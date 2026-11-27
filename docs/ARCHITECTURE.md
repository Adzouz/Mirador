# Architecture

```
            ┌──────────────── Mirador.app ────────────────┐        ┌── mirador CLI ──┐
            │ SwiftUI views  ←  AppModel (@MainActor)     │        │   main.swift    │
            │                     │ timers: 1s / 2s / 60s │        │                 │
            └─────────────────────┼───────────────────────┘        └────────┬────────┘
                                  ▼                                         ▼
            ┌──────────────────────────── MiradorCore ───────────────────────────────┐
            │ Store (store.json, flock)   GitHubSync   LinearAPI   Pings   LocalWork │
            │ Worktrees / WorktreeCreator   EnvironmentRunner   Cleanup   AdminBootstrap │
            │ Focus (queue, pick, snooze)   Archive                                  │
            └───────┬──────────────┬──────────────┬──────────────┬───────────────────┘
                    ▼              ▼              ▼              ▼
              gh (GraphQL)   Linear GraphQL    /usr/bin/git   yarn / Strapi (localhost)
```

## Data

`Store` keeps one JSON document (`StoreData`) in `~/Library/Application Support/Mirador/store.json`:
tasks, running environments, pings, settings and small sync bookkeeping (seen notification threads, requested PRs,
seen branches). Every change is a locked read-modify-write, so the app and the CLI can write concurrently. The app
watches the file's modification date (1 s timer) and reloads.

Secrets (Linear key, admin password) are in the Keychain under the service `dev.mirador.app`.

## Sync (every 60 s, `AppModel.sync`)

1. `Worktrees.list` — `git worktree list --porcelain` of the monorepo + checkouts found in the worktrees folder.
2. `GitHubSync.fetch(tracking:issues:)` — three GraphQL searches (authored, review-requested, reviewed-by me, last 30
   days), then the open tasks' PRs none of them returned, by number (20 per query; only merged / closed is applied from
   those), the open tasks' linked issues (title and state), then CI rollups for open PRs in batches of 10. `GitHubSync.apply` upserts tasks and derives statuses
   ([STATUSES.md](STATUSES.md)).
3. `Pings` — review requests (PR entering the requested set), re-review (a reviewed PR going back to "my turn"),
   real mentions (from GitHub notifications + the latest comment), CI failures on my PRs.
4. `LinearAPI` (if a key is set) — assigned tickets, notifications, and every tracked ticket's state / priority.
5. `LocalWork` — a branch newly checked out in a worktree becomes an "In progress" task.
6. `Archive.apply` — archives finished tasks (after the GitHub pass and after the Linear pass).

Links (`Links.swift`): a task holds at most one PR, one Linear ticket and one GitHub issue. `StoreData.link` merges a
task that already held the link into the target (`TrackedTask.absorb`), so nothing is tracked twice. Removing a link
records it in `TrackedTask.unlinked`; the GitHub and Linear passes skip those when they match tasks by branch or PR, or
fill a Linear key from a branch name.

Linear runs as its own detached task (`AppModel.syncLinear`), so a slow or broken Linear never holds GitHub back.

Each source fails independently; errors go to the toolbar and `~/Library/Logs/Mirador/sync.log`.

## Environments

`EnvironmentRunner` starts two processes per checkout, each in its own process group, logging to
`~/Library/Logs/Mirador/<folder>-{watch,develop}.log`:

- install / build if needed → `cd <app> && PORT=<port> yarn develop --watch-admin`
- `yarn watch`, once install and build are done (it rebuilds on changes, never on start)

"If needed" (`EnvironmentRunner.preparation`): missing install / build markers (fresh checkout: `yarn install`, full
`yarn build`), or what changed since the commit of the last build Mirador ran, recorded per checkout in
`~/Library/Application Support/Mirador/environments/<folder>-<hash>.built`. A changed `package.json` or lockfile →
`yarn install`; changed files under `packages/` → `nx run-many --targets build:code,build:types --projects <their
folders>` (what `yarn watch` runs on a change); shared build setup (root `package.json`, `yarn.lock`, `nx.json`,
`rollup.utils.mjs`) → full `yarn build`. No record yet → the build is assumed to match HEAD (the old behaviour). The
start script writes its phase to `<folder>-<hash>.phase`: the app shows it while starting, `yarn watch` waits for
`starting`. A phase still `installing` / `building` at the next start means that start stopped before Strapi (stopped,
failed, or killed by a restart): the markers come from the first files written, so it builds in full and installs if it
was installing (or if dependencies changed since the last build), and nothing records a build for it meanwhile.

