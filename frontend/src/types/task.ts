// Mirrors the FastAPI contract (backend/app/schemas/task.py). Nothing here is invented.

export type TaskStatus = "todo" | "in_progress" | "done";

export const TASK_STATUSES: readonly TaskStatus[] = ["todo", "in_progress", "done"];

export const STATUS_LABELS: Record<TaskStatus, string> = {
  todo: "Pending",
  in_progress: "In progress",
  done: "Completed",
};

export const TITLE_MAX = 200;
export const DESCRIPTION_MAX = 5000;

export interface Task {
  id: number;
  title: string;
  description: string | null;
  status: TaskStatus;
  created_at: string;
  updated_at: string;
}

export interface TaskPage {
  items: Task[];
  total: number;
  limit: number;
  offset: number;
}

export interface TaskCreate {
  title: string;
  description?: string | null;
  status?: TaskStatus;
}

export interface TaskPatch {
  title?: string;
  description?: string | null;
  status?: TaskStatus;
}

export interface FieldError {
  field: string;
  message: string;
  type: string;
}

export interface TaskCounts {
  total: number;
  todo: number;
  in_progress: number;
  done: number;
}
