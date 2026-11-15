from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request, Response, status
from sqlalchemy.orm import Session

from app.core.metrics import Metrics
from app.db.models import TaskStatus
from app.db.session import get_db
from app.schemas.task import TaskCreate, TaskList, TaskRead, TaskUpdate
from app.services import tasks as service

router = APIRouter(prefix="/api/v1/tasks", tags=["tasks"])

DbSession = Annotated[Session, Depends(get_db)]


def get_metrics(request: Request) -> Metrics:
    return request.app.state.metrics


AppMetrics = Annotated[Metrics, Depends(get_metrics)]


@router.post("", response_model=TaskRead, status_code=status.HTTP_201_CREATED)
def create_task(data: TaskCreate, db: DbSession, metrics: AppMetrics) -> TaskRead:
    task = service.create_task(db, data)
    metrics.task_operations.labels("create").inc()
    return TaskRead.model_validate(task)


@router.get("", response_model=TaskList)
def list_tasks(
    request: Request,
    db: DbSession,
    metrics: AppMetrics,
    status: TaskStatus | None = None,
    limit: Annotated[int, Query(ge=1)] = 20,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> TaskList:
    limit = min(limit, request.app.state.settings.max_page_size)
    items, total = service.list_tasks(db, status=status, limit=limit, offset=offset)
    metrics.task_operations.labels("list").inc()
    return TaskList(
        items=[TaskRead.model_validate(t) for t in items], total=total, limit=limit, offset=offset
    )


@router.get("/{task_id}", response_model=TaskRead)
def get_task(task_id: int, db: DbSession, metrics: AppMetrics) -> TaskRead:
    task = service.get_task(db, task_id)
    metrics.task_operations.labels("read").inc()
    return TaskRead.model_validate(task)


@router.put("/{task_id}", response_model=TaskRead)
def replace_task(task_id: int, data: TaskCreate, db: DbSession, metrics: AppMetrics) -> TaskRead:
    task = service.replace_task(db, task_id, data)
    metrics.task_operations.labels("replace").inc()
    return TaskRead.model_validate(task)


@router.patch("/{task_id}", response_model=TaskRead)
def update_task(task_id: int, data: TaskUpdate, db: DbSession, metrics: AppMetrics) -> TaskRead:
    task = service.update_task(db, task_id, data)
    metrics.task_operations.labels("update").inc()
    return TaskRead.model_validate(task)


@router.delete("/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_task(task_id: int, db: DbSession, metrics: AppMetrics) -> Response:
    service.delete_task(db, task_id)
    metrics.task_operations.labels("delete").inc()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
