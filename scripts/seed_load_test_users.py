"""Seed throwaway employee/supervisor accounts for load testing.

Creates N employees split evenly across `--teams` teams, each team with its
own supervisor, and writes the plain-text credentials k6 needs to
scripts/perf/load_test_users.json (gitignored — these are test-only accounts,
never real ones).

Safe to re-run: skips any user whose email already exists. Re-running with a
larger --count just adds the delta.

Usage (from project root, inside the app container or a venv with DATABASE_URL
pointed at the dev Postgres):

    python scripts/seed_load_test_users.py --count 100 --teams 5

To remove every load-test account afterwards:

    python scripts/seed_load_test_users.py --cleanup
"""
import argparse
import asyncio
import json
import os

from sqlalchemy import delete, select

from app.core.database import async_session_factory
from app.core.security import hash_password
from app.models.enums import UserRole
from app.models.user import Team, User

EMAIL_DOMAIN = "loadtest.fieldtrack.internal"  # clearly not a real domain
PASSWORD = "LoadTest@123"
OUT_PATH = os.path.join(os.path.dirname(__file__), "perf", "load_test_users.json")


async def cleanup() -> None:
    async with async_session_factory() as session:
        result = await session.execute(
            delete(User).where(User.email.like(f"%@{EMAIL_DOMAIN}"))
        )
        await session.execute(
            delete(Team).where(Team.name.like("LoadTest Team%"))
        )
        await session.commit()
        print(f"Removed {result.rowcount} load-test users and their teams.")
    if os.path.exists(OUT_PATH):
        os.remove(OUT_PATH)
        print(f"Deleted {OUT_PATH}")


async def seed(count: int, teams: int) -> None:
    per_team = -(-count // teams)  # ceil
    credentials = {"employees": [], "supervisors": []}

    async with async_session_factory() as session:
        for t in range(teams):
            team_name = f"LoadTest Team {t + 1}"
            team = (
                await session.execute(select(Team).where(Team.name == team_name))
            ).scalar_one_or_none()
            if team is None:
                team = Team(name=team_name, description="Auto-created for load testing")
                session.add(team)
                await session.flush()

            sup_email = f"loadtest.supervisor{t + 1}@{EMAIL_DOMAIN}"
            sup = (
                await session.execute(select(User).where(User.email == sup_email))
            ).scalar_one_or_none()
            if sup is None:
                sup = User(
                    name=f"LoadTest Supervisor {t + 1}",
                    email=sup_email,
                    phone=None,
                    password_hash=hash_password(PASSWORD),
                    role=UserRole.SUPERVISOR,
                    team_id=team.id,
                    is_active=True,
                )
                session.add(sup)
                await session.flush()
            if team.supervisor_id != sup.id:
                team.supervisor_id = sup.id
            credentials["supervisors"].append({"email": sup_email, "password": PASSWORD})

            employees_in_team = per_team if t < teams - 1 else count - per_team * (teams - 1)
            for i in range(employees_in_team):
                idx = t * per_team + i + 1
                emp_email = f"loadtest.employee{idx:04d}@{EMAIL_DOMAIN}"
                existing = (
                    await session.execute(select(User).where(User.email == emp_email))
                ).scalar_one_or_none()
                if existing is None:
                    session.add(
                        User(
                            name=f"LoadTest Employee {idx:04d}",
                            email=emp_email,
                            phone=None,
                            password_hash=hash_password(PASSWORD),
                            role=UserRole.EMPLOYEE,
                            team_id=team.id,
                            is_active=True,
                        )
                    )
                credentials["employees"].append({"email": emp_email, "password": PASSWORD})

        await session.commit()

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(credentials, f, indent=2)

    print(f"Seeded {len(credentials['employees'])} employees across {teams} teams "
          f"({len(credentials['supervisors'])} supervisors).")
    print(f"Credentials written to {OUT_PATH} for k6 to consume.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=100, help="number of employees to seed")
    parser.add_argument("--teams", type=int, default=5, help="number of teams to split them across")
    parser.add_argument("--cleanup", action="store_true", help="delete all load-test accounts and exit")
    args = parser.parse_args()

    if args.cleanup:
        asyncio.run(cleanup())
    else:
        asyncio.run(seed(args.count, args.teams))
