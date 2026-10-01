import AppKit
import SwiftUI
import MiradorCore

/// Paste a GitHub PR or Linear link → preview → add.
struct AddTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onAdded: (TrackedTask.ID) -> Void

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
                Text("Add a task").font(.system(size: 16, weight: .semibold))
                Muted("Paste a GitHub PR or Linear ticket link. #1234 and CMS-123 work too.")
            }

            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(Theme.mutedForeground)
                TextField("https://github.com/strapi/strapi/pull/…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(add)
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(focused ? Theme.mutedForeground : Theme.border))

            if let preview {
                Card(padding: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: preview.link.prNumber != nil ? "arrow.triangle.pull" : "circle.hexagongrid")
                            .frame(width: 30, height: 30)
                            .background(Theme.muted, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preview.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
                            Muted(preview.subtitle)
                            HStack(spacing: 6) {
                                StatusBadge(status: preview.status)
                                if let key = preview.linearKey, preview.link.prNumber != nil { Badge(text: key) }
                                if let pr = preview.prNumber, preview.link.prNumber == nil { Badge(text: "#\(String(pr))") }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Muted("Track as")
                        Picker("", selection: $kind) {
                            ForEach(TaskKind.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
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
                Button("Add task", action: add)
                    .shadButton(.primary, size: .md)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview == nil)
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

    private func resolve(_ value: String) {
        lookup?.cancel()
        preview = nil
        error = nil
        guard let link = LinkParser.parse(value) else {
            loading = false
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { error = "Not a GitHub PR or Linear link." }
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

    private func add() {
        guard var p = preview else { return }
        p.kind = kind
        if p.kind.isReview != (preview?.kind.isReview ?? false) { p.status = kind.flow[0] }
        let id = model.add(p)
        dismiss()
        onAdded(id)
    }
}
