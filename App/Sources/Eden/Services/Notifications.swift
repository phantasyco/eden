import AppKit
import UserNotifications

/// Tells you when a session finishes, fails, or needs you, as a regular macOS
/// notification: Focus and notification settings decide how loud it is.
/// Nothing is posted about the session you're looking at in the front window.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Opens the session a clicked notification is about.
    var open: ((UUID) -> Void)?

    /// Only a bundled app can post; a bare `swift run` binary has no bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Preferences.notifications) as? Bool ?? true
    }

    func start() {
        center?.delegate = self
    }

    /// Asked the first time you start a session, when the reason is plain.
    func requestPermission() {
        guard isEnabled, let center else { return }
        Task {
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    enum Event {
        case finished, failed(String), needsYou(String)
    }

    func post(_ event: Event, for thread: AgentThread, isVisible: Bool) {
        guard isEnabled, let center, !(isVisible && NSApp.isActive) else { return }
        let content = UNMutableNotificationContent()
        content.title = thread.title
        switch event {
        case .finished:
            content.body = thread.repo.isScratch ? "\(thread.modelName) finished." : "\(thread.modelName) finished in \(thread.repo.name)."
        case .failed(let message):
            content.body = "\(thread.modelName) stopped with an error: \(message.prefix(160))"
        case .needsYou(let what):
            content.body = what
        }
        content.sound = .default
        content.threadIdentifier = thread.id.uuidString
        content.userInfo = ["thread": thread.id.uuidString]
        // One notification per session: a new one replaces the last.
        center.add(UNNotificationRequest(identifier: thread.id.uuidString, content: content, trigger: nil))
    }

    /// Clears a session's notification once you've looked at it.
    func clear(_ thread: AgentThread) {
        center?.removeDeliveredNotifications(withIdentifiers: [thread.id.uuidString])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["thread"] as? String,
              let id = UUID(uuidString: raw)
        else { return }
        await MainActor.run {
            NSApp.activate()
            open?(id)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
