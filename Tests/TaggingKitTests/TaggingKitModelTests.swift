import Foundation
import Testing
@testable import TaggingKit

@Suite("TaggingKit Models")
struct TaggingKitModelTests {
    @Test("ChannelRecord id mirrors channelId")
    func channelRecordId() {
        let record = ChannelRecord(channelId: "chan-1", name: "Alpha", iconData: Data([1, 2]))
        #expect(record.id == "chan-1")
        #expect(record.iconData == Data([1, 2]))
    }

    @Test("PlaylistRecord and membership keep identifiers")
    func playlistModels() {
        let playlist = PlaylistRecord(playlistId: "pl-1", title: "Watch Later", videoCount: 12)
        let membership = PlaylistMembershipRecord(playlistId: "pl-1", videoId: "vid-1", position: 3)

        #expect(playlist.id == "pl-1")
        #expect(playlist.videoCount == 12)
        #expect(membership.playlistId == "pl-1")
        #expect(membership.videoId == "vid-1")
        #expect(membership.position == 3)
    }

    @Test("TopicCandidate id combines topic and video IDs")
    func topicCandidateId() {
        let candidate = TopicCandidate(
            topicId: 42,
            videoId: "vid-9",
            title: "Interesting Video",
            channelId: "chan-1",
            score: 0.9,
            reason: "Recent channel upload"
        )
        let source = CandidateSourceRecord(topicId: 42, videoId: "vid-9", sourceKind: "recent", sourceRef: "chan-1")

        #expect(candidate.id == "42-vid-9")
        #expect(candidate.state == CandidateState.candidate.rawValue)
        #expect(source.sourceKind == "recent")
        #expect(source.sourceRef == "chan-1")
    }

    @Test("findLatestInventory returns latest run containing inventory")
    func latestInventoryPrefersNewestRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let olderRun = root.appendingPathComponent("2026-04-01T10-00-00Z")
        let newerRun = root.appendingPathComponent("2026-04-03T10-00-00Z")
        let ignoredRun = root.appendingPathComponent("2026-04-04T10-00-00Z")

        try FileManager.default.createDirectory(at: olderRun, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newerRun, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignoredRun, withIntermediateDirectories: true)

        try "{}".write(to: olderRun.appendingPathComponent("inventory.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: newerRun.appendingPathComponent("inventory.json"), atomically: true, encoding: .utf8)

        let latest = try InventoryLoader.findLatestInventory(in: root)
        #expect(latest?.standardizedFileURL.path == newerRun.appendingPathComponent("inventory.json").standardizedFileURL.path)
    }
}
