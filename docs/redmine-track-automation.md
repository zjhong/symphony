# Redmine Track Automation

This branch adds a Redmine path for proving:

```text
Redmine issue -> workspace -> Codex -> GitHub branch/PR -> Redmine update
```

There are two layers:

- `tracker.kind: redmine` in Symphony, for the long-running service path.
- `scripts/redmine_codex_cron.py`, for a small cron-friendly MVP that can run one real issue quickly.

## Environment

Do not put secrets in `WORKFLOW.md` or cron files.

```bash
export REDMINE_URL="https://redmine.example.com"
export REDMINE_API_KEY="your_redmine_api_key"
```

Optional repo mapping for the cron runner:

```bash
export REDMINE_REPO_MAP='{
  "my-project": "/path/to/my-repo",
  "My Project": "/path/to/my-repo",
  "1": "/path/to/my-repo"
}'
```

The key can be the Redmine project identifier, project name, or project id.

## Quick Dry Run

Dry run reads Redmine and prints the first matching issue. It does not update Redmine and does not run Codex.

```bash
cd /path/to/symphony
REDMINE_URL="https://redmine.example.com" \
REDMINE_API_KEY="$REDMINE_API_KEY" \
scripts/redmine_codex_cron.py --limit 1 --repo /path/to/target/repo
```

Run a specific issue without polling:

```bash
scripts/redmine_codex_cron.py --issue-id 2100 --repo /path/to/target/repo
```

## Execute One Real Task

This claims the issue, checks out a task branch in an isolated workspace, runs Codex, then comments back to Redmine.

```bash
cd /path/to/symphony
export REDMINE_URL="https://redmine.example.com"
export REDMINE_API_KEY="your_redmine_api_key"

scripts/redmine_codex_cron.py \
  --execute \
  --issue-id 2100 \
  --repo /path/to/target/repo \
  --workspace-root /path/to/redmine-codex-workspaces \
  --state-dir /path/to/redmine-codex-state
```

If your local Codex CLI needs a different invocation, override it:

```bash
export CODEX_COMMAND='codex exec --ask-for-approval never --sandbox workspace-write --skip-git-repo-check < {prompt_file}'
```

The template supports:

- `{prompt_file}`
- `{issue_id}`
- `{workspace}`

## Cron Example

Use absolute paths in cron:

```cron
*/10 * * * * REDMINE_URL=https://redmine.example.com REDMINE_API_KEY=your_redmine_api_key REDMINE_REPO_MAP='{"my-project":"/path/to/my-repo"}' /path/to/symphony/scripts/redmine_codex_cron.py --execute --limit 1 >> /path/to/symphony/tmp/redmine-cron.log 2>&1
```

For early testing, prefer running manually with `--issue-id` first.

## Symphony Redmine Workflow

For the long-running Symphony service, use `tracker.kind: redmine`:

```md
---
tracker:
  kind: redmine
  endpoint: "$REDMINE_URL"
  api_key: "$REDMINE_API_KEY"
  project_slug: "thingspanel"
  assignee: "me"
  active_states: ["新建", "进行中", "反馈"]
  terminal_states: ["已关闭", "已拒绝"]
workspace:
  root: /path/to/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
codex:
  command: codex app-server
---

You are working on Redmine issue `{{ issue.identifier }}`.

Redmine URL: {{ issue.url }}
Title: {{ issue.title }}

Body:
{{ issue.description }}

Workflow:
- Inspect the repository first.
- Implement the smallest safe change.
- Run relevant checks.
- Commit, push, and open a draft GitHub PR when credentials are available.
- Use the `redmine_update_issue` tool to comment back to Redmine with summary, checks, branch, PR URL, and blockers.
```

Symphony exposes `redmine_update_issue` to Codex app-server sessions. Tool input:

```json
{
  "issue_id": "2100",
  "notes": "Implemented and opened PR ...",
  "status_name": "已解决"
}
```

## Current Safety Defaults

- The cron runner is dry-run unless `--execute` is passed.
- It only works on statuses listed in `--active-states`.
- It writes a per-issue lock under `--state-dir`.
- Redmine credentials are read from environment variables.
- Repo mapping is explicit; no project is guessed.
