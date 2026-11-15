import { vi } from "vitest";

import type { Task, TaskStatus } from "../types/task";

export type Failure =
  | { network: true }
  | { status: number; body?: unknown; raw?: string };

export interface RecordedCall {
  method: string;
  path: string;
  query: URLSearchParams;
  body: unknown;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export const errorBody = (code: string, message: string, details?: unknown[]) => ({
  error: { code, message, request_id: "req-test", ...(details ? { details } : {}) },
});

/** In-memory stand-in for the FastAPI Tasks API (same paths, shapes and status codes). */
export function installFakeApi(seed: { title: string; status?: TaskStatus; description?: string }[] = []) {
  const tasks: Task[] = [];
  const calls: RecordedCall[] = [];
  let nextId = 1;
  let failNext: Failure | null = null;
  let failAll: Failure | null = null;
  let delayMs = 0;

  const add = (data: { title: string; status?: TaskStatus; description?: string | null }): Task => {
    const stamp = new Date(Date.UTC(2026, 0, 1, 0, 0, nextId)).toISOString();
    const task: Task = {
      id: nextId++,
      title: data.title,
      description: data.description ?? null,
      status: data.status ?? "todo",
      created_at: stamp,
      updated_at: stamp,
    };
    tasks.push(task);
    return task;
  };
  seed.forEach(add);

  const fail = (failure: Failure): Response => {
    if ("network" in failure) throw new TypeError("Failed to fetch");
    if (failure.raw !== undefined) {
      return new Response(failure.raw, { status: failure.status, headers: { "content-type": "text/html" } });
    }
    return json(failure.status, failure.body ?? errorBody("internal_error", "Internal server error"));
  };

  const handle = async (input: RequestInfo | URL, init: RequestInit = {}): Promise<Response> => {
    const url = new URL(String(input), "http://localhost");
    const method = (init.method ?? "GET").toUpperCase();
    const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined;
    calls.push({ method, path: url.pathname, query: url.searchParams, body });
    if (delayMs) await new Promise((r) => setTimeout(r, delayMs));

    const failure = failNext ?? failAll;
    failNext = null;
    if (failure) return fail(failure);

    const match = url.pathname.match(/^\/api\/v1\/tasks(?:\/(\d+))?$/);
    if (!match) return json(404, errorBody("not_found", "Not Found"));
    const id = match[1] ? Number(match[1]) : null;
    const find = () => tasks.find((t) => t.id === id);
    const notFound = () => json(404, errorBody("task_not_found", "Task not found"));

    if (id === null && method === "GET") {
      const status = url.searchParams.get("status");
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 20), 100);
      const offset = Number(url.searchParams.get("offset") ?? 0);
      const matching = tasks.filter((t) => !status || t.status === status).sort((a, b) => b.id - a.id);
      return json(200, { items: matching.slice(offset, offset + limit), total: matching.length, limit, offset });
    }
    if (id === null && method === "POST") {
      const title = typeof body?.title === "string" ? body.title.trim() : "";
      if (!title) {
        return json(422, errorBody("validation_error", "Request validation failed", [
          { field: "title", message: "String should have at least 1 character", type: "string_too_short" },
        ]));
      }
      return json(201, add({ ...body, title }));
    }
    const task = find();
    if (id !== null && !task) return notFound();
    if (task && method === "GET") return json(200, task);
    if (task && method === "PATCH") {
      Object.assign(task, body, { updated_at: new Date(Date.UTC(2026, 6, 1, 0, 0, calls.length)).toISOString() });
      return json(200, task);
    }
    if (task && method === "DELETE") {
      tasks.splice(tasks.indexOf(task), 1);
      return new Response(null, { status: 204 });
    }
    return json(405, errorBody("method_not_allowed", "Method Not Allowed"));
  };

  vi.stubGlobal("fetch", vi.fn(handle));

  return {
    tasks,
    calls,
    add,
    callsTo: (method: string) => calls.filter((c) => c.method === method),
    failNext: (failure: Failure) => {
      failNext = failure;
    },
    failAll: (failure: Failure | null) => {
      failAll = failure;
    },
    setDelay: (ms: number) => {
      delayMs = ms;
    },
  };
}
