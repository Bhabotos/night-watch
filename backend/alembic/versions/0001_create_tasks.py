"""create tasks table

Revision ID: 0001
Revises:
Create Date: 2026-11-14
"""

import sqlalchemy as sa

from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "tasks",
        sa.Column("id", sa.Integer(), sa.Identity(always=False), nullable=False),
        sa.Column("title", sa.String(length=200), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("status", sa.String(length=20), server_default="todo", nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint("status IN ('todo', 'in_progress', 'done')", name="ck_tasks_status"),
        sa.PrimaryKeyConstraint("id", name="pk_tasks"),
    )
    op.create_index("ix_tasks_status", "tasks", ["status"])
    op.create_index("ix_tasks_created_at", "tasks", ["created_at"])


def downgrade() -> None:
    op.drop_index("ix_tasks_created_at", table_name="tasks")
    op.drop_index("ix_tasks_status", table_name="tasks")
    op.drop_table("tasks")
