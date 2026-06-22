"""Report generation: authorization, data assembly, and the async job store.

PIPELINE:
  endpoint (sync, has actor + db) -> authorize() raises 4xx early, returns a
      NormalizedReport (role-scoped, validated filters)
  -> ReportStore.create() writes PROCESSING to Redis, returns report_id
  -> BackgroundTask -> run_report_job(): fresh db session, build_data(),
      render to bytes (off the event loop via to_thread), write file,
      mark READY|FAILED.

WHY a separate background session: the request's session closes when the 202
response is sent; the job outlives it.

TIME ZONES: stored timestamps are UTC; clock-in/out times in the report are
shown in settings.business_timezone (the employees' wall clock).
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from calendar import monthrange
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from math import asin, cos, radians, sin, sqrt
from typing import Any
from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.database import async_session_factory
from app.core.exceptions import bad_request, forbidden, not_found
from app.core.redis import Keys, get_redis
from app.models.attendance import Attendance, AttendanceSession
from app.models.enums import AttendanceStatus, SessionType, UserRole
from app.models.user import User
from app.repositories.report_repository import ReportRepository
from app.schemas.report import (
    ReportFilters,
    ReportFormat,
    ReportStatus,
    ReportType,
)

logger = logging.getLogger("fieldtrack.reports")

DEFAULT_RANGE_DAYS = 30  # used when ATTENDANCE/DISTANCE omit a date range


# ── Internal report representation (exporter-agnostic) ───────────────────
@dataclass
class ReportTable:
    name: str
    columns: list[str]
    rows: list[list[Any]]
    # Right-align these column indices in Excel/PDF (numeric columns).
    numeric_cols: set[int] = field(default_factory=set)
    # Optional per-row style tag (parallel to `rows`) for conditional formatting
    # in Excel: 'visited' (light green), 'not_visited' (light coral),
    # 'summary' (amber). None => default zebra striping. Ignored by CSV.
    row_styles: list[str | None] = field(default_factory=list)


@dataclass
class ReportData:
    title: str
    subtitle: str
    filters_text: list[str]
    generated_at: datetime
    summary: list[tuple[str, str]]
    tables: list[ReportTable]
    filename_stem: str


@dataclass
class NormalizedReport:
    """The role-authorized, validated request handed to the background job."""

    type: ReportType
    start: date
    end: date
    team_id: int | None
    user_id: int | None
    status: AttendanceStatus | None
    scope_label: str
    month: date | None = None


# ── Service ──────────────────────────────────────────────────────────────
class ReportService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = ReportRepository(db)
        self.settings = get_settings()

    @property
    def _tz(self) -> ZoneInfo:
        try:
            return ZoneInfo(self.settings.business_timezone)
        except Exception:  # noqa: BLE001 — bad tz string shouldn't 500 a report
            return ZoneInfo("UTC")

    # ── Authorization + normalization (runs in the request) ──────────────
    async def authorize(
        self, actor: User, type_: ReportType, filters: ReportFilters
    ) -> NormalizedReport:
        """Clamp the request to what `actor` may export and validate targets.
        Raises 403/400/404 synchronously so the client never schedules a job
        it isn't allowed to run."""
        status = self._parse_status(filters.status)

        if type_ is ReportType.TEAM:
            return await self._authorize_team(actor, filters)

        if type_ is ReportType.GEOFENCE_COMPLIANCE:
            return await self._authorize_compliance(actor, filters)

        # ATTENDANCE / DISTANCE
        start, end = self._resolve_range(filters.start_date, filters.end_date)

        if actor.role == UserRole.EMPLOYEE:
            # Locked to self — team_id/user_id from the client are ignored.
            return NormalizedReport(
                type=type_, start=start, end=end, team_id=None,
                user_id=actor.id, status=status, scope_label="My records",
            )

        if actor.role == UserRole.SUPERVISOR:
            return await self._authorize_supervisor_range(
                actor, type_, start, end, filters, status
            )

        # ADMIN — anything; just validate referenced entities exist.
        return await self._authorize_admin_range(type_, start, end, filters, status)

    async def _authorize_team(
        self, actor: User, filters: ReportFilters
    ) -> NormalizedReport:
        if actor.role == UserRole.EMPLOYEE:
            raise forbidden("Employees cannot generate team reports")
        if filters.team_id is None:
            raise bad_request("team_id is required for a team report")
        team = await self.repo.get_team(filters.team_id)
        if team is None:
            raise not_found("Team not found")
        if actor.role == UserRole.SUPERVISOR:
            supervised = await self.repo.supervised_team_ids(actor.id)
            if filters.team_id not in supervised:
                raise forbidden("You don't supervise this team")

        month = filters.month or date.today().replace(day=1)
        start, end = self._month_bounds(month)
        return NormalizedReport(
            type=ReportType.TEAM, start=start, end=end, team_id=team.id,
            user_id=None, status=None, scope_label=f"Team: {team.name}",
            month=month.replace(day=1),
        )

    async def _authorize_compliance(
        self, actor: User, filters: ReportFilters
    ) -> NormalizedReport:
        """Geofence-compliance is team-scoped and date-ranged. team_id is
        MANDATORY here (the report answers "did THIS team visit their zones")."""
        if actor.role == UserRole.EMPLOYEE:
            raise forbidden("Employees cannot generate compliance reports")
        if filters.team_id is None:
            raise bad_request("team_id is required for a geofence compliance report")
        team = await self.repo.get_team(filters.team_id)
        if team is None:
            raise not_found("Team not found")
        if actor.role == UserRole.SUPERVISOR:
            supervised = await self.repo.supervised_team_ids(actor.id)
            if filters.team_id not in supervised:
                raise forbidden("You don't supervise this team")

        start, end = self._resolve_range(filters.start_date, filters.end_date)
        return NormalizedReport(
            type=ReportType.GEOFENCE_COMPLIANCE,
            start=start,
            end=end,
            team_id=team.id,
            user_id=None,
            status=None,
            scope_label=f"Team: {team.name}",
        )

    async def _authorize_supervisor_range(
        self,
        actor: User,
        type_: ReportType,
        start: date,
        end: date,
        filters: ReportFilters,
        status: AttendanceStatus | None,
    ) -> NormalizedReport:
        supervised = await self.repo.supervised_team_ids(actor.id)
        if not supervised:
            raise forbidden("You don't supervise any team")

        if filters.user_id is not None:
            target = await self.repo.get_user(filters.user_id)
            if target is None:
                raise not_found("Employee not found")
            if target.team_id not in supervised:
                raise forbidden("That employee isn't on your team")
            return NormalizedReport(
                type=type_, start=start, end=end, team_id=None,
                user_id=target.id, status=status,
                scope_label=f"Employee: {target.name}",
            )

        if filters.team_id is not None:
            if filters.team_id not in supervised:
                raise forbidden("You don't supervise this team")
            team = await self.repo.get_team(filters.team_id)
            return NormalizedReport(
                type=type_, start=start, end=end, team_id=filters.team_id,
                user_id=None, status=status,
                scope_label=f"Team: {team.name if team else filters.team_id}",
            )

        # Neither set: default to their single team, else ask them to pick.
        if len(supervised) == 1:
            tid = next(iter(supervised))
            team = await self.repo.get_team(tid)
            return NormalizedReport(
                type=type_, start=start, end=end, team_id=tid, user_id=None,
                status=status,
                scope_label=f"Team: {team.name if team else tid}",
            )
        raise bad_request("Select a team or employee for this report")

    async def _authorize_admin_range(
        self,
        type_: ReportType,
        start: date,
        end: date,
        filters: ReportFilters,
        status: AttendanceStatus | None,
    ) -> NormalizedReport:
        scope = "All employees"
        if filters.user_id is not None:
            target = await self.repo.get_user(filters.user_id)
            if target is None:
                raise not_found("Employee not found")
            scope = f"Employee: {target.name}"
        elif filters.team_id is not None:
            team = await self.repo.get_team(filters.team_id)
            if team is None:
                raise not_found("Team not found")
            scope = f"Team: {team.name}"
        return NormalizedReport(
            type=type_, start=start, end=end, team_id=filters.team_id,
            user_id=filters.user_id, status=status, scope_label=scope,
        )

    # ── Data assembly (runs in the background job) ───────────────────────
    async def build_data(self, n: NormalizedReport) -> ReportData:
        if n.type is ReportType.ATTENDANCE:
            return await self._attendance_data(n)
        if n.type is ReportType.DISTANCE:
            return await self._distance_data(n)
        if n.type is ReportType.DISTANCE_ZONES:
            return await self._distance_zones_data(n)
        if n.type is ReportType.GEOFENCE_COMPLIANCE:
            return await self._geofence_compliance_data(n)
        return await self._team_data(n)

    async def _attendance_data(self, n: NormalizedReport) -> ReportData:
        rows = await self.repo.attendance_in_range(
            start=n.start, end=n.end, team_id=n.team_id,
            user_id=n.user_id, status=n.status,
        )
        user_ids = list({u.id for _, u in rows})
        mock = await self.repo.mock_counts_in_range(
            start=n.start, end=n.end, user_ids=user_ids
        )

        columns = [
            "Employee", "Date", "Start", "End", "Duration",
            "Distance (km)", "Status", "Mock GPS", "Work Summary",
        ]
        table_rows: list[list[Any]] = []
        total_minutes = 0
        total_distance = 0.0
        total_mock = 0
        for att, user in rows:
            start_t, end_t = self._session_bounds(att.sessions)
            mock_n = mock.get((user.id, att.date), 0)
            total_minutes += att.total_duration_minutes
            total_distance += att.total_distance_meters
            total_mock += mock_n
            table_rows.append([
                user.name,
                att.date.isoformat(),
                start_t,
                end_t,
                self._fmt_duration(att.total_duration_minutes),
                round(att.total_distance_meters / 1000, 2),
                att.status.value,
                mock_n,
                (att.work_summary or "").strip(),
            ])

        summary = [
            ("Records", str(len(rows))),
            ("Employees", str(len(user_ids))),
            ("Total hours", self._fmt_duration(total_minutes)),
            ("Total distance", f"{total_distance / 1000:.2f} km"),
            ("Mock-GPS flags", str(total_mock)),
        ]
        return ReportData(
            title="Attendance Report",
            subtitle=self._range_text(n.start, n.end),
            filters_text=self._filters_text(n),
            generated_at=datetime.now(timezone.utc),
            summary=summary,
            tables=[ReportTable(
                name="Attendance",
                columns=columns,
                rows=table_rows,
                numeric_cols={5, 7},
            )],
            filename_stem=f"attendance_{n.start}_{n.end}",
        )

    async def _distance_data(self, n: NormalizedReport) -> ReportData:
        rows = await self.repo.attendance_in_range(
            start=n.start, end=n.end, team_id=n.team_id,
            user_id=n.user_id, status=None,
        )
        # Per-employee accumulation.
        per_user: dict[int, dict[str, Any]] = {}
        daily_rows: list[list[Any]] = []
        for att, user in rows:
            km = att.total_distance_meters / 1000
            daily_rows.append([user.name, att.date.isoformat(), round(km, 2)])
            agg = per_user.setdefault(
                user.id, {"name": user.name, "days": 0, "total": 0.0}
            )
            agg["days"] += 1
            agg["total"] += km

        total_km = sum(a["total"] for a in per_user.values())
        total_days = sum(a["days"] for a in per_user.values())
        team_avg_day = (total_km / total_days) if total_days else 0.0

        summary_rows: list[list[Any]] = []
        top_name, top_total = "—", 0.0
        for agg in sorted(per_user.values(), key=lambda a: a["total"], reverse=True):
            avg_day = agg["total"] / agg["days"] if agg["days"] else 0.0
            vs_team = (
                f"{((avg_day - team_avg_day) / team_avg_day * 100):+.0f}%"
                if team_avg_day
                else "—"
            )
            summary_rows.append([
                agg["name"], agg["days"], round(agg["total"], 2),
                round(avg_day, 2), vs_team,
            ])
            if agg["total"] > top_total:
                top_total, top_name = agg["total"], agg["name"]

        summary = [
            ("Employees", str(len(per_user))),
            ("Total distance", f"{total_km:.2f} km"),
            ("Team avg / active day", f"{team_avg_day:.2f} km"),
            ("Top distance", f"{top_name} ({top_total:.1f} km)"),
        ]
        return ReportData(
            title="Distance Report",
            subtitle=self._range_text(n.start, n.end),
            filters_text=self._filters_text(n),
            generated_at=datetime.now(timezone.utc),
            summary=summary,
            tables=[
                ReportTable(
                    name="Per-Employee Summary",
                    columns=["Employee", "Active Days", "Total (km)",
                             "Avg/Day (km)", "vs Team Avg"],
                    rows=summary_rows,
                    numeric_cols={1, 2, 3},
                ),
                ReportTable(
                    name="Daily Distance",
                    columns=["Employee", "Date", "Distance (km)"],
                    rows=daily_rows,
                    numeric_cols={2},
                ),
            ],
            filename_stem=f"distance_{n.start}_{n.end}",
        )

    async def _distance_zones_data(self, n: NormalizedReport) -> ReportData:
        """Per employee, per day: distance travelled (Haversine over GPS pings)
        + time spent inside each geofence (paired ENTER/EXIT events) + derived
        travel time. One flat table, a TOTAL row after each employee."""
        rows = await self.repo.attendance_in_range(
            start=n.start, end=n.end, team_id=n.team_id,
            user_id=n.user_id, status=None,
        )
        user_ids = list({u.id for _, u in rows})
        points = await self.repo.location_points_in_range(
            start=n.start, end=n.end, user_ids=user_ids
        )
        events = await self.repo.geofence_events_in_range(
            start=n.start, end=n.end, user_ids=user_ids
        )

        columns = [
            "Employee Name", "Date", "Distance (km)", "Active Time",
            "Zones Visited", "Time in Zones", "Travel Time",
        ]
        table_rows: list[list[Any]] = []
        grand_distance = 0.0
        grand_zone_min = 0

        # Accumulator for the current employee's TOTAL row.
        cur_uid: int | None = None
        cur_name: str | None = None
        acc = {"distance": 0.0, "active": 0, "travel": 0, "days": 0}

        def flush_total() -> None:
            if cur_uid is not None and acc["days"]:
                table_rows.append([
                    f"TOTAL — {cur_name}",
                    self._range_text(n.start, n.end),
                    round(acc["distance"], 2),
                    self._fmt_duration(acc["active"]),
                    "—",
                    "—",
                    self._fmt_duration(acc["travel"]),
                ])

        for att, user in rows:  # ordered by name, then date
            key = (user.id, att.date)
            distance_km = round(
                self._haversine_total_m(points.get(key, [])) / 1000, 2
            )
            end_dt = self._session_end_dt(att.sessions)
            zones = self._zone_durations(events.get(key, []), end_dt)
            zone_total_min = sum(mins for _, mins in zones)
            zone_details = (
                "; ".join(f"{name}: {self._fmt_zone_minutes(mins)}" for name, mins in zones)
                or "—"
            )
            active_min = att.total_duration_minutes
            travel_min = max(active_min - zone_total_min, 0)

            if user.id != cur_uid:
                flush_total()
                cur_uid, cur_name = user.id, user.name
                acc = {"distance": 0.0, "active": 0, "travel": 0, "days": 0}

            table_rows.append([
                user.name,
                att.date.isoformat(),
                distance_km,
                self._fmt_duration(active_min),
                len(zones),
                zone_details,
                self._fmt_duration(travel_min),
            ])
            acc["distance"] += distance_km
            acc["active"] += active_min
            acc["travel"] += travel_min
            acc["days"] += 1
            grand_distance += distance_km
            grand_zone_min += zone_total_min

        flush_total()  # last employee

        summary = [
            ("Employees", str(len(user_ids))),
            ("Employee-days", str(len(rows))),
            ("Total distance", f"{grand_distance:.2f} km"),
            ("Total time in zones", self._fmt_duration(grand_zone_min)),
        ]
        return ReportData(
            title="Distance & Zone Time Report",
            subtitle=self._range_text(n.start, n.end),
            filters_text=self._filters_text(n),
            generated_at=datetime.now(timezone.utc),
            summary=summary,
            tables=[ReportTable(
                name="Distance & Zones",
                columns=columns,
                rows=table_rows,
                numeric_cols={2, 4},
            )],
            filename_stem=f"distance_zones_{n.start}_{n.end}",
        )

    async def _geofence_compliance_data(self, n: NormalizedReport) -> ReportData:
        """Did each team member visit their assigned zones, and for how long?

        For every (employee, day, assigned-zone) we emit a row: visited?,
        first entry, last exit, total dwell minutes, visit count. A per-employee
        summary row (zones assigned / visited / compliance %) closes each block.
        Assigned zones = universal + this team's zones."""
        assert n.team_id is not None
        team = await self.repo.get_team(n.team_id)
        members = await self.repo.team_members(n.team_id)
        zones = await self.repo.assigned_geofences_for_team(n.team_id)
        user_ids = [m.id for m in members]
        events = await self.repo.geofence_events_in_range(
            start=n.start, end=n.end, user_ids=user_ids
        )

        days = self._date_span(n.start, n.end)

        columns = [
            "Employee", "Date", "Zone", "Scope", "Visited",
            "First Entry", "Last Exit", "Dwell (min)", "Visits",
        ]
        table_rows: list[list[Any]] = []
        row_styles: list[str | None] = []

        grand_assigned = 0
        grand_visited = 0

        for member in members:  # already ordered by name
            # Track, across the range, which zones this member visited at least
            # once (for the per-employee compliance summary).
            visited_zone_ids: set[int] = set()
            emp_total_dwell = 0
            emp_total_visits = 0

            for day in days:
                day_events = events.get((member.id, day), [])
                # Bucket the day's events by geofence id.
                by_zone: dict[int, list[tuple[str, datetime]]] = {}
                for gid, _name, etype, ts in day_events:
                    by_zone.setdefault(gid, []).append((etype, self._aware(ts)))

                for z in zones:
                    gid = z["id"]
                    zevents = by_zone.get(gid, [])
                    (
                        visited,
                        first_entry,
                        last_exit,
                        dwell_min,
                        visit_count,
                    ) = self._zone_day_compliance(zevents)

                    if visited:
                        visited_zone_ids.add(gid)
                        emp_total_dwell += dwell_min
                        emp_total_visits += visit_count

                    table_rows.append([
                        member.name,
                        day.isoformat(),
                        z["name"],
                        z["scope"],
                        "Yes" if visited else "No",
                        self._fmt_time(first_entry) if first_entry else "—",
                        self._fmt_time(last_exit) if last_exit else "—",
                        dwell_min if visited else "—",
                        visit_count if visited else 0,
                    ])
                    row_styles.append("visited" if visited else "not_visited")

            assigned = len(zones)
            visited_n = len(visited_zone_ids)
            rate = (visited_n / assigned * 100) if assigned else 0.0
            grand_assigned += assigned
            grand_visited += visited_n

            table_rows.append([
                f"TOTAL — {member.name}",
                "",
                f"{visited_n}/{assigned} zones visited",
                "",
                f"{rate:.0f}%",
                "",
                "",
                emp_total_dwell,
                emp_total_visits,
            ])
            row_styles.append("summary")

        overall_rate = (grand_visited / grand_assigned * 100) if grand_assigned else 0.0
        summary = [
            ("Team", team.name if team else str(n.team_id)),
            ("Members", str(len(members))),
            ("Assigned zones", str(len(zones))),
            ("Overall compliance", f"{overall_rate:.0f}%"),
        ]
        return ReportData(
            title="Geofence Compliance Report",
            subtitle=self._range_text(n.start, n.end),
            filters_text=self._filters_text(n),
            generated_at=datetime.now(timezone.utc),
            summary=summary,
            tables=[ReportTable(
                name="Compliance",
                columns=columns,
                rows=table_rows,
                numeric_cols={7, 8},
                row_styles=row_styles,
            )],
            filename_stem=f"geofence_compliance_{n.start}_{n.end}",
        )

    @staticmethod
    def _date_span(start: date, end: date) -> list[date]:
        return [start + timedelta(days=i) for i in range((end - start).days + 1)]

    @classmethod
    def _zone_day_compliance(
        cls, zevents: list[tuple[str, datetime]]
    ) -> tuple[bool, datetime | None, datetime | None, int, int]:
        """From one zone's ENTER/EXIT events for one day (ordered by time),
        derive (visited, first_entry, last_exit, dwell_minutes, visit_count).
        Dwell sums closed ENTER→EXIT pairs; an unclosed ENTER contributes 0."""
        first_entry: datetime | None = None
        last_exit: datetime | None = None
        visit_count = 0
        dwell_seconds = 0.0
        open_enter: datetime | None = None

        for etype, ts in zevents:
            if etype == "ENTER":
                visit_count += 1
                if first_entry is None:
                    first_entry = ts
                open_enter = ts
            elif etype == "EXIT":
                last_exit = ts
                if open_enter is not None and ts > open_enter:
                    dwell_seconds += (ts - open_enter).total_seconds()
                    open_enter = None

        visited = visit_count > 0
        return (
            visited,
            first_entry,
            last_exit,
            int(round(dwell_seconds / 60.0)),
            visit_count,
        )

    async def _team_data(self, n: NormalizedReport) -> ReportData:
        assert n.team_id is not None
        team = await self.repo.get_team(n.team_id)
        members = await self.repo.team_members(n.team_id)
        rows = await self.repo.attendance_in_range(
            start=n.start, end=n.end, team_id=n.team_id, user_id=None, status=None,
        )

        # Working days = distinct dates the team had any attendance activity.
        working_days = len({att.date for att, _ in rows})

        agg: dict[int, dict[str, Any]] = {
            m.id: {"name": m.name, "present": 0, "half": 0, "absent": 0,
                   "minutes": 0, "distance": 0.0}
            for m in members
        }
        for att, user in rows:
            a = agg.setdefault(
                user.id,
                {"name": user.name, "present": 0, "half": 0, "absent": 0,
                 "minutes": 0, "distance": 0.0},
            )
            if att.status == AttendanceStatus.PRESENT:
                a["present"] += 1
            elif att.status == AttendanceStatus.HALF_DAY:
                a["half"] += 1
            elif att.status == AttendanceStatus.ABSENT:
                a["absent"] += 1
            a["minutes"] += att.total_duration_minutes
            a["distance"] += att.total_distance_meters

        member_count = len(agg) or 1
        total_minutes = sum(a["minutes"] for a in agg.values())
        total_distance = sum(a["distance"] for a in agg.values())
        credited = sum(a["present"] + 0.5 * a["half"] for a in agg.values())
        denom = member_count * working_days
        team_rate = (credited / denom * 100) if denom else 0.0

        breakdown: list[list[Any]] = []
        top = {"name": "—", "score": -1.0}
        most_absent = {"name": "—", "absent": -1}
        for a in sorted(agg.values(), key=lambda x: x["name"]):
            credited_m = a["present"] + 0.5 * a["half"]
            rate = (credited_m / working_days * 100) if working_days else 0.0
            derived_absent = max(working_days - int(credited_m), 0) if working_days else a["absent"]
            breakdown.append([
                a["name"], a["present"], a["half"], a["absent"],
                self._fmt_duration(a["minutes"]),
                round(a["distance"] / 1000, 2), f"{rate:.0f}%",
            ])
            score = credited_m * 1000 + a["minutes"]  # tie-break by hours
            if score > top["score"]:
                top = {"name": a["name"], "score": score}
            if derived_absent > most_absent["absent"]:
                most_absent = {"name": a["name"], "absent": derived_absent}

        month_label = (n.month or n.start).strftime("%B %Y")
        summary = [
            ("Team", team.name if team else str(n.team_id)),
            ("Month", month_label),
            ("Members", str(len(members))),
            ("Working days", str(working_days)),
            ("Attendance rate", f"{team_rate:.0f}%"),
            ("Total hours", self._fmt_duration(total_minutes)),
            ("Total distance", f"{total_distance / 1000:.2f} km"),
            ("Top performer", top["name"]),
            ("Most absences", most_absent["name"]),
        ]
        return ReportData(
            title="Team Report",
            subtitle=month_label,
            filters_text=[f"Team: {team.name if team else n.team_id}"],
            generated_at=datetime.now(timezone.utc),
            summary=summary,
            tables=[ReportTable(
                name="Individual Breakdown",
                columns=["Employee", "Present", "Half", "Absent",
                         "Hours", "Distance (km)", "Attendance %"],
                rows=breakdown,
                numeric_cols={1, 2, 3, 5},
            )],
            filename_stem=f"team_{n.team_id}_{(n.month or n.start):%Y-%m}",
        )

    # ── Small helpers ────────────────────────────────────────────────────
    def _session_bounds(
        self, sessions: list[AttendanceSession]
    ) -> tuple[str, str]:
        """First START time and last END time, in business tz (HH:MM)."""
        start_t = end_t = ""
        for s in sessions:
            if s.type == SessionType.START and not start_t:
                start_t = self._fmt_time(s.timestamp)
            if s.type == SessionType.END:
                end_t = self._fmt_time(s.timestamp)
        return start_t, end_t

    def _fmt_time(self, dt: datetime) -> str:
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(self._tz).strftime("%H:%M")

    @staticmethod
    def _fmt_duration(minutes: int) -> str:
        h, m = divmod(max(minutes, 0), 60)
        return f"{h}h {m:02d}m"

    @staticmethod
    def _fmt_zone_minutes(minutes: int) -> str:
        """Human zone duration: '2h 15min' or '45min'."""
        h, m = divmod(max(minutes, 0), 60)
        return f"{h}h {m}min" if h else f"{m}min"

    @staticmethod
    def _haversine_total_m(
        points: list[tuple[float, float, datetime]]
    ) -> float:
        """Sum of great-circle distance (metres) between consecutive pings."""
        if len(points) < 2:
            return 0.0
        radius = 6_371_000.0
        total = 0.0
        for (lat1, lng1, _), (lat2, lng2, _) in zip(points, points[1:]):
            p1, p2 = radians(lat1), radians(lat2)
            dphi = radians(lat2 - lat1)
            dlmb = radians(lng2 - lng1)
            a = sin(dphi / 2) ** 2 + cos(p1) * cos(p2) * sin(dlmb / 2) ** 2
            total += 2 * radius * asin(min(1.0, sqrt(a)))
        return total

    @staticmethod
    def _aware(dt: datetime) -> datetime:
        return dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)

    @classmethod
    def _session_end_dt(cls, sessions: list[AttendanceSession]) -> datetime | None:
        """Latest END session timestamp (tz-aware), used as the EXIT time for a
        zone the employee entered but never left before the day closed."""
        end: datetime | None = None
        for s in sessions:
            if s.type == SessionType.END:
                ts = cls._aware(s.timestamp)
                if end is None or ts > end:
                    end = ts
        return end

    @classmethod
    def _zone_durations(
        cls,
        events: list[tuple[int, str, str, datetime]],
        end_dt: datetime | None,
    ) -> list[tuple[str, int]]:
        """Pair ENTER/EXIT per geofence_id and total the minutes inside each
        zone. Events arrive ordered by timestamp. An ENTER with no matching EXIT
        (still inside at day's end) is closed with `end_dt` (attendance END);
        if there's no END either, it contributes nothing. Returns
        [(zone_name, minutes)] for every zone the employee actually entered,
        in first-entry order."""
        names: dict[int, str] = {}
        order: list[int] = []
        open_enter: dict[int, datetime] = {}
        minutes: dict[int, float] = {}

        for gid, name, etype, ts in events:
            ts = cls._aware(ts)
            if gid not in names:
                names[gid] = name
                order.append(gid)
                minutes.setdefault(gid, 0.0)
            if etype == "ENTER":
                open_enter[gid] = ts
            elif etype == "EXIT":
                ent = open_enter.pop(gid, None)
                if ent is not None and ts > ent:
                    minutes[gid] += (ts - ent).total_seconds() / 60.0

        # Unclosed enters → close with attendance END time.
        for gid, ent in open_enter.items():
            if end_dt is not None and end_dt > ent:
                minutes[gid] += (end_dt - ent).total_seconds() / 60.0

        return [(names[gid], int(round(minutes[gid]))) for gid in order]

    @staticmethod
    def _parse_status(raw: str | None) -> AttendanceStatus | None:
        if not raw:
            return None
        try:
            return AttendanceStatus(raw.strip().upper())
        except ValueError:
            raise bad_request("status must be PRESENT, ABSENT or HALF_DAY")

    @staticmethod
    def _resolve_range(
        start: date | None, end: date | None
    ) -> tuple[date, date]:
        if start and end:
            return start, end
        today = date.today()
        if end and not start:
            return end - timedelta(days=DEFAULT_RANGE_DAYS), end
        if start and not end:
            return start, today
        return today - timedelta(days=DEFAULT_RANGE_DAYS), today

    @staticmethod
    def _month_bounds(month: date) -> tuple[date, date]:
        first = month.replace(day=1)
        last = date(month.year, month.month, monthrange(month.year, month.month)[1])
        today = date.today()
        if last > today and first <= today:
            last = today  # current month: stop at today
        return first, last

    @staticmethod
    def _range_text(start: date, end: date) -> str:
        return f"{start.strftime('%d %b %Y')} – {end.strftime('%d %b %Y')}"

    @staticmethod
    def _filters_text(n: NormalizedReport) -> list[str]:
        parts = [n.scope_label]
        if n.status is not None:
            parts.append(f"Status: {n.status.value}")
        return parts


