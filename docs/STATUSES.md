# Statuses

Each task has a **kind** and a **status**. The kind picks the flow; the status is set by GitHub, Linear, the user or
an agent.

| Kind | Flow |
| --- | --- |
| Feature / Fix / Chore (my work) | To do → In progress → Done locally → Draft PR → Waiting for review → Changes requested → Addressing review → Approved → Merged → Released |
| Review (someone else's PR) | To review → Reviewing → Waiting on author → Re-review → Approved → Merged |
| Community PR | To review → Reviewing → Waiting on author → Taken over → Re-review → Approved → Merged → Released |

Any task can also be **Blocked** or **Closed**.

## Who sets what

| Source | Statuses |
| --- | --- |
| GitHub sync | Draft PR, Waiting for review, Changes requested, Approved, Merged, Closed, To review, Waiting on author, Re-review |
| Linear sync | To do → In progress when an assigned ticket is started |
| New local branch | In progress |
| User / agent (`mirador status`) | In progress, Reviewing, Done locally, Addressing review, Taken over, Blocked, Released |

**Override rule.** The sync only changes a task's status when the status it *derives* from GitHub changes (stored as
`lastGitHubStatus`). A status set by hand or by an agent therefore stays until something new happens on the PR.

## My PRs (`GitHubSync.status(authored:)`)

1. Merged → **Merged**; closed → **Closed**; draft → **Draft PR**; review decision approved → **Approved**.
2. *Feedback* = the latest review (changes requested / commented) or plain PR comment from someone else. Bots
   (`github-actions`, `trunk-io`, `greptile-apps`, … any `[bot]`) are ignored.
3. If there is feedback: my latest comment or push after it → **Waiting for review**, otherwise **Changes requested**.
4. No feedback yet → **Waiting for review** (or **Changes requested** if GitHub's review decision says so).

## PRs I review (`GitHubSync.status(reviewing:)`)

1. Merged / closed as above.
2. I have not reviewed or commented → **To review** if my review is requested, else unchanged.
3. My latest word is an approval → **Approved** (or **Re-review** if I am asked again).
4. New commits after my latest review or comment → **Re-review**.
5. Otherwise I spoke last → **Waiting on author** (a pending re-request alone does not flip it: GitHub keeps the
   request when I answer with a plain comment).

## QA

Separate from the status: **QA pending** (default for any task with a PR), **QA done** (`qa-done`, legacy
`QA passed`), **QA skipped** (`qa-skipped`). Labels are the source of truth; changing the mark in Mirador sets the
label, and the sync waits 2 minutes before reading labels again so it does not undo the change.

## CI

From the last commit's check rollup. A check that ran several times counts once (passed if any run passed).
`check-pr-status` (Strapi's QA gate) and `… (observation)` jobs are shown but never make a PR "failing".
