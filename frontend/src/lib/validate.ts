import { DESCRIPTION_MAX, TITLE_MAX } from "../types/task";

export interface FormErrors {
  title?: string;
  description?: string;
}

/** Client-side mirror of the backend rules (title 1-200 after trimming, description <= 5000). */
export function validateTaskForm(title: string, description: string): FormErrors {
  const errors: FormErrors = {};
  const trimmed = title.trim();
  if (trimmed.length === 0) errors.title = "Title is required.";
  else if (trimmed.length > TITLE_MAX) errors.title = `Title must be at most ${TITLE_MAX} characters.`;
  if (description.length > DESCRIPTION_MAX) {
    errors.description = `Description must be at most ${DESCRIPTION_MAX} characters.`;
  }
  return errors;
}

export function formatDate(iso: string): string {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString();
}
