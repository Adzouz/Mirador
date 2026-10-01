import Foundation
import Testing
@testable import MiradorCore

private func pr(
    state: String = "OPEN", draft: Bool = false, merged: Bool = false, decision: String? = nil,
    lastCommit: String = "2026-09-10T10:00:00Z", reviews: [(String, String, String)] = []
) throws -> PullRequest {
    let reviewJSON = reviews.map { #"{"author":{"login":"\#($0.0)"},"state":"\#($0.1)","submittedAt":"\#($0.2)"}"# }.joined(separator: ",")
    let json = """
    {"number":1,"title":"fix: thing","url":"https://github.com/strapi/strapi/pull/1","state":"\(state)","isDraft":\(draft),
     "merged":\(merged),"headRefName":"fix/cms-42-thing","isCrossRepository":false,"author":{"login":"someone"},
     "reviewDecision":\(decision.map { "\"\($0)\"" } ?? "null"),
     "commits":{"nodes":[{"commit":{"committedDate":"\(lastCommit)"}}]},"reviews":{"nodes":[\(reviewJSON)]}}
    """
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return try d.decode(PullRequest.self, from: Data(json.utf8))
}

@Test func linearKeyFromBranch() {
    #expect(LinearKey.find(in: "fix/cms-123-content-manager-upload") == "CMS-123")
    #expect(LinearKey.find(in: "feat/rotate-image") == nil)
}

@Test func authoredStatuses() throws {
    #expect(GitHubSync.status(authored: try pr(draft: true), me: "me") == .draftPR)
    #expect(GitHubSync.status(authored: try pr(), me: "me") == .waitingForReview)
    #expect(GitHubSync.status(authored: try pr(decision: "APPROVED"), me: "me") == .approved)
    #expect(GitHubSync.status(authored: try pr(merged: true), me: "me") == .merged)
    let requested = try pr(decision: "CHANGES_REQUESTED", reviews: [("rev", "CHANGES_REQUESTED", "2026-09-11T10:00:00Z")])
    #expect(GitHubSync.status(authored: requested, me: "me") == .changesRequested)
    let addressed = try pr(decision: "CHANGES_REQUESTED", lastCommit: "2026-09-12T10:00:00Z", reviews: [("rev", "CHANGES_REQUESTED", "2026-09-11T10:00:00Z")])
    #expect(GitHubSync.status(authored: addressed, me: "me") == .waitingForReview)
    let botOnly = try pr(reviews: [("greptile-apps", "COMMENTED", "2026-09-11T10:00:00Z")])
    #expect(GitHubSync.status(authored: botOnly, me: "me") == .waitingForReview)
}

@Test func reviewStatuses() throws {
    #expect(GitHubSync.status(reviewing: try pr(), me: "me", requested: true) == .toReview)
    #expect(GitHubSync.status(reviewing: try pr(), me: "me", requested: false) == nil)
    let commented = try pr(reviews: [("me", "COMMENTED", "2026-09-11T10:00:00Z")])
    #expect(GitHubSync.status(reviewing: commented, me: "me", requested: false) == .waitingOnAuthor)
    // Re-requested, but I commented after the last commit: still the author's turn.
    #expect(GitHubSync.status(reviewing: commented, me: "me", requested: true) == .waitingOnAuthor)
    let pushedAfter = try pr(lastCommit: "2026-09-12T10:00:00Z", reviews: [("me", "CHANGES_REQUESTED", "2026-09-11T10:00:00Z")])
    #expect(GitHubSync.status(reviewing: pushedAfter, me: "me", requested: false) == .reReview)
    let approved = try pr(reviews: [("me", "APPROVED", "2026-09-11T10:00:00Z")])
    #expect(GitHubSync.status(reviewing: approved, me: "me", requested: false) == .approved)
}

@Test func manualStatusSurvivesUntilGitHubChanges() throws {
    var data = StoreData()
    var task = TrackedTask(kind: .fix, title: "Thing", status: .inProgress, source: "claude")
    task.branch = "fix/cms-42-thing"
    data.tasks = [task]
    let reviewed = try pr(decision: "CHANGES_REQUESTED", reviews: [("rev", "CHANGES_REQUESTED", "2026-09-11T10:00:00Z")])
    let snap = GitHubSync.Snapshot(me: "me", authored: [reviewed], requested: [], reviewed: [])

    GitHubSync.apply(snap, to: &data, worktrees: [])
    #expect(data.tasks[0].prNumber == 1)
    #expect(data.tasks[0].linearKey == "CMS-42")
    #expect(data.tasks[0].status == .changesRequested)

    data.tasks[0].setStatus(.addressing, source: "claude")
    GitHubSync.apply(snap, to: &data, worktrees: [])
    #expect(data.tasks[0].status == .addressing)

    let pushed = try pr(decision: "CHANGES_REQUESTED", lastCommit: "2026-09-12T10:00:00Z", reviews: [("rev", "CHANGES_REQUESTED", "2026-09-11T10:00:00Z")])
    GitHubSync.apply(.init(me: "me", authored: [pushed], requested: [], reviewed: []), to: &data, worktrees: [])
    #expect(data.tasks[0].status == .waitingForReview)
}

@Test func worktreePorcelainParsing() {
    let out = """
    worktree /repo
    HEAD abc
    branch refs/heads/develop

    worktree /wt/pr-12345
    HEAD def
    branch refs/heads/feat/cms-375-rotate
    """
    let list = Worktrees.parse(out)
    #expect(list.count == 2)
    #expect(list[1].prNumberFromName == 12345)
    #expect(list[1].branch == "feat/cms-375-rotate")
}

@Test func storeRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = Store(directory: dir)
    store.update { $0.tasks.append(TrackedTask(kind: .review, title: "Review", source: "test")) }
    #expect(store.load().tasks.first?.status == .toReview)
    try? FileManager.default.removeItem(at: dir)
}

