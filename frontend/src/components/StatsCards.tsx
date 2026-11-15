import type { TaskCounts } from "../types/task";

interface Props {
  counts: TaskCounts;
  loading: boolean;
}

const CARDS: { key: keyof TaskCounts; label: string; tone: string }[] = [
  { key: "total", label: "Total tasks", tone: "total" },
  { key: "todo", label: "Pending", tone: "todo" },
  { key: "in_progress", label: "In progress", tone: "progress" },
  { key: "done", label: "Completed", tone: "done" },
];

export function StatsCards({ counts, loading }: Props) {
  return (
    <section className="stats" aria-label="Task overview">
      {CARDS.map(({ key, label, tone }) => (
        <div key={key} className={`stat stat--${tone}`}>
          <span className="stat__label">{label}</span>
          <span className="stat__value" data-testid={`count-${key}`}>
            {loading ? "–" : counts[key]}
          </span>
        </div>
      ))}
    </section>
  );
}
