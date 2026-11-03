import AppKit
import Core
import Observation

/// App-wide state the windows observe: the store, preferences, the meetings list and the content route.
@Observable
final class AppModel {
    enum Route: Hashable { case home, meeting(String) }

    let store: Store
    let settings: Settings
    private(set) var meetings: [Meeting] = []
    var route: Route = .home

    init(store: Store, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    func reloadMeetings() async {
        do { meetings = try await store.meetings() } catch { present(error) }
    }

    func rename(_ id: String, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do { _ = try await store.renameMeeting(id: id, title: title) } catch { present(error) }
        await reloadMeetings()
    }

    /// Removes the meeting from the database; its recording folder stays on disk, as in the Tauri app.
    func delete(_ id: String) async {
        do { _ = try await store.deleteMeeting(id: id) } catch { present(error) }
        if route == .meeting(id) { route = .home }
        await reloadMeetings()
    }

    func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = NSApp.mainWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// Runs `body` now and again after any observed property it read changes (Observation without SwiftUI).
func track(_ body: @escaping @MainActor () -> Void) {
    withObservationTracking(body) { Task { @MainActor in track(body) } }
}
