import Foundation

/// The sidebar's meeting list: date sections and the search filter (Sidebar/index.tsx).
public enum MeetingList {
    public struct Group: Sendable, Hashable {
        public var title: String
        public var meetings: [Meeting]
    }

    /// Sections in input order (newest first): Today, Yesterday, Previous 7/30 Days, then one per month.
    public static func grouped(_ meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let month = DateFormatter()
        month.calendar = calendar
        month.timeZone = calendar.timeZone
        month.dateFormat = "MMMM yyyy"
        let today = calendar.startOfDay(for: now)
        var groups: [Group] = []
        for meeting in meetings {
            let title: String
            if let date = meeting.createdDate {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
                title = switch days {
                case ...0: "Today"
                case 1: "Yesterday"
                case 2...7: "Previous 7 Days"
                case 8...30: "Previous 30 Days"
                default: month.string(from: date)
                }
            } else {
                title = "Earlier"
            }
            if groups.last?.title == title { groups[groups.count - 1].meetings.append(meeting) }
            else { groups.append(Group(title: title, meetings: [meeting])) }
        }
        return groups
    }

    /// Meetings with a transcript hit, or whose title contains the query (case-insensitive).
    public static func filtered(_ meetings: [Meeting], query: String, matches: [SearchResult]) -> [Meeting] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return meetings }
        let hits = Set(matches.map(\.id))
        return meetings.filter { hits.contains($0.id) || $0.title.localizedCaseInsensitiveContains(query) }
    }
}
