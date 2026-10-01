import SwiftUI
import MiradorCore

/// First-launch checklist, also under Mirador → Set Up Mirador…
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @AppStorage("onboardingDone") private var done = false

    @State private var githubOK: Bool?
    @State private var cli: Integrations.Status = .missing
    @State private var skill: Integrations.Status = .missing
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("🔭").font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up Mirador").font(.system(size: 18, weight: .semibold))
                    Muted("A few steps so GitHub, Linear and your AI agents keep your tasks up to date.")
                }
            }

            VStack(spacing: 0) {
                step(1, "GitHub", githubOK == nil ? "Checking `gh auth status`…" : githubOK! ? "Signed in\(model.me.map { " as @\($0)" } ?? "") with the gh CLI." : "Run `gh auth login` in a terminal, then Check again.",
                     ok: githubOK == true) {
                    Button("Check again", action: checkGitHub).shadButton(.outline)
                }
                divider
                step(2, "Linear (optional)", !model.linearKeyLoaded ? "Checking the saved key… (macOS may ask for Keychain access)"
                     : model.hasLinearKey && !model.linearAuthFailed ? "Connected." : "Add a personal API key to sync tickets, priorities and mentions.",
                     ok: model.hasLinearKey && !model.linearAuthFailed) {
                    Button("Open Settings") { openSettings() }.shadButton(.outline)
                }
                divider
                step(3, "Folders & ports", folderText, ok: repoExists) {
                    Button("Open Settings") { openSettings() }.shadButton(.outline)
                }
                divider
                step(4, "Command-line tool", "`mirador` in ~/.local/bin, so agents (and you) can update tasks from a terminal.", ok: cli == .installed) {
                    if cli != .installed {
                        Button("Install") { try? Integrations.installCLI(); refresh() }.shadButton(.primary)
                    }
                }
                divider
                step(5, "Claude Code skill", "Tells Claude Code when to run `mirador`. Installed in ~/.claude/skills/mirador.", ok: skill == .installed) {
                    if skill != .installed {
                        Button(skill == .outdated ? "Update" : "Install") { try? Integrations.installSkill(); refresh() }.shadButton(.primary)
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius + 2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).strokeBorder(Theme.border))

            Card(padding: 14) {
                CardHeader(title: "Other agents or sessions", description: "Paste this into any agent that does not have the skill (or to refresh a running session).") {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgentGuide.prompt, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .shadButton(.outline)
                }
                Text(AgentGuide.prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedForeground)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.muted, in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Done") {
                    done = true
                    dismiss()
                }
                .shadButton(.primary, size: .md)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600)
        .background(Theme.background)
        .onAppear {
            refresh()
            checkGitHub()
        }
    }

    private var divider: some View { Divider().overlay(Theme.border) }

    private var repoExists: Bool {
        FileManager.default.fileExists(atPath: (model.settings.repoPath as NSString).expandingTildeInPath + "/.git")
    }

    private var folderText: String {
        let repo = (model.settings.repoPath as NSString).abbreviatingWithTildeInPath
        return repoExists
            ? "Monorepo \(repo) on :\(model.settings.monorepoPort), worktrees on :\(model.settings.worktreePort)."
            : "\(repo) is not a git checkout — set the monorepo folder in Settings."
    }

    private func refresh() {
        cli = Integrations.cliStatus
        skill = Integrations.skillStatus
    }

    private func checkGitHub() {
        githubOK = nil
        Task.detached {
            let ok = Shell.run("gh", ["auth", "status"]).status == 0
            await MainActor.run { githubOK = ok }
        }
    }

    private func step<Action: View>(_ n: Int, _ title: String, _ detail: String, ok: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(ok ? Color.green.opacity(0.18) : Theme.muted).frame(width: 26, height: 26)
                if ok {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(n)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedForeground)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(.init(detail)).font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
            }
            Spacer()
            action()
        }
        .padding(12)
    }
}
