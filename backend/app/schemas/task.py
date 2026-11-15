from datetime import datetime
from typing import Annotated, Self

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

from app.db.models import TaskStatus

Title = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
Description = Annotated[str, StringConstraints(max_length=5000)]


class TaskCreate(BaseModel):
    """Body for POST and PUT (full replacement)."""

    model_config = ConfigDict(extra="forbid")

    title: Title
    description: Description | None = None
    status: TaskStatus = TaskStatus.TODO


class TaskUpdate(BaseModel):
    """Body for PATCH: only the supplied fields change."""

    model_config = ConfigDict(extra="forbid")

    title: Title | None = None
    description: Description | None = None
    status: TaskStatus | None = None

    @model_validator(mode="after")
    def check_fields(self) -> Self:
        if not self.model_fields_set:
            raise ValueError("at least one field must be provided")
        # title and status are NOT NULL columns; description may be cleared with null.
        for name in ("title", "status"):
            if name in self.model_fields_set and getattr(self, name) is None:
                raise ValueError(f"{name} cannot be null")
        return self


class TaskRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    description: str | None
    status: TaskStatus
    created_at: datetime
    updated_at: datetime


class TaskList(BaseModel):
    items: list[TaskRead]
    total: int = Field(ge=0)
    limit: int
    offset: int
