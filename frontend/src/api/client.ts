import type {
  FieldError,
  Task,
  TaskCounts,
  TaskCreate,
  TaskPage,
  TaskPatch,
  TaskStatus,
} from "../types/task";

// Same-origin: nginx proxies /api/* to the backend (Vite does the same in dev).
const BASE = "/api/v1/tasks";
const PAGE_SIZE = 100; // the backend caps `limit` at MAX_PAGE_SIZE (100)
const MAX_PAGES = 10; // never load more than 1000 tasks into the browser

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly requestId: string | null;
  readonly details: FieldError[];

  constructor(
    status: number,
    code: string,
    message: string,
    requestId: string | null = null,
    details: FieldError[] = [],
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.requestId = requestId;
    this.details = details;
  }
}

interface ErrorEnvelope {
  error: { code?: string; message?: string; request_id?: string | null; details?: FieldError[] };
}

function isErrorEnvelope(body: unknown): body is ErrorEnvelope {
  return typeof body === "object" && body !== null && "error" in body &&
    typeof (body as ErrorEnvelope).error === "object" && (body as ErrorEnvelope).error !== null;
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers: Record<string, string> = { Accept: "application/json" };
  if (init.body !== undefined) headers["Content-Type"] = "application/json";

  let response: Response;
  try {
    response = await fetch(`${BASE}${path}`, { ...init, headers });
  } catch {
    throw new ApiError(0, "network_error", "Cannot reach the server. Check your connection.");
  }

  if (response.status === 204) return undefined as T;

  let body: unknown = null;
  try {
    body = await response.json();
  } catch {
    // Non-JSON body (e.g. an HTML error page from a proxy): handled below.
  }

  if (!response.ok) {
    if (isErrorEnvelope(body)) {
      const { code, message, request_id, details } = body.error;
      throw new ApiError(
        response.status,
        code ?? "http_error",
        message ?? `Request failed (${response.status})`,
        request_id ?? null,
        Array.isArray(details) ? details : [],
      );
    }
    throw new ApiError(response.status, "http_error", `Unexpected response (${response.status})`);
  }

  if (body === null || typeof body !== "object") {
    throw new ApiError(response.status, "invalid_response", "The server sent an invalid response.");
  }
  return body as T;
}

function isTaskPage(body: unknown): body is TaskPage {
  return typeof body === "object" && body !== null &&
    Array.isArray((body as TaskPage).items) && typeof (body as TaskPage).total === "number";
}

export async function listTasks(
  params: { status?: TaskStatus; limit?: number; offset?: number } = {},
): Promise<TaskPage> {
  const query = new URLSearchParams();
  if (params.status) query.set("status", params.status);
  if (params.limit !== undefined) query.set("limit", String(params.limit));
  if (params.offset !== undefined) query.set("offset", String(params.offset));
  const qs = query.toString();
  const page = await request<unknown>(qs ? `?${qs}` : "");
  if (!isTaskPage(page)) {
    throw new ApiError(200, "invalid_response", "The server sent an invalid response.");
  }
  return page;
}

/** Pages through the list endpoint. `truncated` is true if the cap was hit. */
export async function listAllTasks(): Promise<{ tasks: Task[]; total: number; truncated: boolean }> {
  const tasks: Task[] = [];
  let total = 0;
  for (let page = 0; page < MAX_PAGES; page++) {
    const result = await listTasks({ limit: PAGE_SIZE, offset: page * PAGE_SIZE });
    total = result.total;
    tasks.push(...result.items);
    if (tasks.length >= total || result.items.length === 0) break;
  }
  return { tasks, total, truncated: tasks.length < total };
}

/** Exact counts straight from the API: `total` of a limit=1 query per status. */
export async function countTasks(): Promise<TaskCounts> {
  const [todo, inProgress, done] = await Promise.all([
    listTasks({ status: "todo", limit: 1 }),
    listTasks({ status: "in_progress", limit: 1 }),
    listTasks({ status: "done", limit: 1 }),
  ]);
  const counts = { todo: todo.total, in_progress: inProgress.total, done: done.total };
  return { ...counts, total: counts.todo + counts.in_progress + counts.done };
}

export function createTask(data: TaskCreate): Promise<Task> {
  return request<Task>("", { method: "POST", body: JSON.stringify(data) });
}

export function updateTask(id: number, data: TaskPatch): Promise<Task> {
  return request<Task>(`/${id}`, { method: "PATCH", body: JSON.stringify(data) });
}

export function deleteTask(id: number): Promise<void> {
  return request<void>(`/${id}`, { method: "DELETE" });
}

export type ApiHealth = "healthy" | "degraded" | "unreachable";

/**
 * The backend's /health and /ready are deliberately not proxied by nginx, so the
 * UI probes a real API endpoint instead: GET /api/v1/tasks?limit=1.
 *   200 -> healthy (API and database answered)
 *   503 database_unavailable -> degraded (API up, database down)
 *   anything else (network error, 502/503 from the proxy, 5xx) -> unreachable
 */
export async function probeApi(): Promise<ApiHealth> {
  try {
    await listTasks({ limit: 1 });
    return "healthy";
  } catch (error) {
    if (error instanceof ApiError && error.status === 503 && error.code === "database_unavailable") {
      return "degraded";
    }
    return "unreachable";
  }
}
