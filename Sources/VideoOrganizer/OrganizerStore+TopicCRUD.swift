// OrganizerStore+TopicCRUD.swift
//
// Topic lifecycle operations: rename, delete, merge, move videos,
// and AI-driven topic splitting. Extracted from the root
// OrganizerStore to keep the facade focused on state + caching.

import Foundation
import TaggingKit

extension OrganizerStore {

    // MARK: - Topic CRUD

    func renameTopic(_ topicId: Int64, to newName: String) {
        do {
            try store.renameTopic(id: topicId, to: newName)
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTopic(_ topicId: Int64) {
        do {
            try store.deleteTopic(id: topicId)
            if selectedTopicId == topicId { selectedTopicId = nil }
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func mergeTopics(sourceId: Int64, intoId: Int64) {
        do {
            try store.mergeTopic(sourceId: sourceId, intoId: intoId)
            if selectedTopicId == sourceId { selectedTopicId = intoId }
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveVideo(videoId: String, toTopicId: Int64) {
        do {
            try store.assignVideo(videoId: videoId, toTopic: toTopicId)
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveVideos(videoIds: Set<String>, toTopicId: Int64) {
        do {
            for vid in videoIds {
                try store.assignVideo(videoId: vid, toTopic: toTopicId)
            }
            selectedVideoId = nil
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - AI Operations

    func splitTopic(_ topicId: Int64, into count: Int = 3) async {
        guard let suggester else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let videos = try store.videosForTopic(id: topicId)
            let topic = topics.first { $0.id == topicId }
            let videoItems = videos.map { v in
                VideoItem(sourceIndex: v.sourceIndex, title: v.title, videoUrl: v.videoUrl,
                          videoId: v.videoId, channelName: v.channelName, metadataText: nil, unavailableKind: "none")
            }

            let subTopics = try await suggester.splitTopic(
                topicName: topic?.name ?? "",
                videos: videoItems,
                videoIndices: videos.map(\.sourceIndex),
                targetSubTopics: count
            )

            try store.deleteTopic(id: topicId)
            for sub in subTopics {
                let newId = try store.createTopic(name: sub.name)
                try store.assignVideos(indices: sub.videoIndices, toTopic: newId)
            }

            selectedTopicId = nil
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
