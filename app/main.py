"""FieldTrack API entrypoint."""
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from prometheus_fastapi_instrumentator import Instrumentator
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api.v1 import (
    attendance,
    auth,
    devices,
    employees,
    geofencing,
    location,
    notifications,
    reports,
    sync,
    teams,
    ws,
)
from app.core.config import get_settings
from app.core.database import engine
from app.core.exceptions import DEFAULT_ERROR_CODES, ApiError
from app.core.redis import close_redis, get_redis
from app.core.scheduler import build_reminder_scheduler
from app.workers.sync_cleanup import run_cleanup

settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Fail fast: verify Redis is reachable at startup.
    await get_redis().ping()

    # Daily housekeeping (location prune, sync_queue prune, attendance archive).
    # In-process APScheduler — no Celery (see ARCHITECTURE.md). 03:17 UTC is an
    # off-peak, deliberately non-round minute to dodge other cron herds.
    # NOTE: with >1 uvicorn worker each holds a scheduler; the cleanup jobs are
    # age-keyed and idempotent, so a double run is harmless (the 2nd finds
    # nothing). Set CLEANUP_ENABLED=false to disable entirely.
    scheduler: AsyncIOScheduler | None = None
    if settings.cleanup_enabled:
        scheduler = AsyncIOScheduler(timezone="UTC")
        scheduler.add_job(
            run_cleanup,
            CronTrigger(hour=3, minute=17),
            id="daily_cleanup",
            max_instances=1,
            coalesce=True,
            misfire_grace_time=3600,
        )
        scheduler.start()

    # Human-facing daily reminders (9AM clock-in, 6PM clock-out, 11PM cleanup).
    # Separate scheduler because it runs on the BUSINESS timezone, not UTC.
    reminders: AsyncIOScheduler | None = None
    if settings.reminders_enabled:
        reminders = build_reminder_scheduler()
        reminders.start()

    try:
        yield
    finally:
        if scheduler is not None:
            scheduler.shutdown(wait=False)
        if reminders is not None:
            reminders.shutdown(wait=False)
        await close_redis()
        await engine.dispose()


app = FastAPI(
    title=settings.app_name,
    docs_url=f"{settings.api_v1_prefix}/docs" if not settings.is_production else None,
    openapi_url=f"{settings.api_v1_prefix}/openapi.json"
    if not settings.is_production
    else None,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    # Dev-only: matches any localhost port (Flutter web's random dev port).
    # None in production, so prod stays restricted to allowed_origins.
    allow_origin_regex=settings.cors_origin_regex,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Exposes GET /metrics (request counts/latencies) for Prometheus to scrape.
# Safe to leave on in all environments — it's just counters, no auth needed
# because /metrics is never proxied publicly by Nginx (internal network only).
Instrumentator().instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)


# ── Error contract: EVERY error body is {"detail": ..., "code": ...} ─────
@app.exception_handler(ApiError)
async def api_error_handler(request: Request, exc: ApiError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code, content=exc.body(), headers=exc.headers
    )


@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(
    request: Request, exc: StarletteHTTPException
) -> JSONResponse:
    """Framework-raised HTTPExceptions (404 route-not-found, etc.) get a
    default code so the {detail, code} contract holds everywhere."""
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "detail": exc.detail,
            "code": DEFAULT_ERROR_CODES.get(exc.status_code, "ERROR"),
        },
        headers=getattr(exc, "headers", None),
    )


@app.get(f"{settings.api_v1_prefix}/health", tags=["health"])
async def health() -> dict:
    """Liveness probe used by Docker healthcheck and uptime monitoring."""
    return {"status": "ok", "env": settings.app_env}


# ── Routers ──────────────────────────────────────────────────────────────
app.include_router(auth.router, prefix=settings.api_v1_prefix)
app.include_router(employees.router, prefix=settings.api_v1_prefix)
app.include_router(teams.router, prefix=settings.api_v1_prefix)
app.include_router(attendance.router, prefix=settings.api_v1_prefix)
app.include_router(location.router, prefix=settings.api_v1_prefix)
app.include_router(geofencing.router, prefix=settings.api_v1_prefix)
app.include_router(sync.router, prefix=settings.api_v1_prefix)
app.include_router(notifications.router, prefix=settings.api_v1_prefix)
app.include_router(devices.router, prefix=settings.api_v1_prefix)
app.include_router(reports.router, prefix=settings.api_v1_prefix)
# WebSocket router (no response_model/prefix conventions — paths are absolute).
app.include_router(ws.router, prefix=settings.api_v1_prefix)
