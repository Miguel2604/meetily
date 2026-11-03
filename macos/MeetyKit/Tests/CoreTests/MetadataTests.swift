import Foundation
import Testing
@testable import Core

@Suite struct MetadataTests {
    @Test func `the per-meeting summary language round-trips and keeps the other fields`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "meety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(MeetingMetadata.summaryLanguage(in: folder) == nil) // no metadata.json yet
        try MeetingMetadata.update(in: folder) { _ in ["meeting_name": "Standup", "summary_language": "  "] }
        #expect(MeetingMetadata.summaryLanguage(in: folder) == nil) // blank is unset
        try MeetingMetadata.setSummaryLanguage("tl", in: folder)
        #expect(MeetingMetadata.summaryLanguage(in: folder) == "tl")
        #expect(MeetingMetadata.read(in: folder)?["meeting_name"] as? String == "Standup")
        try MeetingMetadata.setSummaryLanguage(nil, in: folder)
        #expect(MeetingMetadata.read(in: folder)?["summary_language"] == nil)
    }
}
