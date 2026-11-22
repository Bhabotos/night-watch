# Night Watch: CI/CD and Hetzner VPS deployment

Status: **deployment prepared, not executed.** The repository `Bhabotos/night-watch` exists and the validation workflow has run on GitHub (see the evidence table below); no `production` secret exists and no server has been touched.

## Pipeline

| Workflow | Trigger | What it does |
|---|---|---|
| `.github/workflows/monitoring-validate.yml` | **every pull request**, `workflow_call`, manual | `scripts/validate_monitoring.sh`: `docker compose config`, `promtool check config` and `check rules`, `promtool test rules` (alerts and recording), `amtool check-config`, `blackbox_exporter --config.check`, JSON validity of every dashboard, dashboard lint and regression tests (required dashboards, "Three-Tier App – Production" with 6+ panels, 3+ visualization types, rows per tier), workflow guard-rail tests, secret scan. No secrets used. |
| `.github/workflows/monitoring-deploy.yml` | **push to `main` only** | Job `validate` (the workflow above) -> job `deploy` (`needs: validate`, `environment: production`) -> SSH to the VPS, stage, validate, back up, swap, health-check, automatic rollback. |

A failed validation cannot deploy because (a) the deploy workflow does not run on pull requests at all, (b) on `main` the `deploy` job `needs` the `validate` job, so a failure stops it, and (c) the job
is bound to the `production` environment, which can require a human approval. `tests/ci/test_workflows.py` asserts (a) to (c) from the workflow files on every run.

## Deployment design (`scripts/deploy_remote.sh`, runs on the VPS as the deployment user)

```
<DEPLOY_PATH>/app        live copy (compose runs here) + the server-only .env  (never written by the pipeline)
<DEPLOY_PATH>/incoming   uploaded copy (staging)
<DEPLOY_PATH>/backups    pre-<time>-<sha>.tgz of the previous app/ without .env (last 5 kept)
```
1. Validate `incoming` with the server's `.env` (`docker compose config -q`).  2. Back up the live copy.  3. Sync `incoming` into `app` (`.env` excluded).
4. `docker compose up -d --build --wait`, reload Prometheus (SIGHUP), restart Alertmanager (its config is read at start).
5. Health checks for up to ~2 minutes: no container unhealthy/starting, **no Prometheus target with `up == 0`**, Grafana `/api/health` ok, Alertmanager healthy.
6. **Any failure after the swap restores the backup and re-applies it**, then fails the job. Old backups are pruned.
It never runs `down -v`, never removes volumes or images, never prunes, and never prints `.env`.

Manual rollback (as the deployment user on the VPS): `cd <DEPLOY_PATH> && ls backups/`, then
`tar -xzf backups/<chosen>.tgz -C /tmp/nw-restore` (after `mkdir /tmp/nw-restore`), `rsync -a --delete --exclude=.env /tmp/nw-restore/app/ app/`, `cd app && docker compose up -d --wait && docker compose kill -s HUP prometheus && docker compose restart alertmanager`.

## What you must set up (I did not, and will not, create these)

### On the VPS
1. A **non-root** user, e.g. `deploy`, with a key-only login (no password) and Docker access. **Note:** membership of the `docker` group is effectively root on that host. Mitigations:
   restrict the key in `authorized_keys` (`from="<GitHub runner ranges>"` is impractical, so use `restrict`), keep the VPS dedicated to this stack, or use rootless Docker for this user.
2. Docker Engine and the Compose plugin (v2.20 or newer, needs `--wait`), `rsync`, `tar`, `bash`.
3. The directory `<DEPLOY_PATH>` (for example `/opt/night-watch`) owned by `deploy`, and `<DEPLOY_PATH>/app/.env` created **once, by you, on the server**, from `.env.example`, with strong secrets
   (and `TELEGRAM_*` only if you use Telegram). chmod 600.
4. A firewall that exposes only SSH (and, if you want, a reverse proxy). The stack binds Grafana, Prometheus and the frontend to `127.0.0.1`, so use an SSH tunnel to look at them.
5. Prometheus, Grafana, Alertmanager and the app share one compose project: if the VPS already runs another stack on 8088, 3001 or 9090, tell me before the first deployment.

