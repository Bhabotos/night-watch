import { useState, type KeyboardEvent } from "react";

import { ApiError } from "../api/client";
import type { Task } from "../types/task";

interface Props {
  task: Task;
  onConfirm: () => Promise<void>;
  onClose: () => void;
}

export function ConfirmDialog({ task, onConfirm, onClose }: Props) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function confirm() {
    setBusy(true);
    setError(null);
    try {
      await onConfirm();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Something went wrong. Please try again.");
      setBusy(false);
    }
  }

  function handleKeyDown(event: KeyboardEvent) {
    if (event.key === "Escape" && !busy) onClose();
  }

  return (
    <div className="overlay" onKeyDown={handleKeyDown}>
      <div className="dialog" role="alertdialog" aria-modal="true" aria-labelledby="confirm-title">
        <h2 id="confirm-title">Delete task?</h2>
        <p>
          “{task.title}” will be permanently deleted. This cannot be undone.
        </p>
        {error && (
          <p className="banner banner--error" role="alert">
            {error}
          </p>
        )}
        <div className="dialog__actions">
          <button type="button" className="btn" onClick={onClose} disabled={busy} autoFocus>
            Cancel
          </button>
          <button type="button" className="btn btn--danger" onClick={() => void confirm()} disabled={busy}>
            {busy ? "Deleting…" : "Delete"}
          </button>
        </div>
      </div>
    </div>
  );
}
