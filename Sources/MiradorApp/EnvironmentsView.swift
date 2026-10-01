import SwiftUI
import MiradorCore

struct EnvironmentsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environments").font(.system(size: 20, weight: .semibold))
                    Muted("Monorepo on :\(String(model.settings.monorepoPort)) and one worktree on :\(String(model.settings.worktreePort)) can run side by side. Starting a worktree stops the other worktree only.")
                }
                .padding(.bottom, 4)
                ForEach(sorted) { wt in
                    Card {
                        HStack(alignment: .firstTextBaseline) {
                            Text(wt.name).font(.system(size: 14, weight: .semibold))
                            if let branch = wt.branch { Badge(text: branch, variant: .secondary, mono: true) }
                            Spacer()
                            if !wt.isInstalled { Badge(text: "not installed", variant: .outline, color: .orange) }
                        }
                        let tasks = model.tasks(for: wt)
                        if !tasks.isEmpty {
                            VStack(spacing: 6) {
                                ForEach(tasks) { task in
                                    HStack(spacing: 8) {
                                        StatusBadge(status: task.status)
                                        Text(task.title).font(.system(size: 12)).lineLimit(1)
                                        Spacer()
                                        LinkButtons(task: task, compact: true)
                                    }
                                }
                            }
                        }
                        HStack {
                            WorktreeActions(path: wt.path)
                            Spacer()
                            Button { model.copy(wt.path) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(ShadButtonStyle(variant: .ghost, size: .icon))
                                .help("Copy path")
                        }
                        Divider().overlay(Theme.border)
                        EnvironmentControls(path: wt.path)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .onAppear { model.refreshWorktrees() }
    }

    private var sorted: [Worktree] {
        model.worktrees.sorted { a, b in
            let ra = model.state(of: a.path) != .stopped, rb = model.state(of: b.path) != .stopped
            if ra != rb { return ra }
            return a.name < b.name
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var status: String?
    @State private var testing = false
    @State private var paths = AppSettings()
    @State private var pathsSaved = false
    @State private var workspace = ""
    @State private var teamKeys = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                linearCard
                AdminSettingsCard()
                pathsCard
                IntegrationsCard()
                UpdatesCard()
                githubCard
            }
            .padding(20)
        }
        .frame(width: 520, height: 620)
        .background(Theme.background)
        .onAppear {
            paths = model.settings
            workspace = model.settings.linearWorkspace
            teamKeys = model.settings.linearTeamKeys
        }
    }

    // MARK: Linear

    private var linearCard: some View {
        Card {
            CardHeader(title: "Linear", description: "Personal API key: Linear → Settings → Security & access → Personal API keys. Stored in the macOS Keychain.") {
                if model.hasLinearKey {
                    Badge(text: model.linearAuthFailed ? "Not working" : "Connected", variant: .outline, color: model.linearAuthFailed ? .red : .green)
                }
            }
            if model.linearAuthFailed {
                Label("Linear rejected the saved key (expired or revoked). Paste a new one below.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            SecureField(model.hasLinearKey ? "Paste a new key to replace the saved one" : "lin_api_…", text: $key)
                .textFieldStyle(ShadTextFieldStyle())
                .onSubmit(save)
            HStack {
                if let status { Muted(status) }
                Spacer()
                Button("Create a key") { model.open(URL(string: "https://linear.app/settings/account/security")) }
                    .shadButton(.ghost)
                if model.hasLinearKey {
                    Button("Remove") {
                        model.setLinearKey(nil)
                        status = "Removed."
                    }
                    .shadButton(.ghost)
                }
                Button(action: save) {
                    if testing { ProgressView().controlSize(.small) } else { Text("Save & test") }
                }
                .shadButton(.primary)
                .disabled(key.isEmpty || testing)
            }
            Divider().overlay(Theme.border)
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace").font(.system(size: 12, weight: .medium))
                    TextField("strapi", text: $workspace).textFieldStyle(ShadTextFieldStyle())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Team keys").font(.system(size: 12, weight: .medium))
                    TextField("CMS", text: $teamKeys).textFieldStyle(ShadTextFieldStyle())
                }
                Button("Save") {
                    var s = model.settings
                    s.linearWorkspace = workspace.trimmingCharacters(in: .whitespaces)
                    s.linearTeamKeys = teamKeys.trimmingCharacters(in: .whitespaces)
                    model.saveSettings(s)
                }
                .shadButton(.outline, size: .md)
                .disabled(workspace == model.settings.linearWorkspace && teamKeys == model.settings.linearTeamKeys)
            }
            Muted("Ticket links open linear.app/<workspace>. Team keys (comma separated) are found in branch names and titles, e.g. fix/cms-123-….", size: 11)
        }
    }

    private func save() {
        guard !key.isEmpty else { return }
        testing = true
        status = nil
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached {
            let result = Result { try LinearAPI.fetch(key: candidate) }
            await MainActor.run {
                testing = false
                switch result {
                case .success(let snap):
                    model.setLinearKey(candidate)
                    key = ""
                    status = "Connected as \(snap.viewerName) · \(snap.assigned.count) open tickets."
                case .failure(let error):
                    status = error.localizedDescription
                }
            }
        }
    }

    // MARK: Paths

    private var pathsCard: some View {
        Card {
            CardHeader(title: "Folders & ports", description: "Where the Strapi monorepo and its worktrees live, which app Quickstart runs, and on which ports.")
            PathSetting(label: "Monorepo", help: "Main strapi/strapi checkout. Also started from Quickstart as “Monorepo”.",
                        value: $paths.repoPath, isDirectory: true)
            PathSetting(label: "Worktrees folder", help: "Checkouts in this folder are picked up even if git does not list them.",
                        value: $paths.worktreesPath, isDirectory: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Quickstart app").font(.system(size: 12, weight: .medium))
                TextField("examples/getstarted", text: $paths.appDirectory).textFieldStyle(ShadTextFieldStyle())
                Muted("Relative to each checkout. Quickstart runs yarn develop --watch-admin there.", size: 11)
            }
            HStack(alignment: .top, spacing: 12) {
                PortSetting(label: "Monorepo port", help: "Run the current code here…", value: $paths.monorepoPort)
                PortSetting(label: "Worktree port", help: "…and the PR being tested here, side by side.", value: $paths.worktreePort)
            }
            if paths.monorepoPort == paths.worktreePort {
                Label("Use two different ports, or the monorepo and a worktree cannot run together.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                if pathsSaved { Muted("Saved.") }
                Spacer()
                Button("Reset") {
                    let d = AppSettings()
                    paths.repoPath = d.repoPath
                    paths.worktreesPath = d.worktreesPath
                    paths.appDirectory = d.appDirectory
                    paths.monorepoPort = d.monorepoPort
                    paths.worktreePort = d.worktreePort
                }
                .shadButton(.ghost)
                Button("Save") {
                    var merged = model.settings
                    merged.repoPath = paths.repoPath
                    merged.worktreesPath = paths.worktreesPath
                    merged.appDirectory = paths.appDirectory
                    merged.monorepoPort = paths.monorepoPort
                    merged.worktreePort = paths.worktreePort
                    model.saveSettings(merged)
                    paths = merged
                    pathsSaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pathsSaved = false }
                }
                .shadButton(.primary)
                .disabled(!pathsChanged || !validPorts)
            }
        }
    }

    private var pathsChanged: Bool {
        let m = model.settings
        return paths.repoPath != m.repoPath || paths.worktreesPath != m.worktreesPath || paths.appDirectory != m.appDirectory
            || paths.monorepoPort != m.monorepoPort || paths.worktreePort != m.worktreePort
    }

    private var validPorts: Bool {
        let range = 1024...65535
        return range.contains(paths.monorepoPort) && range.contains(paths.worktreePort) && paths.monorepoPort != paths.worktreePort
    }

    private var githubCard: some View {
        Card {
            CardHeader(title: "GitHub", description: "Uses your gh login. Syncs every minute.")
            HStack {
                Muted(model.lastSync.map { "Last sync \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet")
                Spacer()
                Button("Sync now") { model.sync() }.shadButton(.outline)
            }
        }
    }
}

struct PathSetting: View {
    let label: String
    let help: String
    @Binding var value: String
    var isDirectory = true

    private var exists: Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: (value as NSString).expandingTildeInPath, isDirectory: &dir) && dir.boolValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                if !exists { Badge(text: "not found", variant: .outline, color: .red) }
            }
            HStack(spacing: 6) {
                TextField("", text: $value).textFieldStyle(ShadTextFieldStyle())
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                    if panel.runModal() == .OK, let url = panel.url { value = url.path }
                }
                .shadButton(.outline, size: .md)
            }
            Muted(help, size: 11)
        }
    }
}

