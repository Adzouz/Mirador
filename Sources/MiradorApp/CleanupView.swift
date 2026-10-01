import SwiftUI
import MiradorCore

/// Stale branches and worktrees. Nothing is removed without an explicit selection and a confirmation listing every name.
struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var report: Cleanup.Report?
    @State private var scanning = false
    @State private var working = false
    @State private var branchFilter: Cleanup.BranchState? = nil
    @State private var selectedBranches: Set<String> = []
    @State private var selectedWorktrees: Set<String> = []
    @State private var confirmBranches = false
    @State private var confirmWorktrees = false
    @State private var result: String?
    @State private var job: Job?
    /// Items that could not be removed, with the reason; shown on their row until the next scan.
    @State private var skipped: [String: String] = [:]

    struct Job: Equatable {
        var verb: String
        var total: Int
        var done = 0
        var failed = 0
        var current: String?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let job {
                    JobCard(job: job)
                } else if let result {
                    Label(result, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
                }
                if let report {
                    worktreesCard(report)
                    branchesCard(report)
                } else if scanning {
                    Card { HStack { ProgressView().controlSize(.small); Muted("Fetching, pruning and asking GitHub about every branch…") } }
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .onAppear { if report == nil { scan() } }
        .confirmationDialog(branchDialogTitle, isPresented: $confirmBranches, titleVisibility: .visible) {
            Button("Delete \(selectedBranches.count) branch\(selectedBranches.count == 1 ? "" : "es")", role: .destructive, action: deleteBranches)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(listing(selectedBranches.sorted()))
        }
        .confirmationDialog(worktreeDialogTitle, isPresented: $confirmWorktrees, titleVisibility: .visible) {
            Button("Remove and delete their branches", role: .destructive) { removeWorktrees(alsoBranch: true) }
            Button("Remove, keep the branches") { removeWorktrees(alsoBranch: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(worktreeMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cleanup").font(.system(size: 20, weight: .semibold))
                Muted(report.map { "Scanned \($0.scannedAt.formatted(.relative(presentation: .named))) · merged status comes from GitHub (squash merges included)" }
                      ?? "Local branches and worktrees you may not need anymore.")
            }
            Spacer()
            Button(action: scan) {
                if scanning { ProgressView().controlSize(.small) } else { Label("Rescan", systemImage: "arrow.clockwise") }
            }
            .shadButton(.outline)
            .disabled(scanning || working)
        }
    }

    // MARK: Worktrees

    private func worktreesCard(_ report: Cleanup.Report) -> some View {
        let removable = report.worktrees.filter(\.canRemove)
        return Card {
            CardHeader(title: "Worktrees", description: "\(report.worktrees.count) besides the monorepo") {
                Button("Select stale") {
                    selectedWorktrees = Set(removable.filter { $0.branchState?.isStale == true && $0.dirtyFiles == 0 }.map(\.path))
                }
                .shadButton(.ghost)
                Button { confirmWorktrees = true } label: {
                    Label("Remove \(selectedWorktrees.count)", systemImage: "trash")
                }
                .shadButton(.destructive)
                .disabled(selectedWorktrees.isEmpty || working)
            }
            VStack(spacing: 0) {
                ForEach(report.worktrees) { wt in
                    WorktreeCleanupRow(info: wt, selected: selectedWorktrees.contains(wt.path),
                                       busy: job?.current == wt.path, skipped: skipped[wt.path]) { on in
                        if on { selectedWorktrees.insert(wt.path) } else { selectedWorktrees.remove(wt.path) }
                    }
                    if wt.id != report.worktrees.last?.id { Divider().overlay(Theme.border) }
                }
            }
        }
    }

    // MARK: Branches

    private func branchesCard(_ report: Cleanup.Report) -> some View {
        let visible = report.branches.filter { branchFilter == nil || $0.state == branchFilter }
        return Card {
            CardHeader(title: "Local branches", description: "\(report.branches.count) in the monorepo") {
                Button("Select stale") {
                    selectedBranches = Set(visible.filter { $0.state.isStale && $0.canDelete }.map(\.name))
                }
                .shadButton(.ghost)
                if !selectedBranches.isEmpty {
                    Button("Clear") { selectedBranches = [] }.shadButton(.ghost)
                }
                Button { confirmBranches = true } label: {
                    Label("Delete \(selectedBranches.count)", systemImage: "trash")
                }
                .shadButton(.destructive)
                .disabled(selectedBranches.isEmpty || working)
            }
            HStack(spacing: 6) {
                FilterChip(title: "All", count: report.branches.count, on: branchFilter == nil) { branchFilter = nil }
                ForEach(Cleanup.BranchState.allCases, id: \.self) { state in
                    FilterChip(title: state.label, count: report.branches.filter { $0.state == state }.count, on: branchFilter == state, color: state.color) {
                        branchFilter = branchFilter == state ? nil : state
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(visible) { branch in
                    BranchCleanupRow(branch: branch, selected: selectedBranches.contains(branch.name),
                                     busy: job?.current == branch.name, skipped: skipped[branch.name]) { on in
                        if on { selectedBranches.insert(branch.name) } else { selectedBranches.remove(branch.name) }
                    }
                    if branch.id != visible.last?.id { Divider().overlay(Theme.border) }
                }
            }
        }
    }

    // MARK: Actions

    private var branchDialogTitle: String { "Delete \(selectedBranches.count) local branch\(selectedBranches.count == 1 ? "" : "es")?" }
    private var worktreeDialogTitle: String { "Remove \(selectedWorktrees.count) worktree\(selectedWorktrees.count == 1 ? "" : "s")?" }

    private var worktreeMessage: String {
        let dirty = (report?.worktrees ?? []).filter { selectedWorktrees.contains($0.path) && $0.dirtyFiles > 0 }
        var text = listing(selectedWorktrees.sorted().map { ($0 as NSString).lastPathComponent })
        if !dirty.isEmpty { text += "\n\n⚠️ \(dirty.map(\.name).joined(separator: ", ")) \(dirty.count == 1 ? "has" : "have") uncommitted changes that will be lost." }
        let branches = (report?.worktrees ?? []).filter { selectedWorktrees.contains($0.path) }.compactMap(\.branch)
        if !branches.isEmpty { text += "\n\nAlso delete their branches?\n" + listing(branches.sorted()) }
        return text
    }

    private func listing(_ names: [String]) -> String {
        let shown = names.prefix(12).joined(separator: "\n")
        return names.count > 12 ? shown + "\n…and \(names.count - 12) more" : shown
    }

    private func scan() { scan(keepSkipped: false) }

    private func scan(keepSkipped: Bool) {
        scanning = true
        let settings = model.settings
        let running = model.runningPaths
        Task.detached {
            let r = Cleanup.scan(settings: settings, running: running)
            await MainActor.run {
                report = r
                scanning = false
                if !keepSkipped { skipped = [:] }
                let valid = Set(r.branches.filter(\.canDelete).map(\.name))
                selectedBranches.formIntersection(valid)
                selectedWorktrees.formIntersection(Set(r.worktrees.filter(\.canRemove).map(\.path)))
            }
        }
    }

    private func deleteBranches() {
        let names = selectedBranches.sorted()
        working = true
        skipped = [:]
        job = Job(verb: "Deleting", total: names.count)
        let settings = model.settings
        Task.detached {
            let outcome = Cleanup.deleteBranches(names, settings: settings) { event in
                DispatchQueue.main.async { apply(event) { name in report?.branches.removeAll { $0.name == name } } }
            }
            await MainActor.run {
                finish(summary(outcome, noun: "branch", plural: "branches"))
            }
        }
    }

    /// Updates the progress card and drops finished items from the list as they go.
    private func apply(_ event: Cleanup.Progress, removeFromList: (String) -> Void) {
        switch event {
        case .started(let item):
            job?.current = item
        case .finished(let item, let error):
            job?.done += 1
            selectedBranches.remove(item)
            selectedWorktrees.remove(item)
            if let error {
                job?.failed += 1
                skipped[item] = error
            } else {
                withAnimation(.easeOut(duration: 0.2)) { removeFromList(item) }
            }
        }
    }

    private func finish(_ message: String) {
        job = nil
        working = false
        result = message
        scan(keepSkipped: true)
    }

    private func removeWorktrees(alsoBranch: Bool) {
        let paths = Array(selectedWorktrees)
        let dirty = (report?.worktrees ?? []).contains { selectedWorktrees.contains($0.path) && $0.dirtyFiles > 0 }
        working = true
        let settings = model.settings
        let running = model.runningPaths
        skipped = [:]
        job = Job(verb: "Removing", total: paths.count)
        Task.detached {
            let outcome = Cleanup.removeWorktrees(paths, force: dirty, alsoDeleteBranch: alsoBranch, settings: settings, running: running) { event in
                DispatchQueue.main.async {
                    apply(event) { path in
                        let branch = report?.worktrees.first { $0.path == path }?.branch
                        report?.worktrees.removeAll { $0.path == path }
                        if alsoBranch, let branch { report?.branches.removeAll { $0.name == branch } }
                    }
                }
            }
            await MainActor.run {
                model.forgetWorktrees(outcome.removed)
                finish(summary(outcome, noun: "worktree", plural: "worktrees"))
            }
        }
    }

    private func summary(_ o: Cleanup.Outcome, noun: String, plural: String) -> String {
        var s = "Removed \(o.removed.count) \(o.removed.count == 1 ? noun : plural)."
        if !o.failed.isEmpty { s += " Skipped \(o.failed.count): " + o.failed.prefix(3).map { "\(($0.0 as NSString).lastPathComponent) (\($0.1))" }.joined(separator: ", ") }
        return s
    }
}

extension Cleanup.BranchState {
    var color: Color {
        switch self {
        case .merged: .purple
        case .closed: .red
        case .gone: .orange
        case .localOnly: Color(nsColor: .systemGray)
        case .active: .green
        }
    }
}

struct FilterChip: View {
    let title: String
    let count: Int
    let on: Bool
    var color: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 6, height: 6) }
                Text(title)
                Text("\(count)").foregroundStyle(Theme.mutedForeground)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(on ? Theme.accent : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
    }
}

struct BranchCleanupRow: View {
    @Environment(AppModel.self) private var model
    let branch: Cleanup.Branch
    let selected: Bool
    var busy = false
    var skipped: String?
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            RowCheck(selected: selected, busy: busy, enabled: branch.canDelete, toggle: toggle)
            VStack(alignment: .leading, spacing: 3) {
                Text(branch.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Badge(text: branch.state.label, variant: .outline, color: branch.state.color)
                    if let pr = branch.prNumber {
                        Button("#\(String(pr))") { model.open(URL(string: "https://github.com/strapi/strapi/pull/\(pr)")) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.mutedForeground)
                    }
                    if let reason = branch.protectedReason ?? branch.note { Muted(reason, size: 11) }
                    if busy { Muted("Deleting…", size: 11) }
                    if let skipped { SkippedNote(reason: skipped) }
                }
            }
            Spacer()
            Muted(branch.lastCommit.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)), size: 11)
        }
        .padding(.vertical, 7)
        .opacity(branch.canDelete ? 1 : 0.6)
    }
}

