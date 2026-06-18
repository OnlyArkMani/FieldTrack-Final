"""Production admin seed — creates the FIRST admin with a RANDOM password.

WHY THIS EXISTS (separate from scripts/seed_users.py):
    scripts/seed_users.py is for LOCAL DEV only — it creates admin/supervisor/
    employee with well-known passwords (Admin@123, …). Running that in
    production would ship a publicly-known admin credential: a critical
    security hole. This script instead generates a cryptographically random
    password, prints it to the console exactly ONCE, and never stores it in
    plaintext anywhere.

USAGE (on the VPS, once, after the stack is up and migrations have run):
    docker compose --env-file .env.prod -f docker-compose.prod.yml \
        run --rm app python -m app.core.seed

    # optional: override the admin email / name
    ADMIN_EMAIL=ops@yourcompany.com ADMIN_NAME="Ops Admin" \
        docker compose ... run --rm app python -m app.core.seed

Idempotent: if an admin with that email already exists, it is left untouched
and NO password is printed (re-running can't silently reset the admin).
"""
import asyncio
import os
import secrets
import string

from sqlalchemy import select

from app.core.database import async_session_factory
from app.core.security import hash_password
from app.models.enums import UserRole
from app.models.user import User

# Ambiguous-character-free alphabet (no O/0, l/1) so the printed password can be
# typed by hand without confusion.
_ALPHABET = (
    "".join(c for c in string.ascii_uppercase if c not in "O")
    + "".join(c for c in string.ascii_lowercase if c not in "l")
    + "".join(c for c in string.digits if c not in "01")
    + "!@#$%^&*?"
)


def generate_password(length: int = 20) -> str:
    """A 20-char random password from a ~70-char alphabet (~120 bits entropy)."""
    return "".join(secrets.choice(_ALPHABET) for _ in range(length))


async def seed_admin() -> None:
    email = os.environ.get("ADMIN_EMAIL", "admin@fieldtrack.local").strip().lower()
    name = os.environ.get("ADMIN_NAME", "FieldTrack Admin").strip()
    phone = os.environ.get("ADMIN_PHONE", "").strip() or None

    async with async_session_factory() as session:
        existing = (
            await session.execute(select(User).where(User.email == email))
        ).scalar_one_or_none()
        if existing is not None:
            print(f"[seed] admin already exists: {email} — leaving untouched.")
            return

        password = generate_password()
        admin = User(
            name=name,
            email=email,
            phone=phone,
            password_hash=hash_password(password),
            role=UserRole.ADMIN,
            team_id=None,
            is_active=True,
        )
        session.add(admin)
        await session.commit()

        bar = "=" * 64
        print(
            f"\n{bar}\n"
            f" FieldTrack admin created. SAVE THIS PASSWORD NOW — it is shown ONCE\n"
            f" and is NOT stored in plaintext anywhere.\n"
            f"{bar}\n"
            f"   email:    {email}\n"
            f"   password: {password}\n"
            f"{bar}\n"
            f" Log in, then change this password from the dashboard.\n"
            f"{bar}\n"
        )


if __name__ == "__main__":
    asyncio.run(seed_admin())