# ── Async job store (Redis status + filesystem files) ────────────────────
class ReportStore:
    """Status in Redis (TTL = retention), bytes on the filesystem. Both expire
    together so a stale status never points at a deleted file."""

    def __init__(self) -> None:
        self.settings = get_settings()
        self.redis = get_redis()

    @property
    def _ttl(self) -> int:
        return self.settings.report_retention_minutes * 60

    def _dir(self) -> str:
        os.makedirs(self.settings.report_storage_dir, exist_ok=True)
        return self.settings.report_storage_dir

    def file_path(self, report_id: str, fmt: ReportFormat) -> str:
        return os.path.join(self._dir(), f"{report_id}.{fmt.extension}")

    def download_url(self, report_id: str) -> str:
        return f"{self.settings.api_v1_prefix}/reports/{report_id}/download"

    async def create(
        self, owner_id: int, type_: ReportType, fmt: ReportFormat
    ) -> str:
        report_id = uuid.uuid4().hex
        now = datetime.now(timezone.utc)
        expires = now + timedelta(seconds=self._ttl)
        mapping = {
            "status": ReportStatus.PROCESSING.value,
            "type": type_.value,
            "format": fmt.value,
            "owner_id": str(owner_id),
            "created_at": now.isoformat(),
            "expires_at": expires.isoformat(),
        }
        key = Keys.report(report_id)
        await self.redis.hset(key, mapping=mapping)
        await self.redis.expire(key, self._ttl)
        return report_id

    async def mark_ready(
        self, report_id: str, *, path: str, filename: str
    ) -> None:
        key = Keys.report(report_id)
        await self.redis.hset(
            key,
            mapping={
                "status": ReportStatus.READY.value,
                "path": path,
                "filename": filename,
                "download_url": self.download_url(report_id),
            },
        )
        await self.redis.expire(key, self._ttl)  # refresh from completion time

    async def mark_failed(self, report_id: str, *, error: str) -> None:
        key = Keys.report(report_id)
        await self.redis.hset(
            key,
            mapping={"status": ReportStatus.FAILED.value, "error": error[:300]},
        )
        await self.redis.expire(key, self._ttl)

    async def get(self, report_id: str) -> dict[str, str] | None:
        data = await self.redis.hgetall(Keys.report(report_id))
        return data or None

    def prune_expired_files(self) -> None:
        """Best-effort: delete files older than the retention window. Called at
        generation start so storage self-maintains without a dedicated cron."""
        try:
            cutoff = time.time() - self._ttl
            d = self.settings.report_storage_dir
            if not os.path.isdir(d):
                return
            for name in os.listdir(d):
                fp = os.path.join(d, name)
                try:
                    if os.path.isfile(fp) and os.path.getmtime(fp) < cutoff:
                        os.remove(fp)
                except OSError:
                    continue
        except Exception:  # noqa: BLE001
            logger.warning("report file prune skipped", exc_info=True)


# ── Background entry point ───────────────────────────────────────────────
async def run_report_job(
    report_id: str, normalized: NormalizedReport, fmt: ReportFormat
) -> None:
    """Render the report and persist it. Owns its own DB session (the request's
    is long gone). All failures are captured into the Redis status — this never
    raises into the event loop."""
    from app.services.report_exporters import render_report  # lazy: heavy libs

    store = ReportStore()
    try:
        store.prune_expired_files()
        async with async_session_factory() as db:
            data = await ReportService(db).build_data(normalized)
        # Rendering is CPU-bound (openpyxl/reportlab) — keep it off the loop.
        content: bytes = await asyncio.to_thread(render_report, data, fmt)
        path = store.file_path(report_id, fmt)
        with open(path, "wb") as fh:
            fh.write(content)
        filename = f"{data.filename_stem}.{fmt.extension}"
        await store.mark_ready(report_id, path=path, filename=filename)
        logger.info("report %s ready (%s, %s)", report_id, normalized.type.value, fmt.value)
    except Exception as exc:  # noqa: BLE001
        logger.exception("report %s failed", report_id)
        await store.mark_failed(report_id, error=str(exc))