struct PortSetting: View {
    let label: String
    let help: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField("", value: $value, format: .number.grouping(.never))
                .textFieldStyle(ShadTextFieldStyle())
                .frame(width: 120)
            Muted(help, size: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Super admin created automatically on a fresh checkout's first start.
struct AdminSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = false
    @State private var firstname = ""
    @State private var lastname = ""
    @State private var email = ""
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var saved = false

    var body: some View {
        Card {
            CardHeader(title: "Local super admin",
                       description: "Created on the first start of any checkout that has no admin yet, so you land on the login page instead of the welcome form. The password is stored in the Keychain.") {
                Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
            }
            if enabled {
                HStack(spacing: 8) {
                    TextField("First name", text: $firstname).textFieldStyle(ShadTextFieldStyle())
                    TextField("Last name", text: $lastname).textFieldStyle(ShadTextFieldStyle())
                }
                TextField("Email", text: $email).textFieldStyle(ShadTextFieldStyle())
                SecureField(hasSavedPassword ? "Password saved — type to replace" : "Password", text: $password)
                    .textFieldStyle(ShadTextFieldStyle())
                if let problem = password.isEmpty ? nil : AdminBootstrap.passwordProblem(password) {
                    Label(problem, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
                } else {
                    Muted("Strapi requires 8+ characters with a lowercase, an uppercase and a number.", size: 11)
                }
            }
            HStack {
                if saved { Muted("Saved.") }
                Spacer()
                Button("Save", action: save)
                    .shadButton(.primary)
                    .disabled(!canSave)
            }
        }
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        guard enabled else { return model.settings.autoCreateAdmin }
        let emailOK = email.contains("@") && email.contains(".")
        let passwordOK = password.isEmpty ? hasSavedPassword : AdminBootstrap.passwordProblem(password) == nil
        return emailOK && passwordOK
    }

    private func load() {
        let s = model.settings
        enabled = s.autoCreateAdmin
        firstname = s.adminFirstname
        lastname = s.adminLastname
        email = s.adminEmail
        Task.detached {
            let exists = Keychain.read(AdminBootstrap.passwordAccount) != nil
            await MainActor.run { hasSavedPassword = exists }
        }
    }

    private func save() {
        var s = model.settings
        s.autoCreateAdmin = enabled
        s.adminFirstname = firstname.trimmingCharacters(in: .whitespaces)
        s.adminLastname = lastname.trimmingCharacters(in: .whitespaces)
        s.adminEmail = email.trimmingCharacters(in: .whitespaces)
        if !password.isEmpty {
            model.saveAdminPassword(password)
            hasSavedPassword = true
            password = ""
        }
        model.saveSettings(s)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
