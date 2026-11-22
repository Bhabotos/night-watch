"""Guard-rail tests for the GitHub Actions workflows (no network, no Docker, standard library only).

They prove, from the workflow files themselves, that:
  - validation runs on every pull request and holds no secrets;
  - deployment can only start from a push to main, only after validation succeeded, and only through the
    `production` environment (so a failed validation can never trigger a deployment);
  - SSH uses a verified host key and secrets only; no key material is committed.

Run from the repo root:  python -I -m unittest discover -s tests/ci -p "test_*.py" -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(text: str) -> str:
    """The file without comment-only lines, so explanations in comments cannot trigger or mask a check."""
    return "".join(line for line in text.splitlines(keepends=True) if not line.lstrip().startswith("#"))


def block(text: str, name: str) -> str:
    """The text of the top-level `on:` / job block called `name` (indentation based, good enough for these files)."""
    match = re.search(rf"^(\s*){re.escape(name)}:\s*\n((?:\1\s+.*\n|\s*\n)+)", text, re.MULTILINE)
    return match.group(2) if match else ""


VALIDATE = code(read(WORKFLOWS / "monitoring-validate.yml"))
DEPLOY = code(read(WORKFLOWS / "monitoring-deploy.yml"))
REMOTE = code(read(ROOT / "scripts" / "deploy_remote.sh"))


class ValidationWorkflow(unittest.TestCase):
    def test_runs_on_every_pull_request_without_filters(self):
        triggers = block(VALIDATE, "on")
        self.assertIn("pull_request:", triggers)
        self.assertNotRegex(triggers, r"pull_request:\s*\n\s+(branches|paths)")  # no branch or path filter

    def test_is_reusable_by_the_deploy_workflow(self):
        self.assertIn("workflow_call:", VALIDATE)

    def test_uses_no_secrets_and_read_only_permissions(self):
        self.assertNotIn("secrets.", VALIDATE)
        self.assertRegex(VALIDATE, r"permissions:\s*\n\s+contents: read")

    def test_never_uses_pull_request_target(self):
        self.assertNotIn("pull_request_target", VALIDATE + DEPLOY)

    def test_runs_the_validation_script(self):
        self.assertIn("scripts/validate_monitoring.sh", VALIDATE)


class DeployWorkflow(unittest.TestCase):
    def test_triggers_only_on_push_to_main(self):
        triggers = block(DEPLOY, "on")
        self.assertRegex(triggers, r"push:\s*\n\s+branches: \[main\]")
        for forbidden in ("pull_request", "workflow_dispatch", "schedule", "workflow_run"):
            self.assertNotIn(forbidden, triggers)

    def test_deploy_job_requires_successful_validation(self):
        deploy_job = block(DEPLOY, "deploy")
        self.assertRegex(deploy_job, r"needs: validate\b")
        self.assertIn("uses: ./.github/workflows/monitoring-validate.yml", block(DEPLOY, "validate"))

    def test_deploy_job_is_restricted_to_main_and_production_environment(self):
        deploy_job = block(DEPLOY, "deploy")
        self.assertIn("github.ref == 'refs/heads/main'", deploy_job)
        self.assertRegex(deploy_job, r"environment: production\b")

    def test_deployments_do_not_overlap_or_cancel(self):
        self.assertRegex(DEPLOY, r"concurrency:\s*\n\s+group: deploy-production\s*\n\s+cancel-in-progress: false")

    def test_ssh_verifies_the_host_key_and_uses_only_secrets(self):
        self.assertIn("StrictHostKeyChecking yes", DEPLOY)
        self.assertNotRegex(DEPLOY + REMOTE, r"StrictHostKeyChecking[ =]no|ssh-keyscan\s")
        for secret in ("DEPLOY_HOST", "DEPLOY_USER", "DEPLOY_PATH", "DEPLOY_SSH_KEY", "DEPLOY_KNOWN_HOSTS"):
            self.assertIn(f"secrets.{secret}", DEPLOY)

    def test_never_uploads_env_files_and_stages_before_going_live(self):
        self.assertIn("--exclude '.env'", DEPLOY)
        self.assertIn("/incoming/", DEPLOY)

    def test_final_step_runs_the_remote_deploy_script(self):
        self.assertRegex(DEPLOY, r'ssh vps "bash -s -- .*" < scripts/deploy_remote\.sh')

    def test_deployment_user_must_not_be_root(self):
        self.assertIn('test "$(id -u)" != 0', DEPLOY)
        self.assertIn('[ "$(id -u)" != 0 ]', REMOTE)


class RemoteScript(unittest.TestCase):
    def test_has_health_checks_and_rollback(self):
        for needle in ("healthy()", "rollback()", "docker compose config -q", "count(up%3D%3D0)"):
            self.assertIn(needle, REMOTE)

    def test_is_not_destructive_and_never_touches_env(self):
        self.assertNotRegex(REMOTE, r"down\s+-v|--volumes|system prune|volume (rm|prune)|image (rm|prune)|rmi\b")
        self.assertIn("--exclude='.env'", REMOTE)
        self.assertNotRegex(REMOTE, r"cat\s+\S*\.env|echo\s+.*\$\{?(TELEGRAM|GRAFANA|POSTGRES)")


class NoSecretsCommitted(unittest.TestCase):
    def test_no_key_material_or_tokens_in_workflows_and_scripts(self):
        pattern = re.compile(r"BEGIN (OPENSSH|RSA|EC) PRIVATE KEY|[0-9]{8,10}:[A-Za-z0-9_-]{35}|ghp_[A-Za-z0-9]{30,}")
        for path in [*WORKFLOWS.glob("*.yml"), ROOT / "scripts" / "deploy_remote.sh", ROOT / "scripts" / "validate_monitoring.sh"]:
            self.assertIsNone(pattern.search(path.read_text(encoding="utf-8")), path.name)


if __name__ == "__main__":
    unittest.main()
