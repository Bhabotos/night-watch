import { formatDate } from "../lib/validate";
import { STATUS_LABELS, TASK_STATUSES, type Task, type TaskStatus } from "../types/task";

interface Props {
  task: Task;
  busy: boolean;
  onStatusChange: (task: Task, status: TaskStatus) => void;
  onEdit: (task: Task) => void;
  onDelete: (task: Task) => void;
}

export function TaskItem({ task, busy, onStatusChange, onEdit, onDelete }: Props) {
  return (
    <li className={`task task--${task.status}`} aria-busy={busy}>
      <div className="task__main">
        <h3 className="task__title">{task.title}</h3>
        {task.description && <p className="task__description">{task.description}</p>}
        <p className="task__meta">
          Created {formatDate(task.created_at)}
          {task.updated_at !== task.created_at && <> · Updated {formatDate(task.updated_at)}</>}
        </p>
      </div>
      <div className="task__actions">
        <label className="field">
          <span className="sr-only">Status for {task.title}</span>
          <select
            value={task.status}
            disabled={busy}
            onChange={(e) => onStatusChange(task, e.target.value as TaskStatus)}
          >
            {TASK_STATUSES.map((s) => (
              <option key={s} value={s}>
                {STATUS_LABELS[s]}
              </option>
            ))}
          </select>
        </label>
        <button type="button" className="btn" disabled={busy} onClick={() => onEdit(task)}>
          Edit
        </button>
        <button type="button" className="btn btn--danger" disabled={busy} onClick={() => onDelete(task)}>
          Delete
        </button>
      </div>
    </li>
  );
}