struct WorktreeCleanupRow: View {
    @Environment(AppModel.self) private var model
    let info: Cleanup.WorktreeInfo
    let selected: Bool
    var busy = false
    var skipped: String?
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            RowCheck(selected: selected, busy: busy, enabled: info.canRemove, toggle: toggle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.name).font(.system(size: 13, weight: .medium))
                    Text(info.branch ?? "detached").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.mutedForeground).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let state = info.branchState { Badge(text: state.label, variant: .outline, color: state.color) }
                    if info.dirtyFiles > 0 { Badge(text: "\(info.dirtyFiles) uncommitted", variant: .outline, color: .orange) }
                    if let pr = info.prNumber {
                        Button("#\(String(pr))") { model.open(URL(string: "https://github.com/strapi/strapi/pull/\(pr)")) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.mutedForeground)
                    }
                    if let reason = info.protectedReason { Muted(reason, size: 11) }
                    if busy { Muted("Removing… (large folders take a moment)", size: 11) }
                    if let skipped { SkippedNote(reason: skipped) }
                }
            }
            Spacer()
            if let last = info.lastActivity { Muted(last.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)), size: 11) }
            Button { model.reveal(info.path) } label: { Image(systemName: "folder") }
                .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
                .help(info.path)
        }
        .padding(.vertical, 7)
        .opacity(info.canRemove ? 1 : 0.6)
    }
}

struct JobCard: View {
    let job: CleanupView.Job

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(job.verb) \(min(job.done + 1, job.total)) of \(job.total)")
                        .font(.system(size: 13, weight: .semibold))
                    if let current = job.current {
                        Text((current as NSString).lastPathComponent == current ? current : (current as NSString).lastPathComponent)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Muted("\(job.done - job.failed) done" + (job.failed > 0 ? " · \(job.failed) skipped" : ""), size: 11)
            }
            ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                .tint(Theme.primary)
        }
    }
}

struct RowCheck: View {
    let selected: Bool
    let busy: Bool
    let enabled: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        ZStack {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(get: { selected }, set: toggle))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!enabled)
            }
        }
        .frame(width: 18)
    }
}

struct SkippedNote: View {
    let reason: String
    var body: some View {
        Label("Skipped: \(reason)", systemImage: "exclamationmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .lineLimit(1)
            .help(reason)
    }
}
