# Night Watch Plan

The existing `monitoring-3tier` repository is the single implementation workspace for the Module 6 "Night Watch" assignment.
Existing services (including Loki and Alloy), volumes, ports and dashboards are preserved; only missing requirements are added.
Progress: [NIGHT_WATCH_TASK_TRACKER.md](NIGHT_WATCH_TASK_TRACKER.md). Evidence: [docs/NIGHT_WATCH_EVIDENCE.md](docs/NIGHT_WATCH_EVIDENCE.md).

## Assignment tasks (100 marks)

| # | Task | Marks |
|---|---|---|
| 1 | Prometheus Setup | 15 |
| 2 | Grafana Setup | 10 |
| 3 | Community Dashboard | 10 |
| 4 | Three-Tier App Dashboard | 20 |
| 5 | Alerting | 20 |
| 6 | GitHub CI/CD | 15 |
| 7 | README Questions | 10 |

## Phases

| Phase | Scope | Validation |
|---|---|---|
| 2 (done) | Blackbox Exporter, frontend probe, alert rules, Alertmanager (Telegram placeholders) | promtool check and test, amtool, targets UP |
| 3 | Community dashboard (Node Exporter Full, ID 1860) and "Three-Tier App - Production" dashboard (6+ panels, 3+ visualization types) | Panels return data; existing `dashboards_lint.py` |
| 4 | Telegram bot, controlled firing and resolved demo (stop only a throwaway/test condition, with approval) | Telegram messages plus Alertmanager state |
| 5 | GitHub Actions: validate on every pull request; deploy to the selected server on push to main (GitHub Secrets) | Green run and an intentionally failing run |
| 6 | Evidence, README answers to the four questions | Checklist in the tracker |

## Operating rules
- Never overwrite `.env`; never commit secrets or Telegram tokens; secrets live in `.env` locally and GitHub Secrets in CI.
- No destructive Docker commands; no stop/restart of existing containers without approval; no new published ports.
- No push, merge, AWS or Terraform without approval.

## Preliminary documents
`D:\Module-6-Night-Watch` holds early planning files and an experimental copy of the stack. They are superseded by this plan.
Nothing there was deleted.