### In GitHub (repository Settings)
1. **Environment `production`**: add *Required reviewers* (you) and restrict deployment branches to `main`.
2. **Environment secrets** (not repository secrets): `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_PORT` (optional, default 22), `DEPLOY_PATH`, `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`.
3. **Branch protection on `main`**: require a pull request and the status check *Validate monitoring configuration* before merging.
4. Generate the SSH key **yourself**, on your machine: `ssh-keygen -t ed25519 -f nightwatch_deploy -C github-actions-deploy`, put `nightwatch_deploy.pub` into `~deploy/.ssh/authorized_keys` on the VPS,
   paste the private key file's content into the `DEPLOY_SSH_KEY` secret, then delete the local private key file. Never paste the private key anywhere else.
5. **Verified host key** -> `DEPLOY_KNOWN_HOSTS`: on the VPS run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` (or read the fingerprint in the Hetzner console), then from your machine run
   `ssh-keyscan -t ed25519 <VPS IP>` and **compare the fingerprint** (`ssh-keygen -lf -` on that output) with the one from the server before storing the line as the secret.
   The workflow uses `StrictHostKeyChecking yes` and never `ssh-keyscan`.

## Exact VPS information still required
1. Public IPv4 (or DNS name) of the VPS and the SSH port.
2. OS and version (for example Ubuntu 24.04) and the RAM / CPU / disk size (the stack needs about 3 GB of RAM).
3. Deployment user name and the deploy directory path you want (`DEPLOY_USER`, `DEPLOY_PATH`).
4. Docker Engine and Compose versions installed (`docker --version`, `docker compose version`), and how the deploy user gets Docker access.
5. Whether the stack **already runs** on the VPS (existing containers or volumes to adopt), or this is a fresh install; and any ports already in use.
6. The ed25519 host key **fingerprint** (not a key or password) so we can confirm `DEPLOY_KNOWN_HOSTS`.
7. The GitHub repository to use (name and owner), whether `main` is the default branch, and who approves production deployments.
8. How you will reach Grafana and Prometheus (SSH tunnel, or a reverse proxy with TLS and which domain).
9. Which notification channel the server should use (webhook receiver only, or Discord/Telegram), because its secrets belong in the server's `.env`.

## Creating the `night-watch` repository (done 2026-11-22 with a feature branch and a PR; kept for reference)

`gh` is logged in as `Bhabotos` (scopes `repo`, `workflow`). `Bhabotos/night-watch` does not exist. The existing remote `origin`
(`monitoring-3tier-project`) is left untouched; the new remote gets a different name.
```
cd D:\monitoring-3tier-project
git status --short                        # review: .env must NOT be listed
gh repo create Bhabotos/night-watch --public --description "Prometheus and Grafana based monitoring, alerting, and CI/CD for a three-tier application."
git remote add night-watch https://github.com/Bhabotos/night-watch.git
git switch -c night-watch-submission      # commit on a branch, not on main
git add -A && git status --short          # check again before committing
git commit -m "Night Watch: Prometheus, Grafana, Alertmanager, CI/CD"
git push night-watch night-watch-submission:main      # first push creates main (the default branch)
```
Then in GitHub: Settings > Environments > `production` (required reviewer), and branch protection on `main` (see above). The deploy
workflow starts on that first push to `main`; with no `production` secrets it will stop at the SSH step, so **create the Environment and
leave the secrets empty (or set them last) until the VPS is ready**. For the evidence runs, open a pull request from a feature branch:
the validation workflow runs on it automatically.

## Evidence plan (Task 6)
| Evidence | How | Status |
|---|---|---|
| Workflow YAML | `.github/workflows/*.yml`: parsed with PyYAML, triggers and `permissions: contents: read` checked by `tests/ci/test_workflows.py` (actionlint has **not** been run) | parsed OK |
| Successful validation, locally | `sh scripts/validate_monitoring.sh` | done, 2026-11-22 (see `docs/NIGHT_WATCH_EVIDENCE.md`) |
| Failed validation, locally | `sh tests/ci/negative_test.sh` (throw-away copy, 5 injected faults) | done, 2026-11-22; a bug in fault 5 of the script was fixed first (see evidence) |
| Successful PR run on GitHub | PR #1, run 44986089290 | **done 2026-11-22, success** (screenshot `12`) |
| Failed run on GitHub | PR #2 (`ci-demo-invalid`): invalid `BackendDown` expression, run 44986168079; fixed in `b4c97c8`, run 44986230651 green | **done 2026-11-22: failure then success** (screenshots `13`, `14`) |
| Deployment on push to `main` | merge the PR after the green run and approve the `production` environment | **needs VPS + secrets + approval** |
