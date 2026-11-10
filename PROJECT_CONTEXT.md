# Project context

The *why* and the *state* of Mirador: read this before changing anything, then [AGENTS.md](AGENTS.md) for the rules
and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the code fits together. The code and git history say *what*;
this file holds what they cannot.

## What Mirador is for

A personal command center for a developer on the [Strapi monorepo](https://github.com/strapi/strapi). It answers
three questions in one place:

1. **What am I working on?** My PRs, the PRs I review, community PRs I took over, Linear tickets, local branches.
2. **What is waiting on me, and what next?** Statuses that follow GitHub / Linear, pings, focus mode.
3. **How do I run it locally?** One worktree per task, Quickstart of the Strapi dev servers, cleanup afterwards.

It started as a tool for one person (Adrien Lepoutre, Strapi dev, GitHub `Adzouz`) and is published as a community
tool at [Adzouz/Mirador](https://github.com/Adzouz/Mirador) (MIT, not an official Strapi product). Features are
driven by daily use: most come from "this annoyed me today".

## Product principles

These come from the maintainer's feedback; keep them when adding features.

- **Less noise, not more features.** The board got overwhelming, which is why *Up next* and *focus mode* exist.
  Anything new should reduce what the user has to look at. Prefer automatic behaviour (auto-archive, statuses moving
  on their own) over new buttons.
- **The sync owns what GitHub / Linear know; the user and agents own the rest.** Never make the user (or an agent)
  set a status GitHub can derive. See [docs/STATUSES.md](docs/STATUSES.md).
- **Read-only towards the outside.** The only outward write is the QA label. No comments, reviews, pushes or commits,
  ever, unless the user clicks for exactly that.
- **Nothing destructive on a computed list.** Cleanup deletes only what the user ticked, re-checking each item.
- **Native and quiet.** SwiftUI with a shadcn/ui look (zinc palette, 1px-border cards, outline / ghost buttons). Native
  was chosen over Tauri / React. Plain copy: short sentences, no jargon, no counts where they add pressure (focus mode
  shows none).
- **Fast first paint, then sync.** Show local data immediately (e.g. Cleanup lists worktrees from disk, then shows
  "Syncing with remote…").

## Feature map

| Feature | Where | Notes |
| --- | --- | --- |
| Task list, sidebar sections (Needs me, All active, My work, Reviews, History) | `MainView.swift` | `SidebarItem.includes` decides membership. |
| Task details (progress, CI, how to test, local environment, notes, activity) | `TaskDetailView.swift` | |
| **Up next** tab: ranked queue, snooze until tomorrow / next week | `Focus.swift`, `FocusView.swift` | Ranking in `Focus.queue`; see STATUSES.md. |
| **Focus mode** (⇧⌘F): one task, no counts / pings / notifications, *Skip for now* stack | `Focus.pick`, `FocusModeView.swift`, `AppModel` focus state | Current task is sticky; next one takes over when it leaves the user's side. |
| GitHub sync (statuses, CI, QA labels, test steps) | `GitHubSync.swift` | 3 searches + by-number lookup of tracked PRs. |
| Linear sync (tickets, priority, mentions) | `Linear.swift` | Optional personal API key in the Keychain. |
| Pings (review requests, mentions, re-reviews, red CI, Linear) | `Pings.swift`, PingsView in `MainView.swift` | Search by `#PR`, `@user`, words; mark read; bulk delete. |
| Links (PR, GitHub issue, Linear ticket per task; merge on conflict; unlink sticks) | `Links.swift`, `AddTaskSheet.swift` (link mode), `TaskDetailView.swift` header | One of each type per task. |
| **Auto-archive + History** | `Archive.swift` | Merged / closed PRs, PR-less tickets done in Linear, PR-less ticket-less closed issues. Unarchive sticks until the status changes. |
| Worktrees per task, Quickstart (monorepo + one worktree side by side) | `Worktrees.swift`, `WorktreeCreator.swift`, `EnvironmentRunner.swift`, `EnvironmentsView.swift` | A task never resolves to the monorepo checkout. |
| Cleanup of merged / closed branches and worktrees | `Cleanup.swift`, `CleanupView.swift` | Local scan first, then GitHub. |
| Menu bar panel | `MenuBarView.swift` | Shows only the focus card in focus mode. |
| CLI + Claude Code skill | `Sources/mirador/main.swift`, `AgentGuide.swift` | See [docs/CLI.md](docs/CLI.md), [docs/AGENTS_INTEGRATION.md](docs/AGENTS_INTEGRATION.md). |
| Auto super admin on fresh apps | `AdminBootstrap.swift` | Password in the Keychain. |
| Releases + Sparkle updates | `scripts/`, `.github/workflows/release.yml`, `Updates.swift` | See [docs/RELEASING.md](docs/RELEASING.md). |

## The maintainer's setup (useful defaults, not assumptions)

- Monorepo `~/Sites/Strapi/strapi`, worktrees `~/Sites/Strapi/wt` (and `strapi-worktrees`), Quickstart app
  `examples/getstarted`. Other users have other paths: always read `AppSettings`, never hard-code.
- Linear workspace `strapi`, team key `CMS` (branches like `fix/cms-1825-…`).
- Runs a **local dev build** (`./scripts/install.sh`, no auto-update) and ships with a `vX.Y.Z` tag. Released: v0.1.0.
- Shell wrappers (`rtk`) rewrite `git` output on this machine: parse git through `/usr/bin/git`.

## Runtime facts

| What | Where |
| --- | --- |
| Tasks, pings, settings, running environments | `~/Library/Application Support/Mirador/store.json` |
| UI state (sidebar section, focus mode, skipped stack, sort / filters) | UserDefaults domain `dev.mirador.app` |
| Secrets (Linear key, admin password) | Keychain service `dev.mirador.app` |
| Sync log, environment logs | `~/Library/Logs/Mirador/` |
| Installed app / CLI | `~/Applications/Mirador.app`, `~/.local/bin/mirador` |

Handy while developing: `defaults read dev.mirador.app`, `mirador list --all`, `mirador sync`, and
`python3 -c 'import json; …'` over `store.json` to inspect real data before guessing.

## Verifying UI changes

There is no UI test target and no accessibility permission for scripted clicks. What works:

1. `./scripts/install.sh`, then `open ~/Applications/Mirador.app` (install can leave it closed).
2. List Mirador windows with `CGWindowListCopyWindowInfo` (a tiny Swift script), capture one with
   `screencapture -l <windowID>`, shrink with `sips -Z 1400`, and look at it.
3. Put behaviour in Core and test it there; say plainly which clicks were not tried in the app.

The menu bar panel cannot be opened from a script.

## Current state

- The work since v0.1.0 (focus mode, Up next, auto-archive / History, task links, monorepo-free task environments,
  Cleanup local-first scan, ping search / mark read) is on branch `feat/v0.2-work`, PR #1, not merged yet.
- Unverified end to end: an actual Sparkle in-app update (needs a second release).
- `docs/images/` screenshots predate focus mode, Up next and History.

## Ideas not built yet

Only build these when asked.

- Cut v0.2.0 once PR #1 is merged.
- Refresh README screenshots.
