import { STATUS_LABELS, TASK_STATUSES, type TaskStatus } from "../types/task";

export type StatusFilter = TaskStatus | "all";

interface Props {
  search: string;
  onSearch: (value: string) => void;
  filter: StatusFilter;
  onFilter: (value: StatusFilter) => void;
  onNew: () => void;
}

export function TaskToolbar({ search, onSearch, filter, onFilter, onNew }: Props) {
  return (
    <div className="toolbar" role="search">
      <label className="field field--grow">
        <span className="sr-only">Search tasks</span>
        <input
          type="search"
          placeholder="Search title or description…"
          value={search}
          onChange={(e) => onSearch(e.target.value)}
        />
      </label>
      <label className="field">
        <span className="sr-only">Filter by status</span>
        <select value={filter} onChange={(e) => onFilter(e.target.value as StatusFilter)}>
          <option value="all">All statuses</option>
          {TASK_STATUSES.map((s) => (
            <option key={s} value={s}>
              {STATUS_LABELS[s]}
            </option>
          ))}
        </select>
      </label>
      <button type="button" className="btn btn--primary" onClick={onNew}>
        New task
      </button>
    </div>
  );
}