@Test func pingsOnlyForNewRequestsAndRealMentions() throws {
    var data = StoreData()
    let first = try pr()
    let empty = Pings.Inputs(notifications: [], comments: [:])
    // First run primes state without pinging.
    #expect(Pings.apply(snapshot: .init(me: "me", authored: [], requested: [first], reviewed: []), inputs: empty, to: &data).isEmpty)
    #expect(Pings.apply(snapshot: .init(me: "me", authored: [], requested: [first], reviewed: []), inputs: empty, to: &data).isEmpty)

    func note(_ id: String, _ reason: String, _ updated: String) -> Pings.Notification {
        .init(id: id, reason: reason, updated_at: updated, subject: .init(title: "T", url: "https://api.github.com/repos/strapi/strapi/pulls/9", latest_comment_url: nil))
    }
    func comment(_ body: String, by user: String = "rev", url: String = "https://c/1") -> Pings.Comment {
        .init(body: body, html_url: url, user: .init(login: user))
    }
    // Thread seen for the first time (e.g. came back unread after a push) with no new comment: no ping (the #12346 case).
    let pushOnly = Pings.Inputs(notifications: [note("n1", "mention", "a")], comments: [:])
    #expect(Pings.apply(snapshot: .init(me: "me", authored: [], requested: [], reviewed: []), inputs: pushOnly, to: &data).isEmpty)

    // Unrelated comment: no ping. Comment naming me: ping, with the author.
    let other = Pings.Inputs(notifications: [note("n1", "mention", "b")], comments: ["n1": comment("lgtm")])
    #expect(Pings.apply(snapshot: .init(me: "me", authored: [], requested: [], reviewed: []), inputs: other, to: &data).isEmpty)
    let named = Pings.Inputs(notifications: [note("n1", "mention", "c")], comments: ["n1": comment("cc @Me", url: "https://c/2")])
    let pings = Pings.apply(snapshot: .init(me: "me", authored: [], requested: [], reviewed: []), inputs: named, to: &data)
    #expect(pings.map(\.reason) == [.mention])
    #expect(pings.first?.headline.hasPrefix("@rev mentioned you") == true)
    // Same comment again after the thread comes back unread: no second ping.
    let again = Pings.Inputs(notifications: [note("n1", "mention", "d")], comments: ["n1": comment("cc @Me", url: "https://c/2")])
    #expect(Pings.apply(snapshot: .init(me: "me", authored: [], requested: [], reviewed: []), inputs: again, to: &data).isEmpty)

    // PR entering the requested set pings, naming who asked.
    let requested = Pings.apply(snapshot: .init(me: "me", authored: [], requested: [first], reviewed: []), inputs: empty, to: &data)
    #expect(requested.map(\.reason) == [.reviewRequested])
    #expect(requested.first?.headline.hasPrefix("@someone asked a review from you") == true)
}

