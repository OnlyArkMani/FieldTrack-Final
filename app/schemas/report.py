"""Report request/response schemas (Pydantic v2).

FLOW: POST /reports/generate returns {report_id, PROCESSING} immediately; a
background task renders the file and writes status to Redis. The client polls
GET /reports/{id}/status until READY|FAILED, then hits /download.

DESIGN:
- type + format are enums (small, closed sets) so a bad value is a 422 at the
  boundary, not a KeyError deep in the exporter.
- ReportFilters is shared by ATTENDANCE/DISTANCE; TEAM uses team_id + month.
  All filter fields are optional and RE-AUTHORIZED server-side per role (an
  employee's request is forced to their own user_id regardless of what they
  send — see report_service).
"""
from datetime import date, datetime
from enum import Enum

from pydantic import BaseModel, Field, model_validator


class ReportType(str, Enum):
    ATTENDANCE = "ATTENDANCE"
    DISTANCE = "DISTANCE"
    DISTANCE_ZONES = "DISTANCE_ZONES"  # distance + time-in-geofence, CSV/Excel only
    GEOFENCE_COMPLIANCE = "GEOFENCE_COMPLIANCE"  # zones visited vs assigned, CSV/Excel only
    TEAM = "TEAM"


class ReportFormat(str, Enum):
    CSV = "CSV"
    EXCEL = "EXCEL"
    PDF = "PDF"

    @property
    def extension(self) -> str:
        return {"CSV": "csv", "EXCEL": "xlsx", "PDF": "pdf"}[self.value]

    @property
    def media_type(self) -> str:
        return {
            "CSV": "text/csv",
            "EXCEL": (
                "application/vnd.openxmlformats-officedocument."
                "spreadsheetml.sheet"
            ),
            "PDF": "application/pdf",
        }[self.value]


class ReportStatus(str, Enum):
    PROCESSING = "PROCESSING"
    READY = "READY"
    FAILED = "FAILED"
    EXPIRED = "EXPIRED"  # status TTL alive but the file was pruned/lost


class ReportFilters(BaseModel):
    """ATTENDANCE / DISTANCE filters. For TEAM, set team_id + month (month is a
    1st-of-month date; the service expands it to the full month)."""

    start_date: date | None = None
    end_date: date | None = None
    team_id: int | None = None
    user_id: int | None = None
    status: str | None = Field(
        default=None, description="PRESENT | ABSENT | HALF_DAY"
    )
    # TEAM-only: any date within the target month (day is ignored).
    month: date | None = None

    @model_validator(mode="after")
    def _check_range(self) -> "ReportFilters":
        if self.start_date is not None and self.end_date is not None:
            if self.start_date > self.end_date:
                raise ValueError("start_date must be on or before end_date")
            # The 31-day business rule is owned by the endpoint (reports.py),
            # which returns the documented 400 + X-Error-Code: DATE_RANGE_TOO_LARGE.
            # If we also raised here, Pydantic would reject a 35-day range with a
            # 422 BEFORE the endpoint runs, so the documented 400 contract would
            # be unreachable. We keep only a loose sanity ceiling (1 year) as a
            # backstop for non-HTTP callers; the real cap lives at the edge.
            if (self.end_date - self.start_date).days > 366:
                raise ValueError("Date range cannot exceed 366 days")
        return self


class GenerateReportRequest(BaseModel):
    type: ReportType
    format: ReportFormat
    filters: ReportFilters = Field(default_factory=ReportFilters)


class GenerateReportResponse(BaseModel):
    report_id: str
    status: ReportStatus


class ReportStatusOut(BaseModel):
    report_id: str
    status: ReportStatus
    type: ReportType | None = None
    format: ReportFormat | None = None
    download_url: str | None = None  # set only when READY
    error: str | None = None  # set only when FAILED
    created_at: datetime | None = None
    expires_at: datetime | None = None