**Removed checkouts.** A checkout is gone once its `.git` is (`Worktrees.isGone`: "no such file", never a lookup the
system refused or a volume that is not mounted, symlinks to it included), never because `git worktree list` omits it (a
failing git call omits everything). `Worktrees.list` leaves out listed worktrees that are gone (git keeps listing a
locked one), except for Cleanup and worktree creation (`includingRemoved`): it still holds its branch. Every 2 s,
with the environment poll, the app checks the worktrees it lists, the running environments and the tasks' worktree links
(file checks only), and the modification dates of the worktrees folder and `.git/worktrees` (any change refreshes the
list). A removal drops the worktree from every list at once; `EnvironmentRunner.forgetRemovedCheckouts` forgets its
environment, unlinks its tasks (the sync matches them again) and deletes its phase / build records. Leftover processes
are stopped only when their group is still led by the process Mirador started (`isOurs`, by start time): recorded ids
get reused. The sync, every start and `mirador env status` do the same for removals made while the app was closed.

A task's environment is `Worktrees.resolve`: its linked worktree, else the best match by branch / `pr-<n>` folder /
Linear key, **never the monorepo checkout** (shared, switches branches). Two slots: the monorepo and one worktree, each on its port from Settings. Starting a checkout stops only what runs in
its slot. State = process groups alive + port answering; startup phase is read from the phase file (install / build
markers for environments started by an older version).

**Update branch** (worktrees; `BranchUpdate`): fetches what the checkout follows (its upstream, else
`refs/pull/<n>/head` for a detached PR checkout, else the same branch name on strapi/strapi) and fast-forwards. A
force-pushed branch (commits reworded or only dropped) is followed (`reset --keep`) only when HEAD was that remote
branch at some point (`merge-base --fork-point` over the remote-tracking ref's reflog) and none of the commits it drops
were written or committed by the local git user (a pushed commit of theirs is in that reflog too); otherwise the app
asks, saying how many commits would be dropped and whose. Commits on top of the new version count as not pushed yet ("up
to date") only when none of them was ever on the remote branch; with no remote-tracking ref (a detached PR or a fork
checkout) nothing shows that, so the app asks. Confirming covers only the commits the dialog counted: if the checkout or
the remote moved meanwhile, the app asks again. Uncommitted changes are never overwritten, a checkout whose HEAD moved
during the fetch is left alone, and nothing moves during a rebase, merge, cherry-pick, revert or bisect. The app then
restarts the environment if it runs, and the start rebuilds what the pull changed. With no record yet, the commit from
before the update is recorded as the built one, so that start still sees the change.
When an environment reaches Running and the super admin option is on, `AdminBootstrap` calls
`GET /admin/init` and, if there is no admin, `POST /admin/register-admin`.

## Cleanup

`Cleanup.scan` is split so the view paints fast: `scanLocal` (worktrees and branches from disk, `git status` in
parallel) is shown first, then `git fetch --prune` and GitHub lookups by branch, by HEAD commit (detached worktrees)
and by `pr-<n>` folder number fill in PR states (`Report.remoteChecked`). The last report is cached on `AppModel`.

## Focus

`Focus.queue` ranks open tasks waiting on the user (urgent first, then step, then priority, then oldest). The **Up
next** tab renders it with snooze (`snoozedUntil`, cleared by any status change). **Focus mode** replaces the whole
window with one task: `Focus.pick` keeps the current task while it is still in the queue and not skipped, else takes
the first non-skipped one. Focus state (`focusMode`, `focusTask`, `focusSkipped`) is UI state in UserDefaults, not in
the store. Notifications are muted in focus mode; pings are still recorded.

## UI

`AppModel` is the single source of UI state. Main window: sidebar (Up next, task sections, History, inbox, cleanup)
→ task list (`ListToolbar` sort / filters) → `TaskDetailView` (cards); in focus mode, `FocusModeView` instead.
`MenuBarView` is the menu bar panel. Design tokens and shadcn-like components are in `Theme.swift` and
`Components.swift`.

## Agents

`AgentGuide.swift` is the single source of the agent rules: `mirador guide`, the bundled Claude Code skill
(generated by `build-app.sh` into the app and `claude/skills/mirador/SKILL.md`) and the onboarding prompt.
