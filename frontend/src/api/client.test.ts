import { describe, expect, it, vi } from "vitest";

import {
  ApiError,
  countTasks,
  createTask,
  deleteTask,
  listAllTasks,
  listTasks,
  probeApi,
  updateTask,
} from "./client";
import { errorBody, installFakeApi } from "../test/fakeApi";

const respond = (status: number, body: unknown, contentType = "application/json") =>
  new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status,
    headers: { "content-type": contentType },
  });

describe("request building", () => {
  it("calls the same-origin /api/v1/tasks endpoints with the right verbs", async () => {
    const fake = installFakeApi([{ title: "a" }]);
    await listTasks({ status: "todo", limit: 5, offset: 10 });
    const created = await createTask({ title: "b", description: "d" });
    await updateTask(created.id, { status: "done" });
    await deleteTask(created.id);

    expect(fake.calls.map((c) => `${c.method} ${c.path}`)).toEqual([
      "GET /api/v1/tasks",
      "POST /api/v1/tasks",
      `PATCH /api/v1/tasks/${created.id}`,
      `DELETE /api/v1/tasks/${created.id}`,
    ]);
    expect(fake.calls[0]?.query.get("status")).toBe("todo");
    expect(fake.calls[0]?.query.get("limit")).toBe("5");
    expect(fake.calls[0]?.query.get("offset")).toBe("10");
    expect(fake.calls[1]?.body).toEqual({ title: "b", description: "d" });
  });

  it("sends JSON headers only when there is a body", async () => {
    installFakeApi();
    await listTasks();
    await createTask({ title: "x" });
    const [getInit, postInit] = vi.mocked(fetch).mock.calls.map((c) => c[1] as RequestInit);
    expect(getInit?.headers).toEqual({ Accept: "application/json" });
    expect(postInit?.headers).toEqual({ Accept: "application/json", "Content-Type": "application/json" });
  });
});

describe("error mapping", () => {
  it("maps the backend error envelope, including request id and details", async () => {
    const details = [{ field: "title", message: "too short", type: "string_too_short" }];
    vi.stubGlobal("fetch", vi.fn(async () => respond(422, errorBody("validation_error", "Request validation failed", details))));
    const error = await createTask({ title: "" }).catch((e) => e);
    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({ status: 422, code: "validation_error", requestId: "req-test", details });
  });

  it("handles a 404 from the API", async () => {
    installFakeApi();
    await expect(updateTask(99, { status: "done" })).rejects.toMatchObject({ status: 404, code: "task_not_found" });
  });

  it("handles a non-JSON error page from a proxy (e.g. nginx 502 HTML)", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => respond(502, "<html>Bad Gateway</html>", "text/html")));
    await expect(listTasks()).rejects.toMatchObject({ status: 502, code: "http_error", message: "Unexpected response (502)" });
  });

  it("handles a JSON error without the expected envelope", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => respond(500, { detail: "boom" })));
    await expect(listTasks()).rejects.toMatchObject({ status: 500, code: "http_error" });
  });

  it("turns a network failure into status 0 network_error", async () => {
    installFakeApi().failAll({ network: true });
    await expect(listTasks()).rejects.toMatchObject({ status: 0, code: "network_error" });
  });

  it("rejects a 200 response whose body is not a task page", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => respond(200, { unexpected: true })));
    await expect(listTasks()).rejects.toMatchObject({ code: "invalid_response" });
  });

  it("rejects a 200 response that is not JSON", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => respond(200, "<html>captive portal</html>", "text/html")));
    await expect(listTasks()).rejects.toMatchObject({ code: "invalid_response" });
  });
});

describe("aggregation", () => {
  it("countTasks uses the API totals per status", async () => {
    installFakeApi([
      { title: "a", status: "todo" },
      { title: "b", status: "todo" },
      { title: "c", status: "in_progress" },
      { title: "d", status: "done" },
    ]);
    expect(await countTasks()).toEqual({ total: 4, todo: 2, in_progress: 1, done: 1 });
  });

  it("listAllTasks pages through results", async () => {
    const fake = installFakeApi(Array.from({ length: 250 }, (_, i) => ({ title: `t${i}` })));
    const result = await listAllTasks();
    expect(result.tasks).toHaveLength(250);
    expect(result.truncated).toBe(false);
    expect(fake.calls.map((c) => c.query.get("offset"))).toEqual(["0", "100", "200"]);
    expect(fake.calls.every((c) => c.query.get("limit") === "100")).toBe(true);
  });

  it("listAllTasks stops at the cap and reports truncation", async () => {
    const page = (offset: number) => ({
      items: Array.from({ length: 100 }, (_, i) => ({
        id: offset + i, title: "t", description: null, status: "todo", created_at: "x", updated_at: "x",
      })),
      total: 5000, limit: 100, offset,
    });
    vi.stubGlobal("fetch", vi.fn(async (url: string) => respond(200, page(Number(new URL(url, "http://x").searchParams.get("offset"))))));
    const result = await listAllTasks();
    expect(result.tasks).toHaveLength(1000);
    expect(result.total).toBe(5000);
    expect(result.truncated).toBe(true);
    expect(fetch).toHaveBeenCalledTimes(10);
  });
});

describe("probeApi", () => {
  it("is healthy when the API answers", async () => {
    installFakeApi();
    expect(await probeApi()).toBe("healthy");
  });

  it("is degraded when the API reports the database is unavailable", async () => {
    installFakeApi().failAll({ status: 503, body: errorBody("database_unavailable", "Database temporarily unavailable") });
    expect(await probeApi()).toBe("degraded");
  });

  it.each([
    ["proxy 503", { status: 503, body: errorBody("upstream_unavailable", "Backend temporarily unavailable") }],
    ["HTML 502", { status: 502, raw: "<html>Bad Gateway</html>" }],
    ["500", { status: 500 }],
    ["network", { network: true as const }],
  ])("is unreachable on %s", async (_name, failure) => {
    installFakeApi().failAll(failure);
    expect(await probeApi()).toBe("unreachable");
  });
});
