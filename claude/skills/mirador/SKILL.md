---
name: mirador
description: Keep the user's Mirador app (task tracker) in sync while working on strapi/strapi. Use at the start of any fix, feature, chore, community-PR takeover or PR review, when the work moves to a step GitHub cannot see (done locally, addressing review comments, blocked), and when a PR needs a local worktree, environment or admin user to test it.
---

# Mirador

Mirador is a macOS app that tracks every task the user works on. **Most statuses are automatic**: the GitHub sync
(every minute) handles draft PR, waiting for review, changes requested, approved, merged, re-review / waiting on
author on reviews, CI and QA labels; Linear handles started / assigned tickets; new local branches become tasks.
Only report the steps nobody else can see.

Run `mirador` from inside the task's worktree: it finds the task from the current branch. If `mirador` is missing
or fails, carry on — never block the work on it.

## Report these (and only these)

| Moment | Command |
| --- | --- |
| Starting a fix / feature / chore | `mirador start --kind fix --title "<short title>" [--linear CMS-123]` |
| Starting a PR review (e.g. `/pr-review`) | `mirador start --kind review --pr <n>` → shows "Reviewing" |
| Taking over a community PR (pushing to their fork) | `mirador start --kind community --pr <n>` then `mirador status taken-over` |
| Implementation done, tests green, no PR yet | `mirador status done-locally` |
| Started addressing review comments on the user's PR | `mirador status addressing` |
| Stuck | `mirador status blocked` + `mirador note "<why>"` |

**Never set by hand** — the sync owns them and would overwrite you: `draft-pr`, `waiting-for-review`,
`changes-requested`, `approved`, `merged`, `re-review`, `waiting-on-author`.
No backfill needed: PRs the user authored, reviews and review requests are imported from GitHub automatically.

## Notes

One short line each, for what is worth finding again: the review verdict (`GO` / `GO WITH NITS` / `NO GO` + the
one reason), a CI root cause, a repro trick. Details stay in the review / PR, not in Mirador.
`mirador note "NO GO — breaks upload in i18n locales"`

## Testing a PR locally

Prefer these over manual worktree / port setup:

| Need | Command |
| --- | --- |
| Track a PR or ticket | `mirador add <GitHub PR or Linear URL>` |
| Create its worktree (`gh pr checkout` for PRs) | `mirador worktree <PR number or CMS key>` |
| Start it (installs + builds on first run) | `mirador env start <path>` |
| Create the super admin from Settings on a fresh app | `mirador admin <path>` |
| What runs where | `mirador env status` |

Ports come from Mirador's Settings: the monorepo and one worktree run side by side (before / after comparison).
Starting a worktree stops the other worktree only. Never start or stop environments the user did not ask for.

## Other commands

`mirador show`, `mirador list`, `mirador link --pr <n>`, `mirador sync`, `mirador cleanup` (read-only report;
deleting branches or worktrees is done by the user in the app, never by an agent). `mirador help` lists everything.

