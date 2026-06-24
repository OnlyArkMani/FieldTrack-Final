"""Application configuration via pydantic-settings.

Every value comes from environment / .env — no hardcoded secrets anywhere.
Missing required secrets fail FAST at startup (Pydantic raises), which is what
you want in production rather than a half-working app.
"""
from functools import lru_cache

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # App
    app_env: str = "development"
    app_name: str = "FieldTrack"
    debug: bool = False
    api_v1_prefix: str = "/api/v1"
    allowed_origins: str = ""  # comma-separated

    # Database
    database_url: str
    db_pool_size: int = 10
    db_max_overflow: int = 5

    # Redis
    redis_url: str

    # JWT — separate secrets for access vs refresh (leak containment)
    jwt_access_secret: str
    jwt_refresh_secret: str
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 7

    # FCM
    fcm_service_account_file: str = ""
    fcm_project_id: str = ""

    # Rate limiting
    rate_limit_per_minute: int = 120

    # Reports — generated export files live on the VPS filesystem; status +
    # metadata live in Redis with a matching TTL. Files older than the
    # retention window are pruned best-effort on the next generation.
    report_storage_dir: str = "/srv/fieldtrack/reports"
    report_retention_minutes: int = 60

    # Data retention — location_logs is the hottest, highest-volume table.
    # 31 days keeps storage (and the VPS disk) small while still covering the
    # "last month" of employee trails the dashboard needs. Tune via env.
    location_retention_days: int = 31

    # Background jobs
    cleanup_enabled: bool = True  # daily housekeeping worker (APScheduler)
    reminders_enabled: bool = True  # daily attendance reminder jobs (APScheduler)
    # Business-local timezone for human-facing schedules (9AM/6PM reminders).
    # The server runs UTC (see models/base.py); reminders must fire on the
    # employees' wall-clock, so APScheduler is told this tz explicitly. Default
    # Asia/Kolkata (SamarthAgri is India-based); override via env if deployed
    # elsewhere — zero code change.
    business_timezone: str = "Asia/Kolkata"

    @property
    def cors_origins(self) -> list[str]:
        return [o.strip() for o in self.allowed_origins.split(",") if o.strip()]

    @property
    def cors_origin_regex(self) -> str | None:
        # Dev convenience: the Flutter web dev server binds a RANDOM localhost
        # port on every run, so it can't be pinned in allowed_origins. Outside
        # production, allow any http://localhost:<port> / 127.0.0.1:<port>
        # origin via regex (this works alongside allow_credentials=True, which
        # forbids a "*" wildcard). In production this returns None so origins
        # stay strictly whitelisted in allowed_origins.
        if self.is_production:
            return None
        return r"^http://(localhost|127\.0\.0\.1)(:\d+)?$"

    @field_validator("app_env")
    @classmethod
    def _validate_env(cls, v: str) -> str:
        if v not in {"development", "staging", "production"}:
            raise ValueError("app_env must be development|staging|production")
        return v

    @property
    def is_production(self) -> bool:
        return self.app_env == "production"


@lru_cache
def get_settings() -> Settings:
    """Cached singleton — import-time safe, test-overridable via dependency."""
    return Settings()
