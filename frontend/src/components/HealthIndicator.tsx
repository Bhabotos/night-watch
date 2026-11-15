import type { HealthState } from "../hooks/useApiHealth";

const LABELS: Record<HealthState, string> = {
  checking: "Checking API…",
  healthy: "API healthy",
  degraded: "Database unavailable",
  unreachable: "API unreachable",
};

interface Props {
  status: HealthState;
  checkedAt: Date | null;
}

export function HealthIndicator({ status, checkedAt }: Props) {
  const title = checkedAt ? `Last checked ${checkedAt.toLocaleTimeString()}` : "Not checked yet";
  return (
    <div className={`health health--${status}`} role="status" aria-live="polite" title={title}>
      <span className="health__dot" aria-hidden="true" />
      <span>{LABELS[status]}</span>
    </div>
  );
}
