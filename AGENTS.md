# AGENTS.md

Guidance for AI agents (and humans) changing Mirador's code. For *using* Mirador from an agent while working on
Strapi, see [docs/AGENTS_INTEGRATION.md](docs/AGENTS_INTEGRATION.md) or run `mirador guide`.

## Start here

1. [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md): why it exists, product principles, feature map, runtime paths, current
   state, how to verify UI.
2. This file: rules and gotchas.
3. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (sync, environments, cleanup, focus) and
   [docs/STATUSES.md](docs/STATUSES.md) (status rules, archive, focus ranking) before touching those areas.

Keep these files true: when a change alters behaviour they describe, update them in the same change (README feature
list included). Add a gotcha below when you lose time to something non-obvious.

## What this is

A native macOS desktop app (SwiftUI window + menu bar panel) and a CLI that track a developer's work on `strapi/strapi`.
Swift Package Manager only — no Xcode project. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first.

| Path | What |
| --- | --- |
| `Sources/MiradorCore` | All logic: models, store, GitHub / Linear sync, pings, worktrees, environment runner, cleanup, focus, archive. No UI. |
| `Sources/MiradorApp` | SwiftUI app. Views + `AppModel` (main-actor state, timers, calls into Core). |
| `Sources/mirador` | The CLI (`main.swift`), a thin layer over Core. |
| `Tests/MiradorCoreTests` | Swift Testing (`@Test`) suite for Core. |
| `scripts/` | `build-app.sh` (bundle), `install.sh` (local install), `make-dmg.sh`, `make-icon.swift`. |
| `claude/skills/mirador/SKILL.md` | **Generated** at build from `AgentGuide.swift` — edit the Swift file, not this one. |
| `Resources/sparkle-public-key` | Sparkle update-signing public key (the private one is a CI secret). Never commit a private key. |

## Commands

```sh
swift build                 # debug build
swift test                  # must stay green; add a test for every rule you add in Core
./scripts/install.sh        # build + install ~/Applications/Mirador.app (quits the running app)
.build/debug/mirador help   # try CLI changes without installing
```

## Rules

- **Logic goes in Core, with a test.** Views only render `AppModel` state and call its methods. Status derivation,
  ping detection, parsing and cleanup rules are pure functions over decoded GitHub / Linear data — test them with
  JSON fixtures like the existing tests do.
- **The store is shared by the app and the CLI** (`Store.update` = locked read-modify-write of one JSON file).
  - New `StoreData` / `AppSettings` / `TrackedTask` fields must be optional or decoded with `decodeIfPresent` and a
    default: older stores must keep loading.
  - An older build re-encoding the store drops keys it does not know. Install the new app before testing a new field
    with the new CLI.
- **Never block the main actor** on the network, git, `gh` or the Keychain. Use `Task.detached` and hop back with
  `MainActor.run`. Reading a Keychain item can show a system prompt (every rebuild changes the ad-hoc signature).
- **Run git through `/usr/bin/git`** when parsing output (`Cleanup` does). Shell wrappers some developers use can
  rewrite `git` output. Never delete refs from a computed list: delete only explicitly named items and re-check each
  one right before (see `Cleanup.deleteBranches`).
- **Outward actions only on an explicit click.** Mirador reads GitHub; the one write is the QA label, when the user
  changes a QA mark. No commits, pushes, comments or review submissions — keep it that way.
- **Status ownership.** The GitHub sync overrides a task's status only when the status *it derives* changes
  (`lastGitHubStatus`). Manual / agent statuses therefore survive until something new happens on the PR. Read
  [docs/STATUSES.md](docs/STATUSES.md) before touching `GitHubSync.status(...)`.
- **Processes.** Environments run in their own process group (`posix_spawn` + `POSIX_SPAWN_SETPGROUP`) so the whole
  yarn / nx / node tree can be stopped. `nx watch` leaves a detached daemon: stopping also runs `yarn nx daemon --stop`.
- **UI style** follows shadcn/ui (zinc palette, cards with 1px borders, outline / ghost buttons) through the tokens and
  components in `Theme.swift`. Reuse `Card`, `Badge`, `ShadButtonStyle`, `StatusBadge` instead of system styles.
- **Strapi specifics live in one place each:** repo name (`GitHubSync.repo`), expected-red CI checks
  (`CIStatus.expectedRed`), bot logins (`GitHubSync.bots`), PR template headings (`TestSteps.headings`), build markers
  (`EnvironmentRunner`).
- Comments: only where the code cannot say it (a non-obvious constraint or a GitHub / Strapi quirk).
- **Verify before claiming.** Run `swift test`; for UI, install and screenshot (see PROJECT_CONTEXT.md). Say which
  clicks you could not try. Never commit, push or open PRs unless the maintainer asks.
- **User-facing copy** is short and plain: sentence case, no jargon, no counts that add pressure.

## Gotchas already paid for

- GitHub notification `reason` is sticky (a thread stays "mention" forever) and threads also update on pushes; only
  unread ones are listed. Mention pings therefore require an actual new comment containing `@login`.
- Strapi squash-merges: git cannot tell a branch was merged. Cleanup asks GitHub for the PR by `headRefName`.
- Worktrees made by `gh pr checkout` are often detached or on a local `pr-<number>` branch: Cleanup finds their PR from
  the HEAD commit, then from the folder name. Folders get reused for other PRs, so the commit wins.
- CI rollups for 50 PRs in one GraphQL search time out (HTTP 504): CI is fetched separately, 10 PRs per query.
- PR bodies use CRLF line endings; normalize before parsing sections.
- `node_modules` existing does not mean installed: `node_modules/.yarn-state.yml` is written at the end of an install.
- Vite HMR in `strapi develop --watch-admin` shares the Strapi server port, so two instances on two ports do not clash.
- A `MenuBarExtra` window keeps its first height; `WindowFitter` resizes it to the content.
- Sparkle is an SPM binary target: `build-app.sh` copies `Sparkle.framework` into `Contents/Frameworks` (the
  executable has an `@executable_path/../Frameworks` rpath) and, when signing, signs its XPC services and helpers
  inside-out before the app. The updater only starts when `Info.plist` has `SUFeedURL`.
- Strapi with `HOST=localhost` can listen on `[::1]` only: the port check tries IPv4 and IPv6 loopback.
- Tasks never resolve to the monorepo checkout (`Worktrees.resolve`): it is shared and switches branches, so a stale
  `worktreePath` pointing at it showed another task's environment. Creating a worktree for a branch the monorepo holds
  uses `gh pr checkout --detach` (PRs) or explains how to free the branch.
- The GitHub searches drop a PR once it is closed or the review request is gone, so its task never learned it merged.
  `fetch(tracking:)` looks up open tasks' PRs the searches missed by number and applies only their end state.
- macOS paths can differ by symlink (`/var` vs `/private/var`): compare resolved paths (`Worktrees.samePath`).
- `gh api graphql` exits non-zero when one alias of a batch fails (a number that is not a PR / issue) but still prints
  the others: decode stdout anyway (`GitHubSync.batch`), never gate on the exit status.
- Every commit on develop is "associated" with the merged PR that brought it. A detached worktree belongs to a PR only
  when HEAD is that PR's `headRefOid` (`Cleanup.pullRequest(at:among:)`).
