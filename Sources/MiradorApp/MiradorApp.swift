import AppKit
import SwiftUI
import MiradorCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Updates.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let raw = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: raw) {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }
}

@main
struct MiradorApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Mirador", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkNow() }
                    .disabled(!Updates.shared.isAvailable)
            }
            CommandGroup(after: .appSettings) {
                Button("Set Up Mirador…") {
                    NSApp.activate(ignoringOtherApps: true)
                    model.showingOnboarding = true
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Task…") { model.showAdd() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Sync") { model.sync() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let count = model.tasks.filter { !$0.archived && !$0.status.isFinished && $0.needsMe }.count
        HStack(spacing: 3) {
            Text("🔭")
            if !model.running.isEmpty { Image(systemName: "bolt.fill") }
            if !model.unreadPings.isEmpty { Image(systemName: "bell.badge.fill") }
            if count > 0 { Text("\(count)") }
        }
    }
}
