import Foundation
import MiradorCore

let usage = """
mirador — update Mirador from the terminal or from an AI agent.
Agents: run `mirador guide` first.

  mirador start [--kind fix|feature|chore|review|community] [--title T] [--linear CMS-1] [--pr N] [--branch B]
      Create (or resume) the task for the current worktree and mark it in progress / reviewing.
  mirador add <link>             Track a GitHub PR or Linear ticket (URL, #123 or CMS-123).
  mirador status <status> [ref]  Set a status (ref = PR number, CMS key, branch or path; default: current worktree).
  mirador note <text> [--ref R]  Add a one-line note.
  mirador link [ref] [--pr N] [--linear CMS-1] [--title T] [--kind K]
  mirador show [ref] · mirador list [--all] · mirador sync
  mirador worktree <ref> [--dir D]              Create a worktree (PR: gh pr checkout; ticket: new branch).
  mirador env start|stop|status [path] [--all]  Monorepo and one worktree run side by side.
  mirador admin [path] [--port N] [--email E]   Create the Settings super admin on a fresh running app.
  mirador cleanup [--verbose]                   Stale branches and worktrees (read-only).
  mirador guide [--skill]                       Rules for agents (or the Claude Code skill file).

Statuses to set by hand: in-progress, reviewing, taken-over, done-locally, addressing, blocked, todo, closed, released.
Everything else is set by the GitHub / Linear sync.
"""

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                    options[key] = raw[i + 1]
                    i += 1
                } else {
                    flags.insert(key)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mirador: \(message)\n".utf8))
    exit(1)
}

let store = Store()
let cwd = FileManager.default.currentDirectoryPath
var raw = Array(CommandLine.arguments.dropFirst())
guard !raw.isEmpty else { print(usage); exit(0) }
let command = raw.removeFirst()
let args = Args(raw)

/// Ref for the current directory: its worktree root, then its branch.
func localRefs() -> [String] {
    var refs: [String] = []
    if let top = Worktrees.topLevel(at: cwd) { refs.append(top) }
    if let branch = Worktrees.currentBranch(at: cwd) { refs.append(branch) }
    return refs
}

func resolve(_ explicit: String?, in data: StoreData) -> Int? {
    if let explicit { return data.find(explicit) }
    for ref in localRefs() {
        if let i = data.find(ref) { return i }
    }
    return nil
}

func describe(_ t: TrackedTask) -> String {
    var parts = ["[\(t.status.label)]", t.kind.label, "—", t.title]
    if let pr = t.prNumber { parts.append("#\(pr)") }
    if let key = t.linearKey { parts.append(key) }
    return parts.joined(separator: " ")
}

