import Foundation

extension OrganizerStore {
    func creatorDetail(channelName: String) -> CreatorDetailViewModel {
        CreatorAnalytics.makeCreatorDetail(for: channelName, in: self)
    }
}

enum CreatorAnalytics {
    @MainActor
    static func makeCreatorDetail(for channelName: String, in store: OrganizerStore) -> CreatorDetailViewModel {
        var videosByTopic: [(topicName: String, videos: [VideoViewModel])] = []
        var totalViews = 0
        var oldestDays = 0
        var newestDays = Int.max
        var recentCount = 0

        for topic in store.topics {
            let videos = store.videosForTopicIncludingSubtopics(topic.id).filter { $0.channelName == channelName }
            if !videos.isEmpty {
                videosByTopic.append((topicName: topic.name, videos: videos))
                for video in videos {
                    if let viewCount = video.viewCount {
                        totalViews += parseViewCount(viewCount)
                    }
                    if let publishedAt = video.publishedAt {
                        let days = parseAge(publishedAt)
                        oldestDays = max(oldestDays, days)
                        newestDays = min(newestDays, days)
                        if days <= 30 {
                            recentCount += 1
                        }
                    }
                }
            }
        }

        let channelIconURL = videosByTopic.flatMap(\.videos).first(where: { $0.channelIconUrl != nil })?.channelIconUrl
        let totalCount = videosByTopic.reduce(0) { $0 + $1.videos.count }
        let channelId = videosByTopic.flatMap(\.videos).first(where: { $0.channelId != nil })?.channelId
        let channelRecord = channelId.flatMap { channelId in
            store.topicChannels.values.flatMap { $0 }.first(where: { $0.channelId == channelId })
        }

        return CreatorDetailViewModel(
            channelName: channelName,
            channelIconUrl: channelIconURL,
            channelIconData: channelRecord?.iconData,
            totalVideoCount: totalCount,
            totalViews: totalViews,
            newestAge: newestDays == Int.max ? nil : formatAge(newestDays),
            oldestAge: oldestDays == 0 ? nil : formatAge(oldestDays),
            recentCount: recentCount,
            subscriberCount: channelRecord?.subscriberCount.flatMap(Int.init),
            totalUploads: channelRecord?.videoCountTotal,
            videosByTopic: videosByTopic
        )
    }

    static func parseViewCount(_ string: String) -> Int {
        let cleaned = string.replacingOccurrences(of: " views", with: "")
        if cleaned.hasSuffix("M") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000_000)
        }
        if cleaned.hasSuffix("K") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000)
        }
        return Int(cleaned) ?? 0
    }

    static func parseAge(_ string: String) -> Int {
        if string == "today" {
            return 0
        }
        let parts = string.split(separator: " ")
        guard parts.count >= 2, let number = Int(parts[0]) else {
            return .max
        }
        let unit = String(parts[1])
        if unit.hasPrefix("day") {
            return number
        }
        if unit.hasPrefix("month") {
            return number * 30
        }
        if unit.hasPrefix("year") {
            return number * 365
        }
        return .max
    }

    static func formatAge(_ days: Int) -> String {
        if days == 0 { return "today" }
        if days == 1 { return "1 day ago" }
        if days < 30 { return "\(days) days ago" }
        let months = days / 30
        if months == 1 { return "1 month ago" }
        if months < 12 { return "\(months) months ago" }
        let years = months / 12
        if years == 1 { return "1 year ago" }
        return "\(years) years ago"
    }

    static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
