import Foundation
import SwiftUI
import MiradorCore

/// Command-line tool and Claude Code skill shipped inside the app bundle.
enum Integrations {
    enum Status: Equatable {
        case installed, outdated, missing, blocked(String)
    }

    static let binDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
    static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mirador") }
    static let names = ["mirador"]
    static var bundledSkill: URL? { Bundle.main.url(forResource: "mirador-skill", withExtension: "md") }
    static let skillFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills/mirador/SKILL.md")

    // MARK: CLI

    static var cliStatus: Status {
        let fm = FileManager.default
        var statuses: [Status] = []
        for name in names {
            let link = binDir.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: link) else { statuses.append(.missing); continue }
            guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
                statuses.append(.blocked("~/.local/bin/\(name) is a regular file, not ours"))
                continue
            }
            let target = (try? fm.destinationOfSymbolicLink(atPath: link)) ?? ""
            statuses.append(target == helper.path ? .installed : .outdated)
        }
        if let blocked = statuses.first(where: { if case .blocked = $0 { true } else { false } }) { return blocked }
        if statuses.allSatisfy({ $0 == .installed }) { return .installed }
        return statuses.contains(.missing) && !statuses.contains(.installed) ? .missing : .outdated
    }

    /// Links `mirador` to this app's helper. Only replaces symlinks, never real files.
    static func installCLI() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        for name in names {
            let link = binDir.appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: link.path) {
                guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: helper)
        }
    }

    /// Whether a new terminal finds ~/.local/bin.
    static func binDirOnPath() -> Bool {
        let r = Shell.run("/bin/zsh", ["-ilc", "print -r -- $PATH"])
        return r.stdout.split(separator: ":").contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == binDir.path }
    }

    // MARK: Claude Code skill

    static var skillStatus: Status {
        guard let source = bundledSkill, let bundled = try? String(contentsOf: source, encoding: .utf8) else { return .blocked("not bundled in this build") }
        guard let current = try? String(contentsOf: skillFile, encoding: .utf8) else { return .missing }
        guard current.contains("name: mirador") else { return .blocked("~/.claude/skills/mirador has someone else's skill") }
        return current == bundled ? .installed : .outdated
    }

    static func installSkill() throws {
        guard let source = bundledSkill else { return }
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: source)
        try data.write(to: skillFile, options: .atomic)
    }
}

struct IntegrationsCard: View {
    @State private var cli: Integrations.Status = .missing
    @State private var onPath = true
    @State private var skill: Integrations.Status = .missing
    @State private var error: String?

    var body: some View {
        Card {
            CardHeader(title: "Command line & Claude Code",
                       description: "The `mirador` command lets Claude Code (or your terminal) update tasks, create worktrees, start environments and create the admin. The skill tells Claude when to use it.")
            row(title: "Command-line tool", detail: "~/.local/bin/mirador", status: cli) {
                do { try Integrations.installCLI() } catch { self.error = error.localizedDescription }
                refresh()
            }
            if cli == .installed && !onPath {
                VStack(alignment: .leading, spacing: 4) {
                    Label("~/.local/bin is not on your PATH. Add this line to ~/.zshrc:", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    HStack {
                        Text(#"export PATH="$HOME/.local/bin:$PATH""#).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(#"export PATH="$HOME/.local/bin:$PATH""#, forType: .string)
                        }
                        .shadButton(.ghost)
                    }
                    .padding(8)
                    .background(Theme.muted, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Divider().overlay(Theme.border)
            row(title: "Claude Code skill", detail: "~/.claude/skills/mirador/SKILL.md", status: skill) {
                do { try Integrations.installSkill() } catch { self.error = error.localizedDescription }
                refresh()
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other agents").font(.system(size: 12, weight: .medium))
                    Muted("A prompt that makes any agent run `mirador guide` and follow it.", size: 11)
                }
                Spacer()
                Button("Copy prompt") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentGuide.prompt, forType: .string)
                }
                .shadButton(.outline)
            }
            if let error { Label(error, systemImage: "xmark.octagon").font(.system(size: 11)).foregroundStyle(.red) }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        cli = Integrations.cliStatus
        skill = Integrations.skillStatus
        Task.detached {
            let found = Integrations.binDirOnPath()
            await MainActor.run { onPath = found }
        }
    }

    private func row(title: String, detail: String, status: Integrations.Status, install: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Muted(detail, size: 11)
            }
            Spacer()
            switch status {
            case .installed:
                Badge(text: "Installed", variant: .outline, color: .green)
            case .outdated:
                Button("Update", action: install).shadButton(.primary)
            case .missing:
                Button("Install", action: install).shadButton(.primary)
            case .blocked(let why):
                Badge(text: why, variant: .outline, color: .orange)
            }
        }
    }
}
