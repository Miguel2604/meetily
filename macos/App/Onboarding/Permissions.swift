import AppKit
import Audio
import AVFoundation
import UserNotifications

/// The three permissions Meety asks for, with live status and the System Settings pane for each.
enum Permission: CaseIterable {
    case microphone, systemAudio, notifications

    enum Status { case granted, denied, notDetermined }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio"
        case .notifications: "Notifications"
        }
    }

    var detail: String {
        switch self {
        case .microphone: "Required to capture your voice during meetings"
        case .systemAudio: "Captures the other side of the call from Zoom, Meet, Teams or any app"
        case .notifications: "Tells you when recording starts and stops, and when a summary is ready"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .systemAudio: "speaker.wave.2"
        case .notifications: "bell"
        }
    }

    private var settingsURL: URL {
        let pane = switch self {
        case .microphone: "com.apple.preference.security?Privacy_Microphone"
        case .systemAudio: "com.apple.preference.security?Privacy_AudioCapture"
        case .notifications: "com.apple.Notifications-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:" + pane)!
    }

    func status() async -> Status {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .systemAudio:
            // No public status API: unknown reads as "not asked yet", and asking again just reruns the tap.
            switch SystemAudioPermission.status {
            case .granted: return .granted
            case .denied: return .denied
            case .unknown: return .notDetermined
            }
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }

    /// Shows the system prompt the first time; after a denial, opens the System Settings pane instead.
    func request() async {
        guard await status() == .notDetermined else {
            NSWorkspace.shared.open(settingsURL)
            return
        }
        switch self {
        case .microphone: _ = await MicrophonePermission.request()
        case .systemAudio: await SystemAudioPermission.request()
        case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }
}
