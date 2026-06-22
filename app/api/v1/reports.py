"""Reports router — async generate / poll / download.

FLOW:
  POST /reports/generate   -> authorize NOW (4xx early), schedule a background
                              job, return 202 {report_id, PROCESSING}
  GET  /reports/{id}/status -> poll until READY|FAILED|EXPIRED
  GET  /reports/{id}/download -> FileResponse (owner/admin only)

AUTHZ: every endpoint is scoped to the report's OWNER (the user who generated
it) or an admin. The generate step additionally clamps the data scope to the
caller's role (employee=self, supervisor=their team) inside ReportService.
"""
import os
from datetime import date, datetime
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.dependencies import CurrentUser, get_db
from app.core.exceptions import forbidden, not_found
from app.core.redis import Keys
from app.models.enums import UserRole
from app.models.user import User
from app.schemas.report import (
    GenerateReportRequest,
    GenerateReportResponse,
    ReportFormat,
    ReportStatus,
    ReportStatusOut,
    ReportType,
)
from app.services.report_service import ReportService, ReportStore, run_report_job

router = APIRouter(prefix="/reports", tags=["reports"])


@router.post("/generate", response_model=GenerateReportResponse, status_code=202)
async def generate_report(
    body: GenerateReportRequest,
    background: BackgroundTasks,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> GenerateReportResponse:
    """Authorize + scope the request, then kick off generation in the
    background. Returns immediately with a poll-able report_id."""
    # Date-range guard (documented API contract). The schema validator also
    # caps at 31 days (422) as defense-in-depth; this 400 + X-Error-Code is the
    # explicit contract and additionally rejects future end dates.
    start_date = body.filters.start_date
    end_date = body.filters.end_date
    if start_date is not None and end_date is not None:
        if (end_date - start_date).days > 31:
            raise HTTPException(
                status_code=400,
                detail="Date range cannot exceed 31 days.",
                headers={"X-Error-Code": "DATE_RANGE_TOO_LARGE"},
            )
    if end_date is not None and end_date > date.today():
        raise HTTPException(
            status_code=400,
            detail="End date cannot be in the future.",
        )

    # Tabular-only report types (no useful single-page PDF layout; keeps
    # generation fast). Distance & Zone Time and Geofence Compliance are
    # CSV/Excel only — server-enforced here in addition to the UI hiding PDF.
    _TABULAR_ONLY = {ReportType.DISTANCE_ZONES, ReportType.GEOFENCE_COMPLIANCE}
    if body.type in _TABULAR_ONLY and body.format is ReportFormat.PDF:
        raise HTTPException(
            status_code=400,
            detail="This report is available in CSV and Excel only",
            headers={"X-Error-Code": "FORMAT_NOT_SUPPORTED"},
        )

    normalized = await ReportService(db).authorize(user, body.type, body.filters)
    store = ReportStore()
    report_id = await store.create(user.id, body.type, body.format)
    background.add_task(run_report_job, report_id, normalized, body.format)
    return GenerateReportResponse(
        report_id=report_id, status=ReportStatus.PROCESSING
    )


@router.get("/{report_id}/status", response_model=ReportStatusOut)
async def report_status(
    report_id: str,
    user: CurrentUser,
) -> ReportStatusOut:
    """Poll target. READY with a missing file degrades to EXPIRED so the client
    re-generates instead of hitting a dead download."""
    data = await _load_owned(report_id, user)

    status = ReportStatus(data["status"])
    download_url = data.get("download_url")
    if status is ReportStatus.READY:
        path = data.get("path")
        if not path or not os.path.isfile(path):
            status = ReportStatus.EXPIRED
            download_url = None

    return ReportStatusOut(
        report_id=report_id,
        status=status,
        type=ReportType(data["type"]) if data.get("type") else None,
        format=ReportFormat(data["format"]) if data.get("format") else None,
        download_url=download_url if status is ReportStatus.READY else None,
        error=data.get("error"),
        created_at=_parse_dt(data.get("created_at")),
        expires_at=_parse_dt(data.get("expires_at")),
    )


@router.get("/{report_id}/download")
async def download_report(
    report_id: str,
    user: CurrentUser,
) -> FileResponse:
    """Stream the generated file. 404 until READY; 410-style EXPIRED if the
    file has been pruned."""
    data = await _load_owned(report_id, user)
    if data["status"] != ReportStatus.READY.value:
        raise not_found("Report is not ready")

    path = data.get("path")
    if not path or not os.path.isfile(path):
        raise not_found("Report file has expired; please regenerate")

    fmt = ReportFormat(data["format"])
    filename = data.get("filename") or f"report.{fmt.extension}"
    return FileResponse(
        path,
        media_type=fmt.media_type,
        filename=filename,
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get("/{report_id}/debug")
async def report_debug(
    report_id: str,
    user: CurrentUser,
) -> dict:
    """DEV-ONLY inspection of the raw job state. Returns exactly what's stored in
    Redis plus on-disk file presence, so a stuck "PROCESSING" can be diagnosed
    (did the background task ever write READY/FAILED? is the file actually
    there?). Disabled (404) in production, and still owner/admin scoped."""
    if get_settings().is_production:
        raise not_found("Not found")

    store = ReportStore()
    raw = await store.get(report_id)
    if not raw:
        # Distinguish "never created / expired key" from a real state.
        return {
            "report_id": report_id,
            "redis_key": Keys.report(report_id),
            "exists": False,
            "raw": None,
        }

    # Owner/admin scope even for the debug view.
    owner_id = int(raw.get("owner_id", "0"))
    if owner_id != user.id and user.role != UserRole.ADMIN:
        raise forbidden("This report belongs to another user")

    path = raw.get("path")
    return {
        "report_id": report_id,
        "redis_key": Keys.report(report_id),
        "exists": True,
        "raw": raw,
        "file_path": path,
        "file_exists": bool(path) and os.path.isfile(path),
        "file_size_bytes": (
            os.path.getsize(path) if path and os.path.isfile(path) else None
        ),
    }


# ── Helpers ──────────────────────────────────────────────────────────────
async def _load_owned(report_id: str, user: User) -> dict:
    """Fetch the report's status hash and enforce owner/admin access."""
    store = ReportStore()
    data = await store.get(report_id)
    if not data:
        raise not_found("Report not found or expired")
    owner_id = int(data.get("owner_id", "0"))
    if owner_id != user.id and user.role != UserRole.ADMIN:
        raise forbidden("This report belongs to another user")
    return data


def _parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None
