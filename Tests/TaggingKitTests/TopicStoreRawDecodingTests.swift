import Foundation
import SQLite
import Testing
@testable import TaggingKit

@Suite("TopicStore — Raw Decoding")
struct TopicStoreRawDecodingTests {
    @Test("playlistsForVideo throws a corruption error for malformed rows")
    func malformedPlaylistRowThrows() throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let store = try TopicStore(path: dbURL.path)
        let connection = try Connection(dbURL.path)

        try connection.run("INSERT INTO videos (video_id, title, channel_name, video_url, source_index, topic_id) VALUES ('vid-1', 'Video', 'Channel', NULL, 0, NULL)")
        try connection.run("INSERT INTO playlists (playlist_id, title, visibility, video_count, source, fetched_at) VALUES ('pl-1', 'Playlist', 'public', 'many', 'test', '2026-04-10T00:00:00Z')")
        try connection.run("INSERT INTO playlist_memberships (playlist_id, video_id, position, verified_at) VALUES ('pl-1', 'vid-1', 0, '2026-04-10T00:00:00Z')")

        #expect(throws: TopicStoreError.self) {
            _ = try store.playlistsForVideo(videoId: "vid-1")
        }
    }
}
