import ArgumentParser
import Foundation
import TaggingKit

protocol VideoTaggerYouTubeServing: Sendable {
    func fetchAllVideoMetadata(
        ids: [String],
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [VideoMetadata]

    func fetchChannelDetails(
        channelIds: [String],
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [ChannelRecord]

    func downloadChannelIcon(url: URL) async throws -> Data
}

extension YouTubeClient: VideoTaggerYouTubeServing {}

func makeYouTubeClient(apiKey: String?) throws -> any VideoTaggerYouTubeServing {
    if let apiKey {
        return YouTubeClient(apiKey: apiKey)
    }
    return try YouTubeClient()
}

struct BackfillMetadataSummary {
    let requestedVideoCount: Int
    let updatedVideoCount: Int
    let missingVideoCount: Int
    let channelStubCount: Int
    let quotaUnitsUsed: Int
}

struct EnrichChannelsSummary {
    let backfilledVideoCount: Int
    let updatedChannelCount: Int
    let cachedIconCount: Int
    let quotaUnitsUsed: Int
}

@main
struct VideoTaggerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video-tagger",
        abstract: "Organize YouTube videos into topics using Claude AI.",
        version: "0.2.0",
        subcommands: [Suggest.self, Reclassify.self, ReclassifyAll.self, SubTopics.self, TopicsList.self, Preview.self, SplitTopic.self, MergeTopics.self, RenameTopic.self, DeleteTopic.self, Status.self, BackfillMetadata.self, EnrichChannels.self, GenerateSubtopics.self, ImportPlaylists.self, ImportSeenHistory.self, VerifyPlaylistMembership.self, VerifyAllPlaylistMemberships.self, SyncPendingActions.self, BrowserSyncLogin.self, BrowserStatus.self, OAuthStatus.self, OAuthAuthURL.self, OAuthExchange.self, OAuthRefresh.self]
    )
}
