import AuthenticationServices
import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let palDeviceToken = Notification.Name("PalDeviceToken")
    static let palDeviceError = Notification.Name("PalDeviceRegistrationError")
    static let palNotificationRoute = Notification.Name("PalNotificationRoute")
}

final class PalAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "PalDeviceToken")
        NotificationCenter.default.post(name: .palDeviceToken, object: token)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .palDeviceError, object: error.localizedDescription)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let payload = response.notification.request.content.userInfo
        UserDefaults.standard.set(payload, forKey: "PalPendingNotification")
        NotificationCenter.default.post(name: .palNotificationRoute, object: payload)
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(PalNotifications.presentationOptions(for: UIApplication.shared.applicationState))
    }
}

enum PalNotifications {
    @MainActor static func presentationOptions(for state: UIApplication.State) -> UNNotificationPresentationOptions {
        state == .active ? [] : [.banner, .sound, .badge]
    }
    @MainActor static func registerIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        UserDefaults.standard.set(settings.authorizationStatus.rawValue, forKey: "PalNotificationAuthorization")
        if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    @MainActor static func enable() async throws -> Bool {
        let enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await registerIfAuthorized()
        return enabled
    }
}

@MainActor final class GoogleCalendarLink: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func connect(store: PalStore) async throws {
        let url = try await store.calendarConnectURL()
        guard url.scheme == "https" else { throw PalFailure(message: "Google Calendar returned an invalid sign-in link.") }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            session = ASWebAuthenticationSession(url: url, callbackURLScheme: "pal") { url, error in
                if let error { continuation.resume(throwing: (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? CancellationError() : error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: PalFailure(message: "Google Calendar did not connect.")) }
            }
            session?.presentationContextProvider = self
            if session?.start() != true {
                continuation.resume(throwing: PalFailure(message: "Unable to open Google sign-in."))
                session = nil
            }
        }
        session = nil
        store.handleURL(callback)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
