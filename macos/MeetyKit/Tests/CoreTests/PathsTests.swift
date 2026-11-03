import Foundation
import Testing
@testable import Core

@Test func `app data lives under the Tauri bundle id`() {
    #expect(Paths.appSupport.lastPathComponent == "com.meetily.ai")
    #expect(Paths.database.lastPathComponent == "meeting_minutes.sqlite")
}
