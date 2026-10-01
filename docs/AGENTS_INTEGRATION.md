# Using Mirador from AI agents

Mirador knows what GitHub and Linear know. An agent working with you knows the rest: when you *start* a task, when
the fix is *done locally*, when you start *addressing* review comments. The `mirador` CLI lets the agent report
those steps, and also create worktrees and start environments to test PRs.

## Claude Code

**Settings → Command line & Claude Code** (or the setup checklist) installs:

1. the CLI as `~/.local/bin/mirador`;
2. the skill as `~/.claude/skills/mirador/SKILL.md`.

New Claude Code sessions then load the skill and call `mirador` on their own. The skill is generated from
[`AgentGuide.swift`](../Sources/MiradorCore/AgentGuide.swift); the committed copy is
[`claude/skills/mirador/SKILL.md`](../claude/skills/mirador/SKILL.md).

## Any other agent, or a session already running

Paste the prompt from **Settings → Copy prompt** (or the setup checklist):

> I track my work in Mirador, a macOS app with a `mirador` CLI. Run `mirador guide` now and follow those rules for
> the rest of this session (and save them to your memory if you have one).

`mirador guide` prints the full rules. The short version:

- **Report only what GitHub cannot see**: `mirador start …`, `mirador status done-locally`,
  `mirador status addressing`, `mirador status taken-over`, `mirador status blocked`.
- **Never set** `draft-pr`, `waiting-for-review`, `changes-requested`, `approved`, `merged`, `re-review` or
  `waiting-on-author`: the sync owns them and would overwrite the agent.
- **Notes are one line**: a review verdict, a CI root cause, a repro trick.
- **Testing a PR**: `mirador worktree <PR>` then `mirador env start <path>`; ports come from Settings. Do not start or
  stop environments the user did not ask for.
- **Never delete** branches or worktrees: `mirador cleanup` is a read-only report; deleting is done by the user in the
  app.
- No backfill: authored PRs, reviews and review requests are imported from GitHub automatically.
