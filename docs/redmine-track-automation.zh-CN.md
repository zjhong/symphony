# Redmine + Track 自动开发接入说明

这个分支提供了一个可落地的自动化闭环：

```text
Redmine 任务 -> 工作目录 -> Codex 执行开发 -> GitHub 分支/PR -> 回写 Redmine
```

包含两层能力：

- Symphony 原生 `tracker.kind: redmine`：适合常驻服务模式。
- `scripts/redmine_codex_cron.py`：适合快速验证和 `cron` 调度的轻量模式。

## 环境变量

不要把密钥写进 `WORKFLOW.md` 或 crontab，统一放环境变量。

```bash
export REDMINE_URL="https://redmine.example.com"
export REDMINE_API_KEY="your_redmine_api_key"
```

可选：项目到仓库映射（轻量脚本会用到）

```bash
export REDMINE_REPO_MAP='{
  "my-project": "/path/to/my-repo",
  "My Project": "/path/to/my-repo",
  "1": "/path/to/my-repo"
}'
```

映射键支持 Redmine 的 `project identifier`、`project name`、`project id`。

## 快速只读验证（Dry Run）

下面命令只读取任务并打印候选项，不会改状态，也不会启动 Codex：

```bash
cd /path/to/symphony
REDMINE_URL="https://redmine.example.com" \
REDMINE_API_KEY="$REDMINE_API_KEY" \
scripts/redmine_codex_cron.py --limit 1 --repo /path/to/target/repo
```

指定任务验证：

```bash
scripts/redmine_codex_cron.py --issue-id 2100 --repo /path/to/target/repo
```

## 执行真实任务

会执行以下动作：领取任务 -> 建独立工作目录 -> 启动 Codex -> 回写 Redmine。

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

如果你本地 Codex 命令参数不同，可以覆盖：

```bash
export CODEX_COMMAND='codex exec --ask-for-approval never --sandbox workspace-write --skip-git-repo-check < {prompt_file}'
```

模板变量支持：

- `{prompt_file}`
- `{issue_id}`
- `{workspace}`

## Cron 示例

```cron
*/10 * * * * REDMINE_URL=https://redmine.example.com REDMINE_API_KEY=your_redmine_api_key REDMINE_REPO_MAP='{"my-project":"/path/to/my-repo"}' /path/to/symphony/scripts/redmine_codex_cron.py --execute --limit 1 >> /path/to/symphony/tmp/redmine-cron.log 2>&1
```

建议先用 `--issue-id` 手动跑通，再挂定时任务。

## Symphony 常驻模式配置

`WORKFLOW.md` 里使用 Redmine 追踪器：

```md
---
tracker:
  kind: redmine
  endpoint: "$REDMINE_URL"
  api_key: "$REDMINE_API_KEY"
  project_slug: "my-project"
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
```

## Agent 可用 Redmine 工具

`app-server` 会暴露 `redmine_update_issue`，用于回写评论或状态：

```json
{
  "issue_id": "2100",
  "notes": "Implemented and opened PR ...",
  "status_name": "已解决"
}
```

## 安全默认值

- `redmine_codex_cron.py` 默认是 dry-run，必须加 `--execute` 才会落操作。
- 只处理 `active_states` 指定状态的任务。
- 用每任务锁文件避免重复执行。
- 凭据只从环境变量读取，不写入仓库。
