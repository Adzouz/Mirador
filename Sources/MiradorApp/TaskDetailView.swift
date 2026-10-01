import SwiftUI
import MiradorCore

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask
    @State private var notes = ""
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ProgressCard(task: task)
                if let ci = task.ci, !task.status.isFinished { CICard(task: task, ci: ci) }
                if let steps = task.testSteps { TestStepsCard(steps: steps) }
                worktreeCard
                notesCard
                ActivityCard(task: task)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .onAppear(perform: load)
        .onChange(of: task.id) { load() }
    }

    private func load() {
        notes = task.notes
        title = task.title
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One line when it fits; on narrow windows the PR / Linear links get their own line instead of being cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    propertyMenus
                    Spacer(minLength: 8)
                    LinkButtons(task: task).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { propertyMenus }
                    LinkButtons(task: task).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { kindAndStatusMenus }
                    HStack(spacing: 8) { priorityAndQAMenus }
                    LinkButtons(task: task).fixedSize()
                }
            }

            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.foreground)
                .focused($titleFocused)
                .onSubmit(saveTitle)
                .onChange(of: titleFocused) { _, focused in if !focused { saveTitle() } }

            PropertiesGrid(task: task, me: model.me)
        }
    }

    @ViewBuilder
    private var propertyMenus: some View {
        kindAndStatusMenus
        priorityAndQAMenus
    }

    @ViewBuilder
    private var kindAndStatusMenus: some View {
        ShadMenu {
            ForEach(TaskKind.allCases) { k in
                Button { model.mutate(task.id) { $0.kind = k } } label: { Label(k.label, systemImage: k.symbol) }
            }
        } label: {
            Label(task.kind.label, systemImage: task.kind.symbol)
        }
        ShadMenu {
            ForEach(statusChoices) { s in
                Button(s.label) { model.setStatus(task.id, s) }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(task.status.color).frame(width: 7, height: 7)
                Text(task.status.label)
            }
        }
    }

    @ViewBuilder
    private var priorityAndQAMenus: some View {
        ShadMenu {
            PriorityMenu(task: task)
        } label: {
            HStack(spacing: 6) {
                PriorityIcon(priority: task.priority)
                Text(task.priority == .none ? "Priority" : task.priority.label)
            }
        }
        .help(task.priorityOverride == nil && task.linearPriority != nil ? "From Linear" : "Set locally")
        if let qa = task.qa {
            ShadMenu {
                QAMenu(task: task)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: qa.symbol).foregroundStyle(qa.color)
                    Text(qa.label).foregroundStyle(qa.color)
                }
            }
            .help("Your QA mark for this PR (kept in Mirador)")
        }
    }

    private func saveTitle() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != task.title else { return }
        model.mutate(task.id) { $0.title = value }
    }

    private var statusChoices: [TaskStatus] {
        var list = task.kind.flow + [.blocked, .closed]
        if !list.contains(task.status) { list.append(task.status) }
        return list
    }

    private var worktreeCard: some View {
        Card {
            if let wt = model.worktree(for: task) {
                CardHeader(title: "Local environment", description: wt.isInstalled ? nil : "Not installed yet — the first Quickstart runs yarn install and yarn build (a few minutes).")
                PathField(path: wt.path)
                WorktreeActions(path: wt.path)
                Divider().overlay(Theme.border)
                EnvironmentControls(path: wt.path)
            } else {
                let creating = model.creatingWorktree.contains(task.id)
                CardHeader(title: "Local environment",
                           description: creating ? "Creating the worktree…" : "No worktree yet. Create one in \((model.settings.worktreesPath as NSString).abbreviatingWithTildeInPath)/\(WorktreeCreator.folderName(for: task)) to test it.") {
                    Button { model.createWorktree(for: task) } label: {
                        if creating { ProgressView().controlSize(.small) } else { Label("Create worktree", systemImage: "plus.rectangle.on.folder") }
                    }
                    .shadButton(.primary)
                    .disabled(creating)
                    .help(task.prNumber != nil ? "git worktree add + gh pr checkout \(String(task.prNumber!))" : "git worktree add on \(WorktreeCreator.branchName(for: task))")
                    ShadMenu {
                        ForEach(model.worktrees) { wt in
                            Button("\(wt.name) — \(wt.branch ?? "detached")") {
                                model.mutate(task.id) {
                                    $0.worktreePath = wt.path
                                    $0.branch = $0.branch ?? wt.branch
                                }
                            }
                        }
                    } label: {
                        Label("Link worktree", systemImage: "link")
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        Card {
            CardHeader(title: "Notes")
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Muted("Add context, links, repro steps…", size: 13).padding(.horizontal, 5).padding(.vertical, 8)
                }
                TextEditor(text: $notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .onChange(of: notes) { _, value in
                        guard value != task.notes else { return }
                        model.mutate(task.id) { $0.notes = value }
                    }
            }
            .padding(4)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius - 2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius - 2).strokeBorder(Theme.border))
        }
    }
}

