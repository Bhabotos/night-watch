import { useMemo, useState } from "react";

import { ApiError } from "./api/client";
import { ConfirmDialog } from "./components/ConfirmDialog";
import { HealthIndicator } from "./components/HealthIndicator";
import { StatsCards } from "./components/StatsCards";
import { TaskFormDialog, type TaskFormValues } from "./components/TaskFormDialog";
import { TaskItem } from "./components/TaskItem";
import { TaskToolbar, type StatusFilter } from "./components/TaskToolbar";
import { useApiHealth } from "./hooks/useApiHealth";
import { useTasks } from "./hooks/useTasks";
import type { Task, TaskStatus } from "./types/task";

type Dialog = { kind: "create" } | { kind: "edit"; task: Task } | { kind: "delete"; task: Task } | null;

function describe(error: ApiError): string {
  return error.requestId ? `${error.message} (ref ${error.requestId})` : error.message;
}

export default function App({ healthIntervalMs = 15_000 }: { healthIntervalMs?: number }) {
  const { tasks, counts, truncated, loading, error, refresh, create, update, remove } = useTasks();
  const health = useApiHealth(healthIntervalMs);

  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<StatusFilter>("all");
  const [dialog, setDialog] = useState<Dialog>(null);
  const [busyId, setBusyId] = useState<number | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const visible = useMemo(() => {
    const needle = search.trim().toLowerCase();
    return tasks.filter((task) => {
      if (filter !== "all" && task.status !== filter) return false;
      if (!needle) return true;
      return task.title.toLowerCase().includes(needle) ||
        (task.description ?? "").toLowerCase().includes(needle);
    });
  }, [tasks, search, filter]);

  async function changeStatus(task: Task, status: TaskStatus) {
    setBusyId(task.id);
    setActionError(null);
    try {
      await update(task.id, { status });
    } catch (e) {
      setActionError(e instanceof ApiError ? describe(e) : "Could not update the task.");
    } finally {
      setBusyId(null);
    }
  }

  async function submitForm(values: TaskFormValues) {
    if (dialog?.kind === "edit") await update(dialog.task.id, values);
    else await create(values);
    setDialog(null);
  }

  async function confirmDelete() {
    if (dialog?.kind !== "delete") return;
    await remove(dialog.task.id);
    setDialog(null);
  }

  const hasTasks = counts.total > 0 || tasks.length > 0;

  return (
    <div className="app">
      <header className="app__header">
        <h1>Tasks Dashboard</h1>
        <HealthIndicator status={health.status} checkedAt={health.checkedAt} />
      </header>

      <main className="app__main">
        <StatsCards counts={counts} loading={loading && tasks.length === 0} />

        <TaskToolbar
          search={search}
          onSearch={setSearch}
          filter={filter}
          onFilter={setFilter}
          onNew={() => setDialog({ kind: "create" })}
        />

        {error && (
          <div className="banner banner--error" role="alert">
            <span>Could not load tasks: {describe(error)}</span>
            <button type="button" className="btn" onClick={() => void refresh()}>
              Retry
            </button>
          </div>
        )}
        {actionError && (
          <div className="banner banner--error" role="alert">
            <span>{actionError}</span>
            <button type="button" className="btn" onClick={() => setActionError(null)}>
              Dismiss
            </button>
          </div>
        )}
        {truncated && (
          <p className="banner banner--warn" role="status">
            Showing the {tasks.length} most recent tasks of {counts.total}. Search and filters apply to these only.
          </p>
        )}

        {loading && tasks.length === 0 && !error ? (
          <p className="empty" role="status">
            Loading tasks…
          </p>
        ) : !hasTasks && !error ? (
          <div className="empty">
            <p>No tasks yet.</p>
            <button type="button" className="btn btn--primary" onClick={() => setDialog({ kind: "create" })}>
              Create your first task
            </button>
          </div>
        ) : visible.length === 0 && tasks.length > 0 ? (
          <p className="empty">No tasks match your search or filter.</p>
        ) : (
          <ul className="tasks" aria-label="Tasks">
            {visible.map((task) => (
              <TaskItem
                key={task.id}
                task={task}
                busy={busyId === task.id}
                onStatusChange={(t, s) => void changeStatus(t, s)}
                onEdit={(t) => setDialog({ kind: "edit", task: t })}
                onDelete={(t) => setDialog({ kind: "delete", task: t })}
              />
            ))}
          </ul>
        )}
      </main>

      {(dialog?.kind === "create" || dialog?.kind === "edit") && (
        <TaskFormDialog
          task={dialog.kind === "edit" ? dialog.task : null}
          onSubmit={submitForm}
          onClose={() => setDialog(null)}
        />
      )}
      {dialog?.kind === "delete" && (
        <ConfirmDialog task={dialog.task} onConfirm={confirmDelete} onClose={() => setDialog(null)} />
      )}
    </div>
  );
}
