import AppKit
import SwiftUI
import MiradorCore

/// Paste a GitHub PR, GitHub issue or Linear link → preview → add it as a task, or link it to `target`.
struct AddTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Set when linking to an existing task instead of adding one.
    var target: TrackedTask? = nil
    var onAdded: (TrackedTask.ID) -> Void = { _ in }

    @State private var text = ""
    @State private var preview: LinkPreview?
    @State private var kind: TaskKind = .fix
    @State private var loading = false
    @State private var error: String?
    @State private var lookup: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(target.map { "Link to “\($0.title)”" } ?? "Add a task")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                Muted("Paste a GitHub PR, GitHub issue or Linear ticket link. #1234 and CMS-123 work too.")
            }

            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(Theme.mutedForeground)
                TextField("https://github.com/strapi/strapi/pull/…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(confirm)
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(focused ? Theme.mutedForeground : Theme.border))

            if let preview {
                Card(padding: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(for: preview.taskLink))
                            .frame(width: 30, height: 30)
                            .background(Theme.muted, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preview.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
                            Muted(preview.subtitle)
                            if target == nil {
                                HStack(spacing: 6) {
                                    StatusBadge(status: preview.status)
                                    if let key = preview.linearKey, preview.link.prNumber != nil { Badge(text: key) }
                                    if let pr = preview.prNumber, preview.link.prNumber == nil { Badge(text: "#\(String(pr))") }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if target == nil {
                        HStack {
                            Muted("Track as")
                            Picker("", selection: $kind) {
                                ForEach(TaskKind.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                    }
                }
                if let note = linkNote(for: preview) {
                    Label(note, systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(3)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.destructive)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.shadButton(.ghost, size: .md).keyboardShortcut(.cancelAction)
                Button(target == nil ? "Add task" : "Link", action: confirm)
                    .shadButton(.primary, size: .md)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || alreadyLinked)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.card)
        .onAppear {
            focused = true
            if let clip = NSPasteboard.general.string(forType: .string), LinkParser.parse(clip) != nil {
                text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .onChange(of: text, initial: true) { _, value in resolve(value) }
    }

    private var alreadyLinked: Bool {
        guard let target, let preview else { return false }
        return target.has(preview.taskLink)
    }

    /// What linking will do beyond the obvious: merge another task, or replace a link of the same type.
    private func linkNote(for preview: LinkPreview) -> String? {
        guard let target else { return nil }
        let link = preview.taskLink
        if target.has(link) { return "Already linked to this task." }
        var notes: [String] = []
        if let other = model.tasks.owner(of: link, excluding: target.id) {
            notes.append("Already tracked as “\(other.title)”. Linking merges it into this task.")
        }
        if let old = target.links.first(where: { $0.sameType(as: link) }) {
            notes.append("Replaces \(old.label).")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private func symbol(for link: TaskLink) -> String {
        switch link {
        case .pr: "arrow.triangle.pull"
        case .issue: "smallcircle.filled.circle"
        case .linear: "circle.hexagongrid"
        }
    }

    private func resolve(_ value: String) {
        lookup?.cancel()
        preview = nil
        error = nil
        guard let link = LinkParser.parse(value) else {
            loading = false
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { error = "Not a GitHub PR, issue or Linear link." }
            return
        }
        loading = true
        let key = model.linearKey
        lookup = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await Task.detached { Result { try LinkPreview.resolve(link, linearKey: key) } }.value
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let p):
                preview = p
                kind = p.kind
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }

    private func confirm() {
        guard var p = preview, !alreadyLinked else { return }
        if let target {
            model.link(p, to: target.id)
            dismiss()
            return
        }
        p.kind = kind
        if p.kind.isReview != (preview?.kind.isReview ?? false) { p.status = kind.flow[0] }
        let id = model.add(p)
        dismiss()
        onAdded(id)
    }
}
