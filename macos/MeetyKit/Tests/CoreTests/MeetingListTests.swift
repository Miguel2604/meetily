import Foundation
import Testing
@testable import Core

@Suite struct MeetingListTests {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    let now = Timestamp.parse("2026-11-04T15:00:00+00:00")!

    func meeting(_ id: String, _ created: String, title: String? = nil) -> Meeting {
        Meeting(id: id, title: title ?? id, createdAt: created, updatedAt: created, folderPath: nil)
    }

    @Test func `groups by relative day, then by month, keeping order`() {
        let meetings = [
            meeting("a", "2026-11-04T09:00:00.000000+00:00"),
            meeting("b", "2026-11-03T22:00:00.000000+00:00"),
            meeting("c", "2026-10-30T10:00:00+00:00"),
            meeting("d", "2026-10-10T10:00:00+00:00"),
            meeting("e", "2026-09-02T10:00:00+00:00"),
            meeting("f", "2025-09-01 10:00:00"),
            meeting("g", "garbage"),
        ]
        let groups = MeetingList.grouped(meetings, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "September 2026", "September 2025", "Earlier"])
        #expect(groups.map { $0.meetings.map(\.id) } == [["a"], ["b"], ["c"], ["d"], ["e"], ["f"], ["g"]])
    }

    @Test func `search keeps transcript hits and title matches`() {
        let meetings = [meeting("a", "x", title: "Standup"), meeting("b", "x", title: "Design review"), meeting("c", "x", title: "1:1")]
        let hits = [SearchResult(id: "c", title: "1:1", matchContext: "…budget…", timestamp: "x")]
        #expect(MeetingList.filtered(meetings, query: "", matches: []).map(\.id) == ["a", "b", "c"])
        #expect(MeetingList.filtered(meetings, query: "REVIEW", matches: []).map(\.id) == ["b"])
        #expect(MeetingList.filtered(meetings, query: "budget", matches: hits).map(\.id) == ["c"])
    }
}
