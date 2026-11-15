import { describe, expect, it } from "vitest";

import { formatDate, validateTaskForm } from "./validate";

describe("validateTaskForm", () => {
  it("accepts a normal task", () => {
    expect(validateTaskForm("Write docs", "details")).toEqual({});
  });

  it.each(["", "   ", "\n\t"])("rejects a blank title %j", (title) => {
    expect(validateTaskForm(title, "").title).toBe("Title is required.");
  });

  it("measures the title after trimming, up to 200 characters", () => {
    expect(validateTaskForm(`  ${"a".repeat(200)}  `, "")).toEqual({});
    expect(validateTaskForm("a".repeat(201), "").title).toContain("200");
  });

  it("limits the description to 5000 characters", () => {
    expect(validateTaskForm("t", "d".repeat(5000))).toEqual({});
    expect(validateTaskForm("t", "d".repeat(5001)).description).toContain("5000");
  });
});

describe("formatDate", () => {
  it("returns the input unchanged when it is not a date", () => {
    expect(formatDate("not-a-date")).toBe("not-a-date");
  });

  it("formats valid ISO dates", () => {
    expect(formatDate("2026-01-01T00:00:00Z")).not.toBe("2026-01-01T00:00:00Z");
  });
});
