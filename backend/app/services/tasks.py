"""Task persistence logic. Routes call these; they own transactions."""

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.errors import TaskNotFoundError
from app.db.models import Task, TaskStatus
from app.schemas.task import TaskCreate, TaskUpdate


def create_task(db: Session, data: TaskCreate) -> Task:
    task = Task(title=data.title, description=data.description, status=data.status.value)
    db.add(task)
    db.commit()
    db.refresh(task)
    return task


def get_task(db: Session, task_id: int) -> Task:
    task = db.get(Task, task_id)
    if task is None:
        raise TaskNotFoundError
    return task


def list_tasks(
    db: Session, *, status: TaskStatus | None, limit: int, offset: int
) -> tuple[list[Task], int]:
    filters = [Task.status == status.value] if status else []
    total = db.scalar(select(func.count()).select_from(Task).where(*filters)) or 0
    query = (
        select(Task)
        .where(*filters)
        .order_by(Task.created_at.desc(), Task.id.desc())
        .limit(limit)
        .offset(offset)
    )
    return list(db.scalars(query).all()), total


def replace_task(db: Session, task_id: int, data: TaskCreate) -> Task:
    task = get_task(db, task_id)
    task.title = data.title
    task.description = data.description
    task.status = data.status.value
    db.commit()
    db.refresh(task)
    return task


def update_task(db: Session, task_id: int, data: TaskUpdate) -> Task:
    task = get_task(db, task_id)
    for field in data.model_fields_set:
        value = getattr(data, field)
        setattr(task, field, value.value if isinstance(value, TaskStatus) else value)
    db.commit()
    db.refresh(task)
    return task


def delete_task(db: Session, task_id: int) -> None:
    task = get_task(db, task_id)
    db.delete(task)
    db.commit()
