import Foundation

enum GridSectionLogic {
    static func sortVideos(_ videos: [VideoGridItemModel], by order: SortOrder, ascending: Bool) -> [VideoGridItemModel] {
        if order == .shuffle { return videos.shuffled() }
        return videos.sorted { a, b in
            let result: Bool
            switch order {
            case .views:
                result = parseViewCount(a.viewCount) > parseViewCount(b.viewCount)
            case .date:
                result = parseAge(a.publishedAt) < parseAge(b.publishedAt)
            case .duration:
                result = parseDuration(a.duration) > parseDuration(b.duration)
            case .creator:
                let aName = a.channelName ?? ""
                let bName = b.channelName ?? ""
                if aName == bName {
                    result = parseAge(a.publishedAt) < parseAge(b.publishedAt)
                } else {
                    result = aName.localizedStandardCompare(bName) == .orderedAscending
                }
            case .alphabetical:
                result = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .shuffle:
                result = false
            }
            return ascending ? !result : result
        }
    }

    static func groupByCreator(
        section: TopicSection,
        ascending: Bool,
        channelCounts: [String: Int],
        includeTopicMarker: Bool
    ) -> [TopicSection] {
        var channelOrder: [String] = []
        var channelMap: [String: [VideoGridItemModel]] = [:]

        for video in section.videos {
            let name = video.channelName ?? "Unknown"
            if channelMap[name] == nil {
                channelOrder.append(name)
            }
            channelMap[name, default: []].append(video)
        }

        var grouped = channelOrder.compactMap { name -> (name: String, videos: [VideoGridItemModel])? in
            guard let videos = channelMap[name] else { return nil }
            return (name: name, videos: videos)
        }

        grouped.sort { a, b in
            ascending ? a.videos.count < b.videos.count : a.videos.count > b.videos.count
        }

        let creatorSections = grouped.map { group in
            let sorted = group.videos.sorted { a, b in
                parseAge(a.publishedAt) < parseAge(b.publishedAt)
            }
            let iconURL = sorted.first(where: { $0.channelIconUrl != nil })?.channelIconUrl
            return TopicSection(
                topicId: section.topicId,
                topicName: section.topicName,
                videos: sorted,
                totalCount: channelCounts[group.name],
                videoSubtopicMap: section.videoSubtopicMap,
                displayMode: section.displayMode,
                creatorName: group.name,
                channelIconUrl: iconURL,
                topicNames: [section.topicName]
            )
        }

        guard includeTopicMarker else {
            return creatorSections
        }

        let marker = TopicSection(
            topicId: section.topicId,
            topicName: section.topicName,
            videos: [],
            totalCount: section.totalCount,
            headerCountOverride: section.videos.count,
            videoSubtopicMap: section.videoSubtopicMap,
            displayMode: section.displayMode
        )
        return [marker] + creatorSections
    }

    static func parseViewCount(_ str: String?) -> Int {
        guard let str else { return 0 }
        let cleaned = str.replacingOccurrences(of: " views", with: "")
        if cleaned.hasSuffix("M") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000_000)
        }
        if cleaned.hasSuffix("K") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000)
        }
        return Int(cleaned) ?? 0
    }

    static func parseAge(_ str: String?) -> Int {
        guard let str else { return .max }
        if str == "today" { return 0 }
        let parts = str.split(separator: " ")
        guard parts.count >= 2, let num = Int(parts[0]) else { return .max }
        let unit = String(parts[1])
        if unit.hasPrefix("day") { return num }
        if unit.hasPrefix("month") { return num * 30 }
        if unit.hasPrefix("year") { return num * 365 }
        return .max
    }

    static func parseDuration(_ str: String?) -> Int {
        guard let str else { return 0 }
        let parts = str.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2:
            return parts[0] * 60 + parts[1]
        case 1:
            return parts[0]
        default:
            return 0
        }
    }
}
