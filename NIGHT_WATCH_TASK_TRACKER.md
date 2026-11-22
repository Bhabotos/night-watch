# Night Watch Task Tracker

Deadline: 22 November 2026, 11:59 PM. Legend: [ ] not started, [~] partial, [x] verified.
A box is ticked only when evidence exists in [docs/NIGHT_WATCH_EVIDENCE.md](docs/NIGHT_WATCH_EVIDENCE.md).
Last updated: 2026-11-22 04:20 UTC (10:20 Bangladesh time, UTC+6). All timestamps in this file and the evidence log are UTC unless marked.

| # | Task | Marks | Status | Notes |
|---|---|---|---|---|
| 1 | Prometheus Setup | 15 | [x] | 9/9 targets UP, Blackbox probe verified, 8 PromQL results recorded. Screenshots `04` (targets), `05` (alerts) and `06` (compose ps) captured 2026-11-22. |
| 2 | Grafana Setup | 10 | [x] | Grafana healthy, provisioned Prometheus datasource health OK, 6 dashboards loaded. Screenshot `01` (dashboards list) captured 2026-11-22; optional: a datasource "Save & test" screenshot. |
| 3 | Community Dashboard | 10 | [x] | Node Exporter Full (ID 1860, rev 46) provisioned; 255 queries return data, 46 empty (collectors unavailable in the Docker VM), 0 errors. Screenshot `02` captured 2026-11-22. |
| 4 | Three-Tier App Dashboard | 20 | [x] | "Three-Tier App – Production": 19 panels, 4 rows, 4 types (stat, gauge, timeseries, table); 23/23 queries return data. Screenshot `03` captured 2026-11-22 (all four rows, with traffic); `08`/`11` show the DOWN and recovered states. |
| 5 | Alerting | 20 | [x] | 9 rules unit-tested; local webhook channel configured and loaded; controlled frontend failure 2026-11-21 18:14-18:17Z: DOWN, FIRING, notification delivered (webhook sent=2, failed=0), recovered, RESOLVED. Demo repeated 2026-11-22 04:30-04:34 UTC: real screenshots `08`-`11` and raw log. Telegram optional, not configured. |
| 6 | GitHub CI/CD | 15 | [x] | Repo https://github.com/Bhabotos/night-watch; PR #1 green run 44986089290 (19/19 checks), PR #2 deliberate failure run 44986168079 (promtool rejects the bad `BackendDown` expression) and green run 44986230651 after the fix; screenshots `12`-`14`. Deploy workflow is **prepared, not executed** (no VPS details or secrets); PRs are open, nothing merged. |
| 7 | README Questions | 10 | [x] | The 4 answers are in README.md (lines 93-139) with a community-dashboard rationale; wording reviewed. Final screenshot links can still be added. |

## Phases

| Phase | Status |
|---|---|
| 0 Audit | [x] |
| 1 Gap analysis | [x] |
| 2 Prometheus, Blackbox, alert rules, Alertmanager | [x] implemented and validated; changes uncommitted |
| 3 Grafana community and production dashboards | [x] implemented and validated; uncommitted |
| 4 Alert notification and demo | [x] controlled demo completed with the local webhook channel; Telegram optional and unconfigured |
| 5 GitHub Actions | [x] validation runs verified on GitHub (green, red, green); deploy prepared, not executed |
| 6 Evidence and README answers | [x] README answers, screenshots 01-14, evidence log; PRs await merge approval |

## Open items
- [ ] Optional: a human-readable channel (Discord webhook or Telegram) for stronger Task 5 evidence.
- [x] Task 5 screenshots: demo repeated 2026-11-22 04:30-04:34 UTC (10:30-10:34 Bangladesh time) with real browser screenshots `08`-`11` in `evidence/screenshots/` and raw log `evidence/alert_demo_2026-11-22T0430Z.txt`.
- [ ] Deployment target and method for the main-branch deploy.
- [x] Updated `docs/decisions.md` #8 and #58 (Grafana Alerting replaced by Prometheus rules + Alertmanager) and `docs/prometheus.md` (2026-11-22).
- [x] `monitoring-3tier-prometheus-1` was found **Exited (255)** after Docker Desktop was started on 2026-11-22 04:07 UTC (10:07 Bangladesh time). Started with `docker start monitoring-3tier-prometheus-1` on 2026-11-22 (approved); 9/9 targets UP and 406/406 dashboard queries pass again (see evidence Phase 6).
- [x] Created `Bhabotos/night-watch` (public), remote `night-watch`, branch `night-watch-submission` (`f9eba60`), PR #1 and PR #2 with real Actions runs (2026-11-22 04:38-04:43 UTC).
- [ ] Merge PR #1 into `main` (needs separate approval; starts the deploy workflow, which will stop at the SSH step without secrets). Close PR #2 without merging.
- [ ] Hetzner: VPS IP/hostname, Ubuntu version, deploy user, verified host-key fingerprint, GitHub `production` secrets.
- [x] `tests/e2e/check_phase6.sh`, `check_phase7.sh` and `grafana_panels_check.py` fixed; 12 regression tests added (Phase 4 evidence).
- [ ] Update `docs/grafana.md` for the two new dashboards.
- [ ] Commit the Phase 2, 3 and 4 changes (awaiting approval; nothing committed or pushed).