/// Segmented progress through the task's flow, with a one-click "next step".
struct ProgressCard: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask

    var body: some View {
        let flow = task.kind.flow
        let index = flow.firstIndex(of: task.status)
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.status.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.foreground)
                    Muted(index.map { "Step \($0 + 1) of \(flow.count)" } ?? "Off the usual flow")
                }
                Spacer()
                if let i = index, i + 1 < flow.count {
                    let next = flow[i + 1]
                    Button { model.setStatus(task.id, next) } label: {
                        Label("Mark as \(next.label.lowercased())", systemImage: "arrow.right")
                    }
                    .shadButton(.outline)
                }
            }
            HStack(spacing: 3) {
                ForEach(Array(flow.enumerated()), id: \.element) { i, step in
                    Button { model.setStatus(task.id, step) } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index.map { i <= $0 } ?? false ? task.status.color : Theme.muted)
                            .frame(height: 6)
                            .contentShape(Rectangle().inset(by: -6))
                    }
                    .buttonStyle(.plain)
                    .help(step.label)
                }
            }
        }
    }
}

struct ActivityCard: View {
    let task: TrackedTask

    var body: some View {
        Card {
            CardHeader(title: "Activity")
            VStack(alignment: .leading, spacing: 0) {
                let items = Array(task.history.reversed().prefix(12))
                ForEach(Array(items.enumerated()), id: \.offset) { i, change in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 0) {
                            Circle().fill(change.status.color).frame(width: 8, height: 8).padding(.top, 4)
                            if i < items.count - 1 {
                                Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: 8)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(change.status.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.foreground)
                            Badge(text: change.source, variant: .secondary)
                            Spacer()
                            Muted(change.at.formatted(.dateTime.day().month(.abbreviated).hour().minute()), size: 11)
                        }
                        .padding(.bottom, 12)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Label / value pairs under the title, two per row.
struct PropertiesGrid: View {
    let task: TrackedTask
    let me: String?

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let value: AnyView
    }

    var body: some View {
        let items = self.items
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                GridRow {
                    cell(items[i])
                    if i + 1 < items.count { cell(items[i + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
            if let branch = task.branch {
                GridRow {
                    cell(Item(id: "Branch", symbol: "arrow.triangle.branch", value: AnyView(
                        Text(branch)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(branch)
                    )))
                    .gridCellColumns(2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radius + 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).strokeBorder(Theme.border))
    }

    private func cell(_ item: Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(item.id, systemImage: item.symbol)
                .labelStyle(TightLabelStyle())
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedForeground)
                .frame(width: 86, alignment: .leading)
            item.value
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var items: [Item] {
        var list: [Item] = []
        let opened = task.prNumber != nil && task.kind.isReview
        list.append(Item(id: opened ? "Opened" : "Started", symbol: "calendar",
                         value: AnyView(Text(task.startDate.formatted(date: .abbreviated, time: .omitted)))))
        list.append(Item(id: "Updated", symbol: "clock",
                         value: AnyView(Text(task.updatedAt.formatted(.relative(presentation: .named))))))
        if let author = task.prAuthor {
            list.append(Item(id: "Author", symbol: "person", value: AnyView(Text(author == me ? "You (@\(author))" : "@\(author)"))))
        }
        if let state = task.linearState {
            list.append(Item(id: "Linear", symbol: "circle.hexagongrid", value: AnyView(Text(state))))
        }
        return list
    }
}

struct CICard: View {
    @Environment(AppModel.self) private var model
    let task: TrackedTask
    let ci: CIStatus

    var body: some View {
        Card {
            CardHeader(title: "Checks", description: description) {
                Button { model.open(task.githubURL.map { $0.appendingPathComponent("checks") }) } label: {
                    Label("Open checks", systemImage: "arrow.up.right")
                }
                .shadButton(.outline)
            }
            HStack(spacing: 6) {
                Image(systemName: ci.state.symbol).foregroundStyle(ci.state.color)
                Text(ci.summary).font(.system(size: 13, weight: .semibold)).foregroundStyle(ci.state.color)
            }
            if !ci.failing.isEmpty { names(ci.failing, color: .red) }
            if ci.state == .pending, !ci.pending.isEmpty { names(Array(ci.pending.prefix(6)), color: .orange) }
            if !ci.expected.isEmpty {
                HStack(spacing: 6) {
                    ForEach(ci.expected, id: \.self) { Badge(text: $0, variant: .secondary) }
                    Muted("red until QA passes — expected", size: 11)
                }
            }
        }
    }

    private var description: String {
        let passed = ci.total - ci.failing.count - ci.pending.count - ci.expected.count
        return "\(passed) of \(ci.total) passed"
    }

    private func names(_ list: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list, id: \.self) { name in
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.foreground)
                }
            }
        }
    }
}

struct TestStepsCard: View {
    let steps: String
    @State private var copied = false

    var body: some View {
        Card {
            CardHeader(title: "How to test it?", description: "From the PR description") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(steps, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .shadButton(.ghost)
            }
            MarkdownBlocks(text: steps)
        }
    }
}

/// Small markdown renderer: headings, bullets, numbered steps, code blocks, inline styles.
struct MarkdownBlocks: View {
    let text: String

    private enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case bullet(String, level: Int)
        case numbered(String, String, level: Int)
        case code(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var code: [String]? = nil
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            if indent >= 4, !trimmed.isEmpty, !(trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.first?.isNumber == true) {
                flush()
                if case .code(let prev) = out.last { out[out.count - 1] = .code(prev + "\n" + trimmed) } else { out.append(.code(trimmed)) }
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("#") { flush(); out.append(.heading(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))); continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush(); out.append(.bullet(String(trimmed.dropFirst(2)), level: indent / 2)); continue
            }
            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), dot > trimmed.startIndex,
               trimmed[..<dot].allSatisfy(\.isNumber), trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush(); out.append(.numbered(String(trimmed[..<dot]), String(trimmed[trimmed.index(dot, offsetBy: 2)...]), level: indent / 3)); continue
            }
            paragraph.append(trimmed)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let t):
                    inline(t)
                case .heading(let t):
                    inline(t).font(.system(size: 12, weight: .semibold)).padding(.top, 4)
                case .bullet(let t, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Theme.mutedForeground)
                        inline(t)
                    }
                    .padding(.leading, CGFloat(level) * 14)
                case .numbered(let n, let t, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(n).").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.mutedForeground)
                        inline(t)
                    }
                    .padding(.leading, CGFloat(level) * 14)
                case .code(let c):
                    Text(c)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.muted, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.foreground)
    }

    private func inline(_ s: String) -> Text {
        let attributed = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(attributed)
    }
}
