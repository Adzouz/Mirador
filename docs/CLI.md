# `mirador` CLI

Installed from **Settings → Command line & Claude Code** (or `./scripts/install.sh`) as `~/.local/bin/mirador`.
It reads and writes the same store as the app, so changes show up in the app within a second.

A `[ref]` is a PR number (`12345` or `#12345`), a Linear key (`CMS-123`), a branch name or a worktree path.
Without one, the task is found from the current directory (its worktree, then its branch).

## Tasks

| Command | What it does |
| --- | --- |
| `mirador start [--kind K] [--title T] [--linear KEY] [--pr N] [--branch B]` | Create or resume the task for the current worktree and mark it In progress (Reviewing for reviews). Kinds: `fix`, `feature`, `chore`, `review`, `community`. |
| `mirador add <link>` | Track a GitHub PR or Linear ticket (URL, `#123` or `CMS-123`). |
| `mirador status <status> [ref]` | Set a status. Meant for the steps GitHub cannot see: `in-progress`, `reviewing`, `done-locally`, `addressing`, `taken-over`, `blocked`, `released`. |
| `mirador note <text> [--ref R]` | Append a one-line note. |
| `mirador link [ref] [--pr N] [--linear KEY] [--title T] [--kind K]` | Attach a PR / ticket or change the kind or title. |
| `mirador show [ref]` | Task details with GitHub, Linear and worktree links. |
| `mirador list [--all]` | Active tasks (`--all` includes finished and archived). |
| `mirador sync` | Pull GitHub and local branches now (the app does it every minute). |

## Local environments

| Command | What it does |
| --- | --- |
| `mirador worktree <ref> [--dir D]` | Create a worktree in the worktrees folder: `gh pr checkout` for a PR (forks included), a new branch from `origin/develop` for a ticket. |
| `mirador env start [path]` | Run `yarn watch` + `yarn develop --watch-admin` (installs and builds first if needed). The monorepo and one worktree can run side by side. |
| `mirador env stop [path] [--all]` | Stop one environment, or all. |
| `mirador env status` | What runs, where, on which port. |
| `mirador admin [path] [--port N] [--email E]` | Create the super admin configured in Settings on a running app that has none. `MIRADOR_ADMIN_PASSWORD` overrides the Keychain password. |

## Other

| Command | What it does |
| --- | --- |
| `mirador cleanup [--verbose]` | Read-only report of stale local branches and worktrees. Deleting happens in the app. |
| `mirador guide [--skill]` | The rules for AI agents, or the full Claude Code skill file. |
| `mirador help` | Usage. |
