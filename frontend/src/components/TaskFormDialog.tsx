import { useState, type FormEvent, type KeyboardEvent } from "react";

import { ApiError } from "../api/client";
import { validateTaskForm, type FormErrors } from "../lib/validate";
import {
  DESCRIPTION_MAX,
  STATUS_LABELS,
  TASK_STATUSES,
  TITLE_MAX,
  type Task,
  type TaskStatus,
} from "../types/task";

export interface TaskFormValues {
  title: string;
  description: string | null;
  status: TaskStatus;
}

interface Props {
  task: Task | null; // null = create
  onSubmit: (values: TaskFormValues) => Promise<void>;
  onClose: () => void;
}

export function TaskFormDialog({ task, onSubmit, onClose }: Props) {
  const [title, setTitle] = useState(task?.title ?? "");
  const [description, setDescription] = useState(task?.description ?? "");
  const [status, setStatus] = useState<TaskStatus>(task?.status ?? "todo");
  const [errors, setErrors] = useState<FormErrors>({});
  const [serverError, setServerError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    const found = validateTaskForm(title, description);
    setErrors(found);
    setServerError(null);
    if (Object.keys(found).length > 0) return;

    setSaving(true);
    try {
      await onSubmit({
        title: title.trim(),
        description: description.trim() === "" ? null : description,
        status,
      });
    } catch (e) {
      if (e instanceof ApiError) {
        const details = e.details.map((d) => `${d.field}: ${d.message}`).join("; ");
        setServerError(details ? `${e.message} (${details})` : e.message);
      } else {
        setServerError("Something went wrong. Please try again.");
      }
      setSaving(false);
    }
  }

  function handleKeyDown(event: KeyboardEvent) {
    if (event.key === "Escape" && !saving) onClose();
  }

  const heading = task ? "Edit task" : "New task";
  return (
    <div className="overlay" onKeyDown={handleKeyDown}>
      <div className="dialog" role="dialog" aria-modal="true" aria-labelledby="task-dialog-title">
        <h2 id="task-dialog-title">{heading}</h2>
        <form onSubmit={handleSubmit} noValidate>
          <div className="form-row">
            <label htmlFor="task-title">Title</label>
            <input
              id="task-title"
              value={title}
              autoFocus
              maxLength={TITLE_MAX + 50}
              aria-invalid={errors.title ? true : undefined}
              aria-describedby={errors.title ? "task-title-error" : undefined}
              onChange={(e) => setTitle(e.target.value)}
            />
            {errors.title && (
              <p id="task-title-error" className="form-error">
                {errors.title}
              </p>
            )}
          </div>
          <div className="form-row">
            <label htmlFor="task-description">Description</label>
            <textarea
              id="task-description"
              rows={4}
              value={description}
              aria-invalid={errors.description ? true : undefined}
              aria-describedby={errors.description ? "task-description-error" : undefined}
              onChange={(e) => setDescription(e.target.value)}
            />
            <p className="form-hint">
              {description.length}/{DESCRIPTION_MAX}
            </p>
            {errors.description && (
              <p id="task-description-error" className="form-error">
                {errors.description}
              </p>
            )}
          </div>
          <div className="form-row">
            <label htmlFor="task-status">Status</label>
            <select id="task-status" value={status} onChange={(e) => setStatus(e.target.value as TaskStatus)}>
              {TASK_STATUSES.map((s) => (
                <option key={s} value={s}>
                  {STATUS_LABELS[s]}
                </option>
              ))}
            </select>
          </div>
          {serverError && (
            <p className="banner banner--error" role="alert">
              {serverError}
            </p>
          )}
          <div className="dialog__actions">
            <button type="button" className="btn" onClick={onClose} disabled={saving}>
              Cancel
            </button>
            <button type="submit" className="btn btn--primary" disabled={saving}>
              {saving ? "Saving…" : task ? "Save changes" : "Create task"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
