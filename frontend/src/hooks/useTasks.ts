import { useCallback, useEffect, useRef, useState } from "react";

import * as api from "../api/client";
import type { Task, TaskCounts, TaskCreate, TaskPatch } from "../types/task";

const EMPTY_COUNTS: TaskCounts = { total: 0, todo: 0, in_progress: 0, done: 0 };

export interface TasksState {
  tasks: Task[];
  counts: TaskCounts;
  truncated: boolean;
  loading: boolean;
  error: api.ApiError | null;
  refresh: (options?: { silent?: boolean }) => Promise<void>;
  create: (data: TaskCreate) => Promise<void>;
  update: (id: number, data: TaskPatch) => Promise<void>;
  remove: (id: number) => Promise<void>;
}

export function useTasks(): TasksState {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [counts, setCounts] = useState<TaskCounts>(EMPTY_COUNTS);
  const [truncated, setTruncated] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<api.ApiError | null>(null);
  const latest = useRef(0);
  const mounted = useRef(true);

  const refresh = useCallback(async ({ silent = false }: { silent?: boolean } = {}) => {
    const ticket = ++latest.current; // ignore out-of-order responses
    if (!silent) setLoading(true);
    try {
      const [all, totals] = await Promise.all([api.listAllTasks(), api.countTasks()]);
      if (!mounted.current || ticket !== latest.current) return;
      setTasks(all.tasks);
      setTruncated(all.truncated);
      setCounts(totals);
      setError(null);
    } catch (e) {
      if (!mounted.current || ticket !== latest.current) return;
      setError(e instanceof api.ApiError ? e : new api.ApiError(0, "unknown", "Something went wrong."));
    } finally {
      if (mounted.current && ticket === latest.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    mounted.current = true;
    void refresh();
    return () => {
      mounted.current = false;
    };
  }, [refresh]);

  // Mutations throw ApiError to the caller (dialogs show it), then reload.
  const create = useCallback(async (data: TaskCreate) => {
    await api.createTask(data);
    await refresh({ silent: true });
  }, [refresh]);

  const update = useCallback(async (id: number, data: TaskPatch) => {
    await api.updateTask(id, data);
    await refresh({ silent: true });
  }, [refresh]);

  const remove = useCallback(async (id: number) => {
    await api.deleteTask(id);
    await refresh({ silent: true });
  }, [refresh]);

  return { tasks, counts, truncated, loading, error, refresh, create, update, remove };
}
