"""Core business-logic unit tests.

These are intentionally DB-free so they run fast and deterministically in CI
(the postgres/redis service containers are still used by the migration step).
They cover the pure logic most likely to silently break a release:
  - attendance worked-minutes math (must EXCLUDE break gaps)
  - the attendance state-machine transition table
  - password hashing round-trip
  - FCM being a true no-op when unconfigured
  - report date-range validation ceiling
"""
from datetime import datetime, timedelta, timezone

import pytest

from app.models.enums import SessionType
from app.models.attendance import AttendanceSession
from app.services.attendance_service import (
    _ALLOWED_FROM,
    calculate_duration,
)


def _sess(t: SessionType, dt: datetime) -> AttendanceSession:
    return AttendanceSession(type=t, timestamp=dt, lat=0.0, lng=0.0)


def test_duration_excludes_break_time():
    base = datetime(2026, 6, 18, 9, 0, tzinfo=timezone.utc)
    sessions = [
        _sess(SessionType.START, base),                       # 09:00
        _sess(SessionType.BREAK, base + timedelta(hours=3)),  # 12:00  -> 3h worked
        _sess(SessionType.RESUME, base + timedelta(hours=4)), # 13:00  (1h break, excluded)
        _sess(SessionType.END, base + timedelta(hours=8)),    # 17:00  -> 4h worked
    ]
    # 3h + 4h = 7h = 420 minutes; the 1h break is NOT counted.
    assert calculate_duration(sessions) == 420


def test_duration_empty_is_zero():
    assert calculate_duration([]) == 0


def test_duration_is_order_independent():
    base = datetime(2026, 6, 18, 9, 0, tzinfo=timezone.utc)
    ordered = [
        _sess(SessionType.START, base),
        _sess(SessionType.END, base + timedelta(hours=2)),
    ]
    shuffled = list(reversed(ordered))
    assert calculate_duration(shuffled) == calculate_duration(ordered) == 120


def test_state_machine_transitions():
    # START only from NULL; you cannot START again once STARTED.
    assert "NULL" in _ALLOWED_FROM[SessionType.START]
    assert "STARTED" not in _ALLOWED_FROM[SessionType.START]
    # BREAK only while working; RESUME only from a break; END only while working.
    assert _ALLOWED_FROM[SessionType.BREAK] == {"STARTED", "RESUMED"}
    assert _ALLOWED_FROM[SessionType.RESUME] == {"ON_BREAK"}
    assert _ALLOWED_FROM[SessionType.END] == {"STARTED", "RESUMED"}


def test_password_hash_roundtrip():
    from app.core.security import hash_password, verify_password

    h = hash_password("S3cret-Passw0rd!")
    assert h != "S3cret-Passw0rd!"          # never stored in plaintext
    assert verify_password("S3cret-Passw0rd!", h) is True
    assert verify_password("wrong-password", h) is False


async def test_fcm_is_noop_when_unconfigured():
    """With no service-account file configured, FCM must silently skip — no
    exception — so create/update requests never 500 because push isn't set up."""
    from app.services.fcm_service import FCMService

    svc = FCMService()
    assert svc._configured is False  # CI sets FCM_PROJECT_ID but file is ""
    delivered = await svc.send_to_tokens(["fake-token"], title="t", body="b")
    assert delivered == []

    result = await svc.send_and_classify(["fake-token"], title="t", body="b")
    assert result.delivered_count == 0
    assert result.stale_tokens == []


def test_report_range_validator_ceiling():
    """Schema allows up to a 1-year sanity ceiling; the 31-day business rule is
    enforced at the endpoint (so a 35-day range returns 400, not 422)."""
    from app.schemas.report import ReportFilters
    from datetime import date

    # 35 days must PASS schema validation (endpoint enforces the 31-day 400).
    ReportFilters(start_date=date(2026, 1, 1), end_date=date(2026, 2, 5))
    # start after end is always rejected.
    with pytest.raises(ValueError):
        ReportFilters(start_date=date(2026, 2, 5), end_date=date(2026, 1, 1))
    # Beyond the 1-year sanity ceiling is rejected.
    with pytest.raises(ValueError):
        ReportFilters(start_date=date(2025, 1, 1), end_date=date(2026, 6, 1))
