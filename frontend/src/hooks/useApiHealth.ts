import { useEffect, useState } from "react";

import { probeApi, type ApiHealth } from "../api/client";

export type HealthState = ApiHealth | "checking";

export function useApiHealth(intervalMs: number): { status: HealthState; checkedAt: Date | null } {
  const [status, setStatus] = useState<HealthState>("checking");
  const [checkedAt, setCheckedAt] = useState<Date | null>(null);

  useEffect(() => {
    let active = true;
    const check = async () => {
      const result = await probeApi();
      if (!active) return;
      setStatus(result);
      setCheckedAt(new Date());
    };
    void check();
    const timer = window.setInterval(() => void check(), intervalMs);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, [intervalMs]);

  return { status, checkedAt };
}