@Test func pingWhenReviewComesBackToMe() throws {
    var data = StoreData()
    data.requestedPRs = []
    data.seenThreads = [:]
    // I commented, then the author pushed: waiting-on-author → re-review.
    let pushed = try pr(lastCommit: "2026-09-12T10:00:00Z", reviews: [("me", "COMMENTED", "2026-09-11T10:00:00Z")])
    var inputs = Pings.Inputs(notifications: [], comments: [:])
    inputs.previousStatus = [1: .waitingOnAuthor]
    let pings = Pings.apply(snapshot: .init(me: "me", authored: [], requested: [], reviewed: [pushed]), inputs: inputs, to: &data)
    #expect(pings.map(\.reason) == [.reReviewNeeded])
    // Already re-review last time: no repeat.
    inputs.previousStatus = [1: .reReview]
    #expect(Pings.apply(snapshot: .init(me: "me", authored: [], requested: [], reviewed: [pushed]), inputs: inputs, to: &data).isEmpty)
}

@Test func linkParsing() {
    #expect(LinkParser.parse("https://github.com/strapi/strapi/pull/12347/files") == .githubPR(12347))
    #expect(LinkParser.parse("  #12347 ") == .githubPR(12347))
    #expect(LinkParser.parse("https://linear.app/strapi/issue/CMS-123/rebuild-media-field") == .linear("CMS-123"))
    #expect(LinkParser.parse("cms-42") == .linear("CMS-42"))
    #expect(LinkParser.parse("hello world") == nil)
    #expect(LinkParser.parse("https://github.com/other/repo/pull/1") == nil)
}

@Test func worktreeMatchesByLinearKeyInFolderName() {
    var task = TrackedTask(kind: .feature, title: "x", source: "test")
    task.linearKey = "CMS-123"
    task.branch = "fix/cms-123-upload-progress"
    let wts = [Worktree(path: "/wt/cms-123", branch: "fix/cms-122-other", head: "", isMain: false)]
    #expect(Worktrees.match(task, in: wts)?.path == "/wt/cms-123")
}

@Test func newLocalBranchBecomesTask() {
    var data = StoreData()
    let old = Worktree(path: "/wt/old", branch: "fix/cms-1-old-thing", head: "", isMain: false)
    let review = Worktree(path: "/wt/pr-5", branch: "someone/branch", head: "", isMain: false)
    let dev = Worktree(path: "/repo", branch: "develop", head: "", isMain: true)
    // First run: stale branches are only remembered.
    LocalWork.apply(worktrees: [dev, old, review], activity: ["fix/cms-1-old-thing": .distantPast], to: &data)
    #expect(data.tasks.isEmpty)

    let fresh = Worktree(path: "/wt/new", branch: "feat/cms-99-rotate-image", head: "", isMain: false)
    #expect(LocalWork.apply(worktrees: [dev, old, fresh], activity: [:], to: &data) == 1)
    #expect(data.tasks[0].title == "Rotate image")
    #expect(data.tasks[0].kind == .feature)
    #expect(data.tasks[0].status == .inProgress)
    #expect(data.tasks[0].linearKey == "CMS-99")
    // Seen once, never duplicated.
    #expect(LocalWork.apply(worktrees: [fresh], activity: [:], to: &data) == 0)
}

