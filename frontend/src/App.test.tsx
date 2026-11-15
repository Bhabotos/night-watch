import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";

import App from "./App";
import { errorBody, installFakeApi } from "./test/fakeApi";

const SEED = [
  { title: "Write docs", status: "todo" as const, description: "API reference" },
  { title: "Fix login bug", status: "in_progress" as const },
  { title: "Ship release", status: "done" as const },
];

const counts = () => ({
  total: screen.getByTestId("count-total").textContent,
  todo: screen.getByTestId("count-todo").textContent,
  progress: screen.getByTestId("count-in_progress").textContent,
  done: screen.getByTestId("count-done").textContent,
});

const renderApp = (healthIntervalMs = 60_000) => render(<App healthIntervalMs={healthIntervalMs} />);
const taskTitles = () => screen.queryAllByRole("heading", { level: 3 }).map((h) => h.textContent);

describe("dashboard", () => {
  it("shows a loading state, then the counters and tasks from the API", async () => {
    installFakeApi(SEED).setDelay(20);
    renderApp();
    expect(screen.getByText("Loading tasks…")).toBeInTheDocument();
    expect(await screen.findByText("Fix login bug")).toBeInTheDocument();
    expect(counts()).toEqual({ total: "3", todo: "1", progress: "1", done: "1" });
    expect(taskTitles()).toEqual(["Ship release", "Fix login bug", "Write docs"]); // newest first
    expect(screen.queryByText("Loading tasks…")).not.toBeInTheDocument();
  });

  it("shows an empty state with a call to action", async () => {
    installFakeApi();
    renderApp();
    expect(await screen.findByText("No tasks yet.")).toBeInTheDocument();
    expect(counts().total).toBe("0");
    expect(screen.getByRole("button", { name: "Create your first task" })).toBeInTheDocument();
  });
});

describe("create", () => {
  it("creates a task and refreshes the list and counters", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");

    await user.click(screen.getByRole("button", { name: "New task" }));
    const dialog = screen.getByRole("dialog", { name: "New task" });
    await user.type(within(dialog).getByLabelText("Title"), "  Plan sprint  ");
    await user.type(within(dialog).getByLabelText("Description"), "Q1 goals");
    await user.selectOptions(within(dialog).getByLabelText("Status"), "in_progress");
    await user.click(within(dialog).getByRole("button", { name: "Create task" }));

    expect(await screen.findByText("Plan sprint")).toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(fake.callsTo("POST")).toHaveLength(1);
    expect(fake.callsTo("POST")[0]?.body).toEqual({ title: "Plan sprint", description: "Q1 goals", status: "in_progress" });
    await waitFor(() => expect(counts()).toEqual({ total: "4", todo: "1", progress: "2", done: "1" }));
  });

  it("validates on the client and does not call the API", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");

    await user.click(screen.getByRole("button", { name: "New task" }));
    await user.click(screen.getByRole("button", { name: "Create task" }));
    expect(screen.getByText("Title is required.")).toBeInTheDocument();
    expect(screen.getByLabelText("Title")).toHaveAttribute("aria-invalid", "true");
    expect(fake.callsTo("POST")).toHaveLength(0);
  });

  it("shows a server-side validation error inside the dialog and keeps it open", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");

    await user.click(screen.getByRole("button", { name: "New task" }));
    await user.type(screen.getByLabelText("Title"), "Valid locally");
    fake.failNext({
      status: 422,
      body: errorBody("validation_error", "Request validation failed", [
        { field: "title", message: "Rejected by server", type: "value_error" },
      ]),
    });
    await user.click(screen.getByRole("button", { name: "Create task" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Request validation failed (title: Rejected by server)");
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Create task" })).toBeEnabled();
  });

  it("closes the dialog with Cancel and Escape without saving", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");

    await user.click(screen.getByRole("button", { name: "New task" }));
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "New task" }));
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(fake.callsTo("POST")).toHaveLength(0);
  });
});

describe("edit and status", () => {
  it("edits a task through PATCH and shows the new values", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");

    const row = screen.getByText("Write docs").closest("li") as HTMLElement;
    await user.click(within(row).getByRole("button", { name: "Edit" }));
    const dialog = screen.getByRole("dialog", { name: "Edit task" });
    expect(within(dialog).getByLabelText("Title")).toHaveValue("Write docs");
    expect(within(dialog).getByLabelText("Description")).toHaveValue("API reference");

    await user.clear(within(dialog).getByLabelText("Title"));
    await user.type(within(dialog).getByLabelText("Title"), "Write better docs");
    await user.click(within(dialog).getByRole("button", { name: "Save changes" }));

    expect(await screen.findByText("Write better docs")).toBeInTheDocument();
    expect(screen.queryByText("Write docs")).not.toBeInTheDocument();
    expect(fake.callsTo("PATCH")[0]?.path).toBe("/api/v1/tasks/1");
    expect(fake.callsTo("PATCH")[0]?.body).toMatchObject({ title: "Write better docs", status: "todo" });
  });

  it("clears the description by sending null", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("API reference");
    const row = screen.getByText("Write docs").closest("li") as HTMLElement;
    await user.click(within(row).getByRole("button", { name: "Edit" }));
    await user.clear(screen.getByLabelText("Description"));
    await user.click(screen.getByRole("button", { name: "Save changes" }));
    await waitFor(() => expect(screen.queryByText("API reference")).not.toBeInTheDocument());
    expect(fake.callsTo("PATCH")[0]?.body).toMatchObject({ description: null });
  });

  it("changes status from the list and updates the counters", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");

    await user.selectOptions(screen.getByLabelText("Status for Write docs"), "done");
    await waitFor(() => expect(counts()).toEqual({ total: "3", todo: "0", progress: "1", done: "2" }));
    expect(fake.callsTo("PATCH")[0]?.body).toEqual({ status: "done" });
  });

  it("shows a dismissible error when a status change fails", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");

    fake.failNext({ status: 503, body: errorBody("database_unavailable", "Database temporarily unavailable") });
    await user.selectOptions(screen.getByLabelText("Status for Write docs"), "done");
    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent("Database temporarily unavailable (ref req-test)");
    await user.click(within(alert).getByRole("button", { name: "Dismiss" }));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(counts().done).toBe("1"); // unchanged
  });
});

