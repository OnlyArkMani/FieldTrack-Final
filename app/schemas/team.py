"""Team request/response schemas (Pydantic v2).

DESIGN:
- TeamOut carries denormalized read-time aggregates (member_count,
  supervisor_name, present_today, performance_pct) computed by the repository
  in one grouped query — the team-list card needs all of them, and computing
  them in SQL beats N round-trips.
- performance_pct = present_today / member_count * 100, rounded to 1 dp.
  member_count == 0 ⇒ 0.0 (no division by zero, an empty team is 0% not N/A).
- Soft delete: DELETE marks is_active=False (teams are referenced by users +
  audit history; a hard delete would orphan or cascade-null those).
"""
from pydantic import BaseModel, ConfigDict, Field


class TeamCreate(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=500)
    supervisor_id: int | None = None


class TeamUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=500)
    supervisor_id: int | None = None


class AddMemberRequest(BaseModel):
    user_id: int


class TeamOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    description: str | None
    supervisor_id: int | None
    supervisor_name: str | None
    member_count: int
    present_today: int
    performance_pct: float


class TeamMemberOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    email: str
    role: str
    profile_photo_url: str | None
    is_active: bool
    # Redis-derived live status (ACTIVE | IDLE | OFFLINE); read-time, never
    # persisted. Lets the Teams screen show who's live per team.
    live_status: str = "OFFLINE"


class TeamDetailOut(TeamOut):
    members: list[TeamMemberOut]