@Test func linearStartedTicketBecomesTaskAndMentionsPing() throws {
    let json = """
    {"identifier":"CMS-7","title":"Fix crop","url":"https://linear.app/strapi/issue/CMS-7","branchName":"fix/cms-7-crop",
     "updatedAt":"2026-01-01T00:00:00Z","state":{"name":"In Progress","type":"started"},
     "labels":{"nodes":[{"name":"Bug"}]},"attachments":{"nodes":[{"url":"https://github.com/strapi/strapi/pull/321"}]}}
    """
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    let issue = try d.decode(LinearIssue.self, from: Data(json.utf8))
    let note = LinearNotification(id: "n1", type: "issueCommentMention", createdAt: .now, readAt: nil,
                                  issue: .init(identifier: "CMS-7", title: "Fix crop", url: "https://linear.app/x"), comment: nil)
    var data = StoreData()
    let first = LinearAPI.apply(.init(viewerName: "A", assigned: [issue], notifications: [note]), to: &data, worktrees: [])
    #expect(first.isEmpty) // priming
    #expect(data.tasks.count == 1)
    #expect(data.tasks[0].prNumber == 321)
    #expect(data.tasks[0].status == .inProgress)
    #expect(data.tasks[0].kind == .fix)

    var second = note
    second.id = "n2"
    let pings = LinearAPI.apply(.init(viewerName: "A", assigned: [issue], notifications: [second, note]), to: &data, worktrees: [])
    #expect(pings.map(\.reason) == [.linearMention])
    #expect(data.tasks.count == 1)
}

@Test func startDateKeepsEarliest() throws {
    var data = StoreData()
    var task = TrackedTask(kind: .fix, title: "Thing", status: .inProgress, source: "local")
    task.branch = "fix/cms-42-thing"
    task.noteStart(Date(timeIntervalSince1970: 1_000))
    data.tasks = [task]
    var opened = try pr()
    opened.createdAt = Date(timeIntervalSince1970: 5_000)
    GitHubSync.apply(.init(me: "me", authored: [opened], requested: [], reviewed: []), to: &data, worktrees: [])
    #expect(data.tasks[0].startDate == Date(timeIntervalSince1970: 1_000))

    var fromGitHub = StoreData()
    GitHubSync.apply(.init(me: "me", authored: [opened], requested: [], reviewed: []), to: &fromGitHub, worktrees: [])
    #expect(fromGitHub.tasks[0].startDate == Date(timeIntervalSince1970: 5_000))
}

@Test func priorityOverrideWinsOverLinear() {
    var t = TrackedTask(kind: .fix, title: "x", source: "test")
    #expect(t.priority == .none)
    t.linearPriority = 3
    #expect(t.priority == .medium)
    t.priorityOverride = 1
    #expect(t.priority == .urgent)
    #expect(Priority.urgent.rank < Priority.low.rank && Priority.low.rank < Priority.none.rank)
}

@Test func statusRankPutsActionFirst() {
    #expect(TaskStatus.changesRequested.rank < TaskStatus.inReview.rank)
    #expect(TaskStatus.toReview.rank < TaskStatus.approved.rank)
    #expect(TaskStatus.approved.rank < TaskStatus.merged.rank)
}

