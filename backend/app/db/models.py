from datetime import datetime
from enum import StrEnum

from sqlalchemy import CheckConstraint, DateTime, Index, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class TaskStatus(StrEnum):
    TODO = "todo"
    IN_PROGRESS = "in_progress"
    DONE = "done"


class Task(Base):
    __tablename__ = "tasks"
    __table_args__ = (
        CheckConstraint("status IN ('todo', 'in_progress', 'done')", name="status"),
        Index("ix_tasks_status", "status"),
        Index("ix_tasks_created_at", "created_at"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    description: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(
        String(20), default=TaskStatus.TODO.value, server_default=TaskStatus.TODO.value
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
