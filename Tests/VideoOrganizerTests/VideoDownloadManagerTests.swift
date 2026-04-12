import Foundation
import Testing
@testable import VideoOrganizer

@Suite("VideoDownloadManager")
struct VideoDownloadManagerTests {
    @Test("parseProgress extracts bounded percentages from yt-dlp output")
    func parseProgressFromYtDlpOutput() {
        #expect(VideoDownloadManager.parseProgress("[download]  45.2% of ~12.34MiB at 1.23MiB/s ETA 00:08") == 0.452)
        #expect(VideoDownloadManager.parseProgress("100%") == 1.0)
        #expect(VideoDownloadManager.parseProgress("[download] destination: file.mp4") == nil)
        #expect(VideoDownloadManager.parseProgress("101.5%") == nil)
    }
}