func apply(options: [String: String], to t: inout TrackedTask) {
    if let kind = options["kind"] {
        guard let k = TaskKind(rawValue: kind) else { fail("unknown kind \(kind)") }
        t.kind = k
    }
    if let title = options["title"] { t.title = title }
    if let key = options["linear"] { t.linearKey = LinearKey.find(in: key) ?? key.uppercased() }
    if let pr = options["pr"] {
        guard let n = Int(pr.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else { fail("bad PR number \(pr)") }
        t.prNumber = n
    }
    if let branch = options["branch"] { t.branch = branch }
    t.updatedAt = .now
}

switch command {
case "start":
    let top = Worktrees.topLevel(at: cwd)
    let branch = args.options["branch"] ?? Worktrees.currentBranch(at: cwd)
    let task: TrackedTask = store.update { data in
        let explicit = args.options["pr"] ?? args.options["linear"]
        let index = explicit.flatMap { data.find($0) } ?? resolve(nil, in: data)
        var t: TrackedTask
        if let index {
            t = data.tasks[index]
        } else {
            let kind = TaskKind(rawValue: args.options["kind"] ?? "") ?? .fix
            t = TrackedTask(kind: kind, title: args.options["title"] ?? branch ?? "Untitled task", source: "claude")
        }
        apply(options: args.options, to: &t)
        t.branch = t.branch ?? branch
        t.worktreePath = t.worktreePath ?? top
        t.linearKey = t.linearKey ?? LinearKey.find(in: branch)
        t.archived = false
        t.noteStart(.now)
        if t.status == t.kind.flow[0] || t.status == .blocked { t.setStatus(t.kind.startStatus, source: "claude") }
        if let index { data.tasks[index] = t } else { data.tasks.append(t) }
        return t
    }
    print(describe(task))

case "add":
    guard let raw = args.positional.first, let link = LinkParser.parse(raw) else { fail("usage: mirador add <GitHub PR or Linear link>") }
    do {
        var preview = try LinkPreview.resolve(link, linearKey: LinearAPI.apiKey)
        if let kind = args.options["kind"].flatMap(TaskKind.init(rawValue:)) { preview.kind = kind }
        let worktrees = Worktrees.list(settings: store.load().settings)
        let task: TrackedTask = store.update { data in data.tasks[preview.insert(into: &data, worktrees: worktrees)] }
        print(describe(task))
    } catch {
        fail(error.localizedDescription)
    }

case "status":
    guard let value = args.positional.first, let status = TaskStatus(rawValue: value) else {
        fail("usage: mirador status <status> [ref]\nstatuses: \(TaskStatus.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    let task: TrackedTask = store.update { data in
        guard let i = resolve(args.positional.dropFirst().first, in: data) else { fail("no task found; run `mirador start` first") }
        data.tasks[i].setStatus(status, source: "claude")
        return data.tasks[i]
    }
    print(describe(task))

case "link":
    let task: TrackedTask = store.update { data in
        guard let i = resolve(args.positional.first, in: data) else { fail("no task found") }
        apply(options: args.options, to: &data.tasks[i])
        return data.tasks[i]
    }
    print(describe(task))

case "note":
    let text = args.positional.joined(separator: " ")
    guard !text.isEmpty else { fail("usage: mirador note <text>") }
    let task: TrackedTask = store.update { data in
        guard let i = resolve(args.options["ref"], in: data) else { fail("no task found") }
        let stamp = DateFormatter.localizedString(from: .now, dateStyle: .short, timeStyle: .short)
        data.tasks[i].notes += (data.tasks[i].notes.isEmpty ? "" : "\n") + "\(stamp) — \(text)"
        data.tasks[i].updatedAt = .now
        return data.tasks[i]
    }
    print(describe(task))

case "show":
    let data = store.load()
    guard let i = resolve(args.positional.first, in: data) else { fail("no task found") }
    let t = data.tasks[i]
    print(describe(t))
    if let url = t.githubURL { print("GitHub:   \(url.absoluteString)") }
    if let url = t.linearURL { print("Linear:   \(url.absoluteString)") }
    if let wt = t.worktreePath { print("Worktree: \(wt)") }
    if let b = t.branch { print("Branch:   \(b)") }
    if !t.notes.isEmpty { print("Notes:\n\(t.notes)") }

case "list":
    let data = store.load()
    let tasks = data.tasks.filter { args.flags.contains("all") || (!$0.archived && !$0.status.isFinished) }
    if tasks.isEmpty { print("No active tasks.") }
    for t in tasks.sorted(by: { $0.updatedAt > $1.updatedAt }) { print(describe(t)) }

case "sync":
    do {
        let snap = try GitHubSync.fetch()
        let worktrees = Worktrees.list(settings: store.load().settings)
        let activity = LocalWork.activity(in: worktrees)
        let (n, local) = store.update { data in
            (GitHubSync.apply(snap, to: &data, worktrees: worktrees), LocalWork.apply(worktrees: worktrees, activity: activity, to: &data))
        }
        print("Synced GitHub: \(n) task(s) updated, \(local) new local branch task(s).")
    } catch {
        fail(error.localizedDescription)
    }

case "env":
    let sub = args.positional.first ?? "status"
    let path = args.positional.dropFirst().first.map { ($0 as NSString).standardizingPath } ?? Worktrees.topLevel(at: cwd)
    let settings = store.load().settings
    switch sub {
    case "start":
        guard let path else { fail("not in a worktree") }
        do {
            try EnvironmentRunner.start(worktreePath: path, store: store)
            print("Starting \(path) on port \(settings.port(for: path)). Logs: \(EnvironmentRunner.logDirectory.path)")
        } catch {
            fail(error.localizedDescription)
        }
    case "stop":
        if args.flags.contains("all") || path == nil { EnvironmentRunner.stopAll(store: store) } else { EnvironmentRunner.stop(path: path!, store: store) }
        print("Stopped.")
    default:
        let envs = store.load().runningEnvironments
        if envs.isEmpty { print("No environment running.") }
        for env in envs {
            let port = env.port ?? settings.port(for: env.worktreePath)
            print("\(env.worktreePath) :\(port): \(EnvironmentRunner.state(of: env.worktreePath, store: store).label)")
        }
    }

case "worktree":
    var settings = store.load().settings
    if let dir = args.options["dir"] { settings.worktreesPath = (dir as NSString).standardizingPath }
    let data = store.load()
    guard let i = resolve(args.positional.first, in: data) else { fail("no task found; use a PR number, CMS key or branch") }
    do {
        let created = try WorktreeCreator.create(for: data.tasks[i], settings: settings)
        let id = data.tasks[i].id
        store.update { d in
            guard let j = d.tasks.firstIndex(where: { $0.id == id }) else { return }
            d.tasks[j].worktreePath = created.path
            d.tasks[j].branch = d.tasks[j].branch ?? created.branch
            if let b = created.branch { d.seenBranches = (d.seenBranches ?? []) + [b] }
        }
        print("Created \(created.path) on \(created.branch ?? "detached")")
    } catch {
        fail(error.localizedDescription)
    }

case "cleanup":
    // Read-only report; deleting happens in the app, one confirmed selection at a time.
    let data = store.load()
    let report = Cleanup.scan(settings: data.settings, running: data.runningEnvironments.map(\.worktreePath))
    let groups = Dictionary(grouping: report.branches, by: \.state)
    for state in Cleanup.BranchState.allCases {
        let list = groups[state] ?? []
        print("\(state.label): \(list.count)")
        if args.flags.contains("verbose") {
            for b in list { print("  \(b.name)\(b.prNumber.map { " #\($0)" } ?? "")\(b.protectedReason.map { " [\($0)]" } ?? "")") }
        }
    }
    print("Worktrees:")
    for w in report.worktrees {
        print("  \(w.name) — \(w.branch ?? "detached") · \(w.branchState?.label ?? "?") · \(w.dirtyFiles) changed file(s)\(w.protectedReason.map { " [\($0)]" } ?? "")")
    }

case "admin":
    // Create the configured super admin on a running app that has none yet.
    let settings = store.load().settings
    let path = args.positional.first.map { ($0 as NSString).standardizingPath } ?? Worktrees.topLevel(at: cwd)
    guard let port = args.options["port"].flatMap(Int.init) ?? path.map(settings.port(for:)) else { fail("usage: mirador admin [path] [--port N]") }
    let email = args.options["email"] ?? settings.adminEmail
    guard !email.isEmpty else { fail("set the admin email in Settings (or pass --email)") }
    guard let password = ProcessInfo.processInfo.environment["MIRADOR_ADMIN_PASSWORD"] ?? Keychain.read(AdminBootstrap.passwordAccount) else {
        fail("no admin password saved in Settings")
    }
    let credentials = AdminBootstrap.Credentials(email: email, password: password,
                                                 firstname: settings.adminFirstname.isEmpty ? "Admin" : settings.adminFirstname,
                                                 lastname: settings.adminLastname)
    switch AdminBootstrap.ensureAdmin(port: port, credentials: credentials) {
    case .created: print("Created super admin \(email) on :\(port).")
    case .alreadyHasAdmin: print("An admin already exists on :\(port).")
    case .failed(let message): fail(message)
    }

case "guide":
    print(args.flags.contains("skill") ? AgentGuide.skill : AgentGuide.body)

case "help", "-h", "--help":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