@Test func plainCommentAfterPushMeansWaitingOnAuthor() throws {
    // Case of #12346: review dismissed, author pushes, re-requests, I answer with a plain comment.
    var p = try pr(lastCommit: "2026-09-29T11:02:00Z", reviews: [("me", "DISMISSED", "2026-09-29T08:47:00Z")])
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    p.comments = try d.decode(PullRequest.Nodes<PullRequest.Comment>.self, from: Data(#"{"nodes":[{"author":{"login":"me"},"createdAt":"2026-09-29T14:52:00Z"}]}"#.utf8))
    #expect(GitHubSync.status(reviewing: p, me: "me", requested: true) == .waitingOnAuthor)
}

@Test func ciIgnoresExpectedRedGate() throws {
    let json = """
    {"number":2,"title":"t","url":"u","state":"OPEN","isDraft":false,"merged":false,"headRefName":"b","isCrossRepository":false,
     "commits":{"nodes":[{"commit":{"committedDate":"2026-09-10T10:00:00Z","statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[
       {"name":"check-pr-status","conclusion":"FAILURE","status":"COMPLETED"},
       {"name":"lint","conclusion":"SUCCESS","status":"COMPLETED"},
       {"name":"e2e","conclusion":null,"status":"IN_PROGRESS"}]}}}}]},
     "reviews":{"nodes":[]}}
    """
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    let ci = try d.decode(PullRequest.self, from: Data(json.utf8)).ci
    #expect(ci?.state == .pending)
    #expect(ci?.expected == ["check-pr-status"])
    #expect(ci?.failing.isEmpty == true)
}

@Test func settingsDefaultWhenMissingFromOldStore() throws {
    let d = JSONDecoder()
    let data = try d.decode(StoreData.self, from: Data(#"{"tasks":[]}"#.utf8))
    #expect(data.settings.appDirectory == "examples/getstarted")
    #expect(data.settings.repoPath == AppSettings.detectedRepo)
    #expect(data.settings.linearWorkspace == "strapi")
    let partial = try d.decode(AppSettings.self, from: Data(#"{"worktreesPath":"/tmp/wt"}"#.utf8))
    #expect(partial.worktreesPath == "/tmp/wt")
    #expect(partial.appDirectory == "examples/getstarted")
}

@Test func worktreesFolderCheckoutsAreListed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let clone = root.appendingPathComponent("my-clone")
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    Shell.run("git", ["init", "-q", "-b", "fix/cms-5-thing", clone.path])
    try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-repo"), withIntermediateDirectories: true)
    var settings = AppSettings()
    settings.repoPath = root.appendingPathComponent("missing").path
    settings.worktreesPath = root.path
    let list = Worktrees.list(settings: settings)
    #expect(list.map(\.name) == ["my-clone"])
    #expect(list.first?.branch == nil || list.first?.branch == "fix/cms-5-thing")
    try? FileManager.default.removeItem(at: root)
}

@Test func testStepsExtraction() {
    let body = """
    <!-- template comment -->
      ### What does it do?

      Stuff.

      ### How to test it?

      Manual (`examples/getstarted`):

      1. Upload a file
      2. `GET /api/upload/files/<documentId>` returns it.

      ### Related issue(s)/PR(s)

      Fix #1
    """
    let steps = TestSteps.extract(from: body)
    #expect(steps?.hasPrefix("Manual (`examples/getstarted`):") == true)
    #expect(steps?.contains("2. `GET") == true)
    #expect(steps?.contains("Related") == false)
    #expect(TestSteps.extract(from: "### How to test it?\n\nProvide information about the environment and the path to verify the behaviour.\n") == nil)
    #expect(TestSteps.extract(from: "no sections here") == nil)
}

@Test func worktreeNaming() {
    var pr = TrackedTask(kind: .review, title: "x", source: "t")
    pr.prNumber = 12346
    #expect(WorktreeCreator.folderName(for: pr) == "pr-12346")
    var ticket = TrackedTask(kind: .fix, title: "Fix crop on signed URLs!", source: "t")
    ticket.linearKey = "CMS-42"
    #expect(WorktreeCreator.folderName(for: ticket) == "cms-42")
    #expect(WorktreeCreator.branchName(for: ticket) == "fix/cms-42-fix-crop-on-signed-urls")
}

@Test func testStepsHandleWindowsLineEndings() {
    let steps = TestSteps.extract(from: "### How to test it?\r\n\r\n1. Open admin\r\n2. Upload\r\n\r\n### Related\r\n")
    #expect(steps == "1. Open admin\n2. Upload")
}

@Test func cleanupDeletesOnlyNamedUnprotectedBranches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repo = root.appendingPathComponent("repo").path
    let git = { (args: [String]) in Shell.run("/usr/bin/git", ["-C", repo] + args) }
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    _ = git(["init", "-q", "-b", "develop"])
    _ = git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
    for b in ["old-a", "old-b", "keep-me"] { _ = git(["branch", b]) }
    let wtPath = root.appendingPathComponent("wt-b").path
    _ = git(["worktree", "add", "-q", wtPath, "old-b"])

    var settings = AppSettings()
    settings.repoPath = repo
    settings.worktreesPath = root.appendingPathComponent("none").path

    let outcome = Cleanup.deleteBranches(["develop", "old-a", "old-b"], settings: settings)
    #expect(outcome.removed == ["old-a"])
    #expect(Set(outcome.failed.map(\.0)) == ["develop", "old-b"])
    let left = git(["for-each-ref", "--format=%(refname:short)", "refs/heads"]).stdout.split(separator: "\n").map(String.init)
    #expect(Set(left) == ["develop", "old-b", "keep-me"])

    // Running environment is never removed; the other one goes, with its branch.
    let blocked = Cleanup.removeWorktrees([wtPath], force: false, alsoDeleteBranch: true, settings: settings, running: [wtPath])
    #expect(blocked.removed.isEmpty)
    let done = Cleanup.removeWorktrees([wtPath], force: false, alsoDeleteBranch: true, settings: settings, running: [])
    #expect(done.removed.count == 1)
    #expect(!FileManager.default.fileExists(atPath: wtPath))
    let after = git(["for-each-ref", "--format=%(refname:short)", "refs/heads"]).stdout.split(separator: "\n").map(String.init)
    #expect(Set(after) == ["develop", "keep-me"])
    try? FileManager.default.removeItem(at: root)
}

@Test func legacySingleEnvironmentMigratesToList() throws {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    let json = #"{"tasks":[],"runningEnvironment":{"worktreePath":"/wt/a","processGroups":[1,2],"startedAt":"2026-09-30T10:00:00Z"}}"#
    let data = try d.decode(StoreData.self, from: Data(json.utf8))
    #expect(data.runningEnvironments.map(\.worktreePath) == ["/wt/a"])
    #expect(data.runningEnvironments.first?.port == nil)
}

@Test func portsDependOnSlot() {
    var s = AppSettings()
    s.repoPath = "/repo"
    #expect(s.port(for: "/repo") == 1338)
    #expect(s.port(for: "/repo/") == 1338)
    #expect(s.port(for: "/wt/pr-1") == 1339)
    #expect(s.isMonorepo("/repo") && !s.isMonorepo("/wt/pr-1"))
}

@Test func adminPasswordRules() {
    #expect(AdminBootstrap.passwordProblem("short1A") != nil)
    #expect(AdminBootstrap.passwordProblem("alllowercase1") != nil)
    #expect(AdminBootstrap.passwordProblem("ALLUPPERCASE1") != nil)
    #expect(AdminBootstrap.passwordProblem("NoNumbersHere") != nil)
    #expect(AdminBootstrap.passwordProblem("Strapi2026ok") == nil)
}

@Test func qaDefaultsToPendingOnlyForPRs() {
    var t = TrackedTask(kind: .fix, title: "x", source: "t")
    #expect(t.qa == nil)
    t.prNumber = 1
    #expect(t.qa == .pending)
    t.qaState = .skipped
    #expect(t.qa == .skipped)
}

@Test func qaFollowsPRLabelsExceptRightAfterLocalChange() throws {
    #expect(QAState.from(labels: ["pr: fix", "qa-done"]) == .done)
    #expect(QAState.from(labels: ["QA passed"]) == .done)
    #expect(QAState.from(labels: ["qa-skipped"]) == .skipped)
    #expect(QAState.from(labels: ["needs-qa"]) == .pending)

    var labelled = try pr()
    let d = JSONDecoder()
    labelled.labels = try d.decode(PullRequest.Nodes<PullRequest.Label>.self, from: Data(#"{"nodes":[{"name":"qa-skipped"}]}"#.utf8))
    var data = StoreData()
    GitHubSync.apply(.init(me: "me", authored: [labelled], requested: [], reviewed: []), to: &data, worktrees: [])
    #expect(data.tasks[0].qa == .skipped)

    // Just marked done in Mirador: the stale label must not win.
    data.tasks[0].qaState = .done
    data.tasks[0].qaChangedAt = .now
    GitHubSync.apply(.init(me: "me", authored: [labelled], requested: [], reviewed: []), to: &data, worktrees: [])
    #expect(data.tasks[0].qa == .done)

    // Later, the label (removed by someone) is the truth again.
    data.tasks[0].qaChangedAt = Date().addingTimeInterval(-600)
    GitHubSync.apply(.init(me: "me", authored: [try pr()], requested: [], reviewed: []), to: &data, worktrees: [])
    #expect(data.tasks[0].qa == .pending)
}

@Test func myCommentAfterFeedbackMeansWaitingForReview() throws {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    func comments(_ json: String) throws -> PullRequest.Nodes<PullRequest.Comment> {
        try d.decode(PullRequest.Nodes<PullRequest.Comment>.self, from: Data(json.utf8))
    }
    // Reviewer asked for changes in a plain comment, no push yet: my turn.
    var p = try pr(lastCommit: "2026-09-10T10:00:00Z")
    p.comments = try comments(#"{"nodes":[{"author":{"login":"rev"},"createdAt":"2026-09-11T10:00:00Z"}]}"#)
    #expect(GitHubSync.status(authored: p, me: "me") == .changesRequested)
    // I answered "can you test again?": their turn.
    p.comments = try comments(#"{"nodes":[{"author":{"login":"rev"},"createdAt":"2026-09-11T10:00:00Z"},{"author":{"login":"me"},"createdAt":"2026-09-12T10:00:00Z"}]}"#)
    #expect(GitHubSync.status(authored: p, me: "me") == .waitingForReview)
    // Bots do not count as feedback.
    p.comments = try comments(#"{"nodes":[{"author":{"login":"trunk-io"},"createdAt":"2026-09-13T10:00:00Z"},{"author":{"login":"me"},"createdAt":"2026-09-12T10:00:00Z"}]}"#)
    #expect(GitHubSync.status(authored: p, me: "me") == .waitingForReview)
}

@Test func agentGuideUsesNewNameAndValidSkillHeader() {
    #expect(AgentGuide.skill.hasPrefix("---\nname: mirador\ndescription: "))
    #expect(!AgentGuide.body.contains("trackr "))
    #expect(!AgentGuide.body.contains("/Users/"))
    #expect(AgentGuide.prompt.contains("mirador guide"))
}

@Test func startupPhaseFollowsInstallAndBuildMarkers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    // node_modules alone (install interrupted or still running) is not "installed".
    #expect(EnvironmentRunner.startupPhase(of: root.path) == .installing)
    FileManager.default.createFile(atPath: root.appendingPathComponent("node_modules/.yarn-state.yml").path, contents: Data())
    #expect(EnvironmentRunner.startupPhase(of: root.path) == .building)
    let dist = root.appendingPathComponent("packages/core/strapi/dist")
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dist.appendingPathComponent("cli.js").path, contents: Data())
    #expect(EnvironmentRunner.startupPhase(of: root.path) == .starting)
    try? FileManager.default.removeItem(at: root)
}

@Test func linearKeysFollowConfiguredTeams() {
    #expect(LinearKey.find(in: "fix/upgrade-vite-6") == nil)
    var s = AppSettings()
    s.linearTeamKeys = "CMS, DX"
    #expect(s.teamKeys == ["CMS", "DX"])
    #expect(LinearKey.find(in: "feat/dx-12-docs", prefixes: s.teamKeys) == "DX-12")
    #expect(LinearKey.find(in: "fix/cms-123-x", prefixes: s.teamKeys) == "CMS-123")
    #expect(LinearKey.find(in: "fix/upgrade-vite-6", prefixes: s.teamKeys) == nil)
}
