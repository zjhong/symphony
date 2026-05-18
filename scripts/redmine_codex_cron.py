#!/usr/bin/env python3
"""Poll Redmine issues and run Codex CLI on one development task.

This is the thin "prove the loop" runner:

Redmine issue -> isolated workspace -> Codex CLI -> Redmine comment/status.

It intentionally keeps policy in environment variables/flags so credentials and
repository mapping do not get baked into the codebase.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import textwrap
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_ACTIVE_STATES = ["新建", "进行中", "反馈"]
DEFAULT_TERMINAL_STATES = ["已关闭", "已拒绝"]


class RedmineError(RuntimeError):
    pass


def main() -> int:
    args = parse_args()
    redmine_url = env_required("REDMINE_URL").rstrip("/")
    api_key = env_required("REDMINE_API_KEY")

    client = RedmineClient(redmine_url, api_key)
    state_dir = Path(args.state_dir).expanduser().resolve()
    workspace_root = Path(args.workspace_root).expanduser().resolve()
    state_dir.mkdir(parents=True, exist_ok=True)
    workspace_root.mkdir(parents=True, exist_ok=True)

    issues = [client.get_issue(args.issue_id)] if args.issue_id else client.list_candidate_issues(args)
    if not issues:
        print("No matching Redmine issues.")
        return 0

    for issue in issues[: args.limit]:
        if should_skip_issue(issue, args):
            continue

        repo = select_repo(issue, args)
        if not repo:
            print(f"Skip #{issue['id']}: no repo mapping. Set --repo or REDMINE_REPO_MAP.")
            continue

        print_issue(issue, repo)
        if not args.execute:
            print("Dry run only. Re-run with --execute to claim and run Codex.")
            continue

        return run_issue(client, issue, repo, workspace_root, state_dir, args)

    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Codex against Redmine development issues.")
    parser.add_argument("--execute", action="store_true", help="Actually claim the issue and invoke Codex.")
    parser.add_argument("--issue-id", help="Run a specific Redmine issue id instead of polling.")
    parser.add_argument("--project", help="Redmine project identifier or id filter.")
    parser.add_argument("--assigned-to", default="me", help="Redmine assignee id or 'me'. Default: me.")
    parser.add_argument("--tracker", help="Optional Redmine tracker id filter.")
    parser.add_argument("--limit", type=int, default=1, help="Max issues to consider. Default: 1.")
    parser.add_argument("--repo", help="Fallback local path or git URL for all issues.")
    parser.add_argument(
        "--repo-map",
        default=os.environ.get("REDMINE_REPO_MAP", ""),
        help="JSON map from Redmine project identifier/name/id to local path or git URL.",
    )
    parser.add_argument(
        "--active-states",
        default=",".join(DEFAULT_ACTIVE_STATES),
        help="Comma-separated Redmine status names eligible for work.",
    )
    parser.add_argument(
        "--terminal-states",
        default=",".join(DEFAULT_TERMINAL_STATES),
        help="Comma-separated Redmine status names never eligible for work.",
    )
    parser.add_argument("--in-progress-status", default="进行中", help="Status name used when claiming.")
    parser.add_argument("--done-status", default="已解决", help="Status name used after Codex exits 0.")
    parser.add_argument(
        "--workspace-root",
        default=os.environ.get("REDMINE_CODEX_WORKSPACE_ROOT", "./tmp/redmine-codex-workspaces"),
        help="Workspace root for cloned task repos.",
    )
    parser.add_argument(
        "--state-dir",
        default=os.environ.get("REDMINE_CODEX_STATE_DIR", "./tmp/redmine-codex-state"),
        help="State/log root.",
    )
    parser.add_argument(
        "--codex-command",
        default=os.environ.get(
            "CODEX_COMMAND",
            "codex exec --ask-for-approval never --sandbox workspace-write --skip-git-repo-check < {prompt_file}",
        ),
        help="Shell command template. Supports {prompt_file}, {issue_id}, {workspace}.",
    )
    parser.add_argument("--branch-prefix", default="codex/redmine-", help="Branch prefix for task workspaces.")
    parser.add_argument("--no-status-updates", action="store_true", help="Only write comments, do not change status.")
    return parser.parse_args()


def run_issue(
    client: "RedmineClient",
    issue: dict[str, Any],
    repo: str,
    workspace_root: Path,
    state_dir: Path,
    args: argparse.Namespace,
) -> int:
    issue_id = str(issue["id"])
    lock_path = state_dir / f"{issue_id}.lock"
    if lock_path.exists():
        print(f"Skip #{issue_id}: lock exists at {lock_path}")
        return 0

    lock_path.write_text(str(os.getpid()), encoding="utf-8")
    try:
        if not args.no_status_updates:
            client.update_issue(issue_id, status_name=args.in_progress_status, notes=claim_note())
        else:
            client.update_issue(issue_id, notes=claim_note())

        workspace = prepare_workspace(repo, workspace_root, issue, args.branch_prefix)
        prompt_file = write_prompt(workspace, issue, client.base_url)
        command = render_command(args.codex_command, prompt_file, issue_id, workspace)
        log_path = state_dir / f"{issue_id}.codex.log"

        print(f"Running Codex in {workspace}")
        print(f"Command: {command}")
        result = run_command(command, workspace, log_path)

        if result == 0:
            done_note = completion_note(log_path)
            if args.no_status_updates:
                client.update_issue(issue_id, notes=done_note)
            else:
                client.update_issue(issue_id, status_name=args.done_status, notes=done_note)
        else:
            client.update_issue(issue_id, notes=f"AI 自动开发失败，退出码 {result}。日志：{log_path}")

        return result
    finally:
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass


def prepare_workspace(repo: str, workspace_root: Path, issue: dict[str, Any], branch_prefix: str) -> Path:
    issue_id = str(issue["id"])
    workspace = workspace_root / f"RM-{issue_id}"

    if not workspace.exists():
        subprocess.run(["git", "clone", repo, str(workspace)], check=True)

    branch = safe_branch_name(branch_prefix + issue_id + "-" + str(issue.get("subject", "task")))
    subprocess.run(["git", "fetch", "--all", "--prune"], cwd=workspace, check=False)
    subprocess.run(["git", "checkout", "-B", branch], cwd=workspace, check=True)
    return workspace


def write_prompt(workspace: Path, issue: dict[str, Any], redmine_url: str) -> Path:
    issue_id = str(issue["id"])
    prompt = textwrap.dedent(
        f"""
        You are running unattended from Redmine issue RM-{issue_id}.

        Redmine URL: {redmine_url}/issues/{issue_id}
        Project: {nested_name(issue, "project")}
        Tracker: {nested_name(issue, "tracker")}
        Status: {nested_name(issue, "status")}
        Priority: {nested_name(issue, "priority")}

        Title:
        {issue.get("subject", "")}

        Description:
        {issue.get("description") or "(no description)"}

        Requirements:
        - Inspect the repository before editing.
        - Implement the smallest safe change that satisfies the Redmine issue.
        - Run the relevant tests or checks you can discover locally.
        - Commit your changes on the current branch.
        - If GitHub remote auth is available, push the branch and open a draft PR.
        - If blocked, leave a concise explanation in your final response and do not fake success.

        Final response must include:
        - Summary of changes.
        - Tests/checks run.
        - Branch name and PR URL if created.
        - Any blocker that needs a human.
        """
    ).strip()

    prompt_file = workspace / ".redmine-codex-prompt.md"
    prompt_file.write_text(prompt + "\n", encoding="utf-8")
    return prompt_file


def run_command(command: str, workspace: Path, log_path: Path) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
      process = subprocess.Popen(
          command,
          cwd=workspace,
          shell=True,
          stdout=subprocess.PIPE,
          stderr=subprocess.STDOUT,
          text=True,
          bufsize=1,
      )
      assert process.stdout is not None
      for line in process.stdout:
          sys.stdout.write(line)
          log.write(line)
      return process.wait()


def render_command(command: str, prompt_file: Path, issue_id: str, workspace: Path) -> str:
    values = {
        "prompt_file": shlex.quote(str(prompt_file)),
        "issue_id": shlex.quote(issue_id),
        "workspace": shlex.quote(str(workspace)),
    }
    return command.format(**values)


def should_skip_issue(issue: dict[str, Any], args: argparse.Namespace) -> bool:
    status = nested_name(issue, "status")
    terminal = split_csv(args.terminal_states)
    active = split_csv(args.active_states)

    if status in terminal:
        print(f"Skip #{issue['id']}: terminal status {status}")
        return True
    if active and status not in active:
        print(f"Skip #{issue['id']}: status {status} not in {active}")
        return True
    return False


def select_repo(issue: dict[str, Any], args: argparse.Namespace) -> str:
    if args.repo:
        return args.repo

    repo_map = load_repo_map(args.repo_map)
    project = issue.get("project") or {}
    keys = [str(project.get("identifier") or ""), str(project.get("name") or ""), str(project.get("id") or "")]
    for key in keys:
        if key and key in repo_map:
            return repo_map[key]
    return ""


def load_repo_map(raw: str) -> dict[str, str]:
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid REDMINE_REPO_MAP JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit("REDMINE_REPO_MAP must be a JSON object.")
    return {str(k): str(v) for k, v in data.items()}


def print_issue(issue: dict[str, Any], repo: str) -> None:
    print(
        f"Candidate #{issue['id']} [{nested_name(issue, 'status')}] "
        f"{nested_name(issue, 'project')}: {issue.get('subject', '')}\n  repo: {repo}"
    )


def claim_note() -> str:
    return f"AI 自动开发已领取任务。时间戳：{int(time.time())}"


def completion_note(log_path: Path) -> str:
    return f"AI 自动开发已完成本地执行。请检查 GitHub PR/分支和日志：{log_path}"


def safe_branch_name(value: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9._/-]+", "-", value).strip("-")
    return normalized[:120] or "codex/redmine-task"


def nested_name(issue: dict[str, Any], key: str) -> str:
    value = issue.get(key)
    if isinstance(value, dict):
        return str(value.get("name") or value.get("id") or "")
    return ""


def split_csv(raw: str) -> list[str]:
    return [item.strip() for item in raw.split(",") if item.strip()]


def env_required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


class RedmineClient:
    def __init__(self, base_url: str, api_key: str) -> None:
        self.base_url = base_url
        self.api_key = api_key

    def list_candidate_issues(self, args: argparse.Namespace) -> list[dict[str, Any]]:
        params: dict[str, Any] = {
            "status_id": "open",
            "assigned_to_id": args.assigned_to,
            "limit": max(args.limit, 1),
            "sort": "updated_on:desc",
        }
        if args.project:
            params["project_id"] = args.project
        if args.tracker:
            params["tracker_id"] = args.tracker

        data = self.get("/issues.json", params)
        return list(data.get("issues") or [])

    def get_issue(self, issue_id: str) -> dict[str, Any]:
        data = self.get(f"/issues/{issue_id}.json", {"include": "attachments,journals"})
        issue = data.get("issue")
        if not isinstance(issue, dict):
            raise RedmineError(f"Redmine issue not found or malformed: {issue_id}")
        return issue

    def update_issue(self, issue_id: str, *, notes: str | None = None, status_name: str | None = None) -> None:
        issue: dict[str, Any] = {}
        if notes:
            issue["notes"] = notes
        if status_name:
            issue["status_id"] = self.resolve_status_id(status_name)
        if not issue:
            return
        self.put(f"/issues/{issue_id}.json", {"issue": issue})

    def resolve_status_id(self, status_name: str) -> int:
        data = self.get("/issue_statuses.json", {})
        for status in data.get("issue_statuses") or []:
            if str(status.get("name", "")).strip() == status_name:
                return int(status["id"])
        raise RedmineError(f"Redmine status not found: {status_name}")

    def get(self, path: str, params: dict[str, Any]) -> dict[str, Any]:
        url = self.base_url + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers=self.headers())
        return self.open_json(req)

    def put(self, path: str, payload: dict[str, Any]) -> None:
        req = urllib.request.Request(
            self.base_url + path,
            headers={**self.headers(), "Content-Type": "application/json"},
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            method="PUT",
        )
        self.open_json(req, allow_empty=True)

    def open_json(self, req: urllib.request.Request, allow_empty: bool = False) -> dict[str, Any]:
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                if not raw and allow_empty:
                    return {}
                return json.loads(raw or "{}")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RedmineError(f"HTTP {exc.code} for {req.full_url}: {body}") from exc
        except urllib.error.URLError as exc:
            raise RedmineError(f"Connection error for {req.full_url}: {exc.reason}") from exc

    def headers(self) -> dict[str, str]:
        return {"X-Redmine-API-Key": self.api_key, "Accept": "application/json"}


if __name__ == "__main__":
    raise SystemExit(main())
