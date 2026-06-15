"""Add teams.is_active (soft-delete flag).

The Team model/repository/service already reference `is_active` (list
filtering in TeamRepository.list_with_stats, soft_delete in TeamService,
TeamRow), but the column was never added to the `teams` table in 0001 —
every call to list_with_stats() raised AttributeError -> 500 (e.g. right
after creating a team, when get_detail() re-fetches it).

Revision ID: 0003
Revises: 0002
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0003"
down_revision: Union[str, None] = "0002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "teams",
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
    )


def downgrade() -> None:
    op.drop_column("teams", "is_active")