describe("delete", () => {
  it("asks for confirmation, then deletes", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");

    const row = screen.getByText("Write docs").closest("li") as HTMLElement;
    await user.click(within(row).getByRole("button", { name: "Delete" }));
    const dialog = screen.getByRole("alertdialog");
    expect(dialog).toHaveTextContent("Write docs");
    expect(fake.callsTo("DELETE")).toHaveLength(0);

    await user.click(within(dialog).getByRole("button", { name: "Delete" }));
    await waitFor(() => expect(screen.queryByText("Write docs")).not.toBeInTheDocument());
    expect(fake.callsTo("DELETE")[0]?.path).toBe("/api/v1/tasks/1");
    expect(counts()).toEqual({ total: "2", todo: "0", progress: "1", done: "1" });
  });

  it("does nothing when cancelled", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");
    const row = screen.getByText("Write docs").closest("li") as HTMLElement;
    await user.click(within(row).getByRole("button", { name: "Delete" }));
    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Cancel" }));
    expect(fake.callsTo("DELETE")).toHaveLength(0);
    expect(screen.getByText("Write docs")).toBeInTheDocument();
  });

  it("keeps the dialog open and shows the error when deletion fails", async () => {
    const fake = installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");
    const row = screen.getByText("Write docs").closest("li") as HTMLElement;
    await user.click(within(row).getByRole("button", { name: "Delete" }));

    fake.failNext({ status: 404, body: errorBody("task_not_found", "Task not found") });
    await user.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Delete" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Task not found");
    expect(screen.getByRole("alertdialog")).toBeInTheDocument();
    expect(screen.getByText("Write docs")).toBeInTheDocument();
  });
});

describe("search and filter", () => {
  it("filters by status", async () => {
    installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");
    await user.selectOptions(screen.getByLabelText("Filter by status"), "in_progress");
    expect(taskTitles()).toEqual(["Fix login bug"]);
    await user.selectOptions(screen.getByLabelText("Filter by status"), "all");
    expect(taskTitles()).toHaveLength(3);
  });

  it("searches title and description, case-insensitively", async () => {
    installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");
    await user.type(screen.getByLabelText("Search tasks"), "LOGIN");
    expect(taskTitles()).toEqual(["Fix login bug"]);
    await user.clear(screen.getByLabelText("Search tasks"));
    await user.type(screen.getByLabelText("Search tasks"), "api ref");
    expect(taskTitles()).toEqual(["Write docs"]);
  });

  it("combines search and status filter and shows a no-match message", async () => {
    installFakeApi(SEED);
    const user = userEvent.setup();
    renderApp();
    await screen.findByText("Write docs");
    await user.selectOptions(screen.getByLabelText("Filter by status"), "done");
    await user.type(screen.getByLabelText("Search tasks"), "login");
    expect(screen.getByText("No tasks match your search or filter.")).toBeInTheDocument();
  });
});

describe("error handling", () => {
  it("shows a load error with a working Retry", async () => {
    const fake = installFakeApi(SEED);
    fake.failAll({ status: 500 });
    const user = userEvent.setup();
    renderApp();
    expect(await screen.findByRole("alert")).toHaveTextContent("Could not load tasks: Internal server error (ref req-test)");
    expect(screen.queryByText("No tasks yet.")).not.toBeInTheDocument();

    fake.failAll(null);
    await user.click(screen.getByRole("button", { name: "Retry" }));
    expect(await screen.findByText("Write docs")).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("explains a network failure", async () => {
    installFakeApi(SEED).failAll({ network: true });
    renderApp();
    expect(await screen.findByRole("alert")).toHaveTextContent("Cannot reach the server");
  });

  it("copes with an HTML error page from the proxy", async () => {
    installFakeApi(SEED).failAll({ status: 502, raw: "<html>502 Bad Gateway</html>" });
    renderApp();
    expect(await screen.findByRole("alert")).toHaveTextContent("Unexpected response (502)");
    expect(screen.queryByText(/Bad Gateway/)).not.toBeInTheDocument(); // raw HTML is never rendered
  });
});

describe("API health indicator", () => {
  it("reports healthy", async () => {
    installFakeApi(SEED);
    renderApp();
    expect(await screen.findByText("API healthy")).toBeInTheDocument();
  });

  it("reports an unavailable database", async () => {
    installFakeApi(SEED).failAll({ status: 503, body: errorBody("database_unavailable", "Database temporarily unavailable") });
    renderApp();
    expect(await screen.findByText("Database unavailable")).toBeInTheDocument();
  });

  it("reports an unreachable API", async () => {
    installFakeApi(SEED).failAll({ network: true });
    renderApp();
    expect(await screen.findByText("API unreachable")).toBeInTheDocument();
  });

  it("re-checks periodically and recovers", async () => {
    const fake = installFakeApi(SEED);
    fake.failAll({ network: true });
    renderApp(40);
    expect(await screen.findByText("API unreachable")).toBeInTheDocument();
    fake.failAll(null);
    expect(await screen.findByText("API healthy")).toBeInTheDocument();
  });
});
