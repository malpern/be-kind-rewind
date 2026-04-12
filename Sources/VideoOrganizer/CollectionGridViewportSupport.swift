import AppKit
import Foundation

@MainActor
enum CollectionGridViewportSupport {
    static func frameForSection(
        collectionView: NSCollectionView?,
        sectionIndex: Int
    ) -> CGRect? {
        guard let collectionView else { return nil }

        let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
        var sectionFrame = collectionView.collectionViewLayout?.layoutAttributesForSupplementaryView(
            ofKind: NSCollectionView.elementKindSectionHeader,
            at: headerIndexPath
        )?.frame

        let itemCount = collectionView.numberOfItems(inSection: sectionIndex)
        if itemCount > 0,
           let firstItemFrame = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: sectionIndex))?.frame,
           let lastItemFrame = collectionView.layoutAttributesForItem(at: IndexPath(item: itemCount - 1, section: sectionIndex))?.frame {
            let itemsFrame = firstItemFrame.union(lastItemFrame)
            sectionFrame = sectionFrame.map { $0.union(itemsFrame) } ?? itemsFrame
        }

        return sectionFrame
    }

    static func topicScrollProgress(
        collectionView: NSCollectionView?,
        renderedSections: [TopicSection],
        topicId: Int64,
        frameForSection: (Int) -> CGRect?
    ) -> Double {
        guard let collectionView,
              let scrollView = collectionView.enclosingScrollView else { return 0 }

        let visibleBounds = scrollView.contentView.bounds
        guard visibleBounds.height > 0 else { return 0 }

        let sectionIndices = renderedSections.indices.filter { renderedSections[$0].topicId == topicId }
        guard !sectionIndices.isEmpty else { return 0 }

        var topicFrame: CGRect?
        for sectionIndex in sectionIndices {
            guard let sectionFrame = frameForSection(sectionIndex) else { continue }
            topicFrame = topicFrame.map { $0.union(sectionFrame) } ?? sectionFrame
        }

        guard let frame = topicFrame else { return 0 }
        let scrollableDistance = max(frame.height - visibleBounds.height, 1)
        let scrolled = visibleBounds.minY - frame.minY
        return min(max(scrolled / scrollableDistance, 0), 1)
    }

    static func sectionScrollProgress(
        collectionView: NSCollectionView?,
        renderedSections: [TopicSection],
        sectionIndex: Int,
        frameForSection: (Int) -> CGRect?
    ) -> Double {
        guard let collectionView,
              let scrollView = collectionView.enclosingScrollView,
              renderedSections.indices.contains(sectionIndex) else { return 0 }

        let visibleBounds = scrollView.contentView.bounds
        guard visibleBounds.height > 0 else { return 0 }

        guard let frame = frameForSection(sectionIndex) else { return 0 }
        let scrollableDistance = max(frame.height - visibleBounds.height, 1)
        let scrolled = visibleBounds.minY - frame.minY
        return min(max(scrolled / scrollableDistance, 0), 1)
    }

    static func refreshVisibleHeaders(
        collectionView: NSCollectionView?,
        renderedSections: [TopicSection],
        headerModel: (Int) -> CollectionSectionHeaderModel
    ) {
        guard let collectionView else { return }
        let startedAt = ContinuousClock.now
        let visibleRect = collectionView.visibleRect
        var refreshedCount = 0

        for sectionIndex in renderedSections.indices {
            let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
            guard let attributes = collectionView.collectionViewLayout?.layoutAttributesForSupplementaryView(
                ofKind: NSCollectionView.elementKindSectionHeader,
                at: headerIndexPath
            ) else { continue }
            guard attributes.frame.intersects(visibleRect),
                  let header = collectionView.supplementaryView(
                    forElementKind: NSCollectionView.elementKindSectionHeader,
                    at: headerIndexPath
                  ) as? CollectionSectionHeaderView else { continue }
            header.configure(model: headerModel(sectionIndex))
            refreshedCount += 1
        }

        let duration = startedAt.duration(to: .now)
        let millis = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        if millis >= 12 {
            AppLogger.discovery.debug(
                "refreshVisibleHeaders count=\(refreshedCount, privacy: .public) took \(Int(millis), privacy: .public)ms"
            )
        }
    }

    static func refreshTopicScrollProgress(
        store: OrganizerStore?,
        topicScrollProgress: (Int64) -> Double
    ) {
        guard let store else { return }
        let supportsTopicProgress =
            store.pageDisplayMode == .saved ||
            (store.pageDisplayMode == .watchCandidates && store.watchPresentationMode == .byTopic)

        guard supportsTopicProgress,
              let topicId = store.selectedTopicId else {
            if store.topicScrollProgress != 0 {
                store.topicScrollProgress = 0
            }
            return
        }

        let progress = topicScrollProgress(topicId)
        if abs(store.topicScrollProgress - progress) > 0.001 {
            store.topicScrollProgress = progress
        }
    }

    static func refreshViewportContext(
        store: OrganizerStore?,
        collectionView: NSCollectionView?,
        renderedSections: [TopicSection],
        visibleTopicIds: (CGRect) -> [Int64],
        primaryVisibleSectionIndex: (CGRect) -> Int?,
        currentVisibleCreatorSectionId: (CGRect, Int64) -> String?,
        currentVisibleSubtopicId: (Int, CGRect) -> Int64?
    ) {
        let startedAt = ContinuousClock.now
        guard let store,
              let collectionView,
              let scrollView = collectionView.enclosingScrollView else {
            store?.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
            return
        }

        if store.pageDisplayMode == .watchCandidates {
            guard store.watchPresentationMode == .byTopic else {
                store.updateVisibleWatchTopics([])
                store.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
                return
            }

            let visibleBounds = scrollView.contentView.bounds
            store.updateVisibleWatchTopics(visibleTopicIds(visibleBounds))
            guard let sectionIndex = primaryVisibleSectionIndex(visibleBounds) else {
                store.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
                return
            }

            let section = renderedSections[sectionIndex]
            let isCreatorMode = renderedSections.contains(where: { $0.creatorName != nil })

            if isCreatorMode {
                let creatorSectionId = currentVisibleCreatorSectionId(visibleBounds, section.topicId)
                store.updateViewportContext(topicId: section.topicId, subtopicId: nil, creatorSectionId: creatorSectionId)
            } else {
                store.updateViewportContext(topicId: section.topicId, subtopicId: nil, creatorSectionId: nil)
            }
            return
        }

        guard store.pageDisplayMode == .saved else {
            store.updateVisibleWatchTopics([])
            store.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
            return
        }

        let visibleBounds = scrollView.contentView.bounds
        guard let sectionIndex = primaryVisibleSectionIndex(visibleBounds) else {
            store.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
            return
        }

        let section = renderedSections[sectionIndex]
        let isCreatorMode = renderedSections.contains(where: { $0.creatorName != nil })

        if isCreatorMode {
            let creatorSectionId = currentVisibleCreatorSectionId(visibleBounds, section.topicId)
            store.updateViewportContext(topicId: section.topicId, subtopicId: nil, creatorSectionId: creatorSectionId)
            return
        }

        let subtopicId = currentVisibleSubtopicId(sectionIndex, visibleBounds)
        store.updateViewportContext(topicId: section.topicId, subtopicId: subtopicId, creatorSectionId: nil)

        let duration = startedAt.duration(to: .now)
        let millis = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        if millis >= 8 {
            AppLogger.discovery.debug(
                "refreshViewportContext mode=\(store.pageDisplayMode.rawValue, privacy: .public) watchMode=\(store.watchPresentationMode.rawValue, privacy: .public) took \(Int(millis), privacy: .public)ms"
            )
        }
    }

    static func primaryVisibleSectionIndex(
        renderedSections: [TopicSection],
        visibleBounds: CGRect,
        frameForSection: (Int) -> CGRect?
    ) -> Int? {
        var bestIndex: Int?
        var bestPriority = Int.max
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for sectionIndex in renderedSections.indices {
            guard let frame = frameForSection(sectionIndex) else { continue }

            let priority: Int
            let distance: CGFloat
            if frame.minY <= visibleBounds.minY, frame.maxY >= visibleBounds.minY {
                priority = 0
                distance = visibleBounds.minY - frame.minY
            } else if frame.minY > visibleBounds.minY {
                priority = 1
                distance = frame.minY - visibleBounds.minY
            } else {
                priority = 2
                distance = visibleBounds.minY - frame.maxY
            }

            if priority < bestPriority || (priority == bestPriority && distance < bestDistance) {
                bestPriority = priority
                bestDistance = distance
                bestIndex = sectionIndex
            }
        }

        return bestIndex
    }

    static func visibleTopicIds(
        renderedSections: [TopicSection],
        visibleBounds: CGRect,
        frameForSection: (Int) -> CGRect?
    ) -> [Int64] {
        var orderedTopicIds: [Int64] = []

        for sectionIndex in renderedSections.indices {
            guard let frame = frameForSection(sectionIndex),
                  frame.maxY >= visibleBounds.minY,
                  frame.minY <= visibleBounds.maxY else {
                continue
            }

            let topicId = renderedSections[sectionIndex].topicId
            if !orderedTopicIds.contains(topicId) {
                orderedTopicIds.append(topicId)
            }
        }

        return orderedTopicIds
    }

    static func currentVisibleCreatorSectionId(
        collectionView: NSCollectionView?,
        renderedSections: [TopicSection],
        visibleBounds: CGRect,
        topicId: Int64,
        viewportTopicId: Int64?,
        viewportCreatorSectionId: String?
    ) -> String? {
        guard let collectionView else { return nil }

        let candidateIndices = renderedSections.indices.filter {
            renderedSections[$0].topicId == topicId && renderedSections[$0].creatorName != nil
        }
        guard !candidateIndices.isEmpty else { return nil }

        let dockTolerance: CGFloat = 1
        let dockedIndices = candidateIndices.filter { sectionIndex in
            let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
            guard let headerFrame = collectionView.collectionViewLayout?.layoutAttributesForSupplementaryView(
                ofKind: NSCollectionView.elementKindSectionHeader,
                at: headerIndexPath
            )?.frame else {
                return false
            }
            return headerFrame.minY <= visibleBounds.minY + dockTolerance
        }

        if let docked = dockedIndices.max() {
            return renderedSections[docked].id
        }

        if viewportTopicId == topicId,
           let current = viewportCreatorSectionId,
           candidateIndices.contains(where: { renderedSections[$0].id == current }) {
            return current
        }

        return candidateIndices.first.map { renderedSections[$0].id }
    }

    static func currentVisibleSubtopicId(
        collectionView: NSCollectionView?,
        renderedSections: [TopicSection],
        sectionIndex: Int,
        visibleBounds: CGRect
    ) -> Int64? {
        guard let collectionView,
              renderedSections.indices.contains(sectionIndex) else { return nil }

        let section = renderedSections[sectionIndex]
        let visibleItems = collectionView.indexPathsForVisibleItems()
            .filter { $0.section == sectionIndex }
            .compactMap { indexPath -> (CGRect, VideoGridItemModel)? in
                guard indexPath.item < section.videos.count,
                      let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return nil }
                return (frame, section.videos[indexPath.item])
            }
            .sorted { lhs, rhs in
                let lhsDistance = distanceFromViewportTop(lhs.0, visibleTop: visibleBounds.minY)
                let rhsDistance = distanceFromViewportTop(rhs.0, visibleTop: visibleBounds.minY)
                if lhsDistance == rhsDistance {
                    if lhs.0.minY == rhs.0.minY {
                        return lhs.0.minX < rhs.0.minX
                    }
                    return lhs.0.minY < rhs.0.minY
                }
                return lhsDistance < rhsDistance
            }

        for (_, video) in visibleItems {
            if let subtopicId = section.videoSubtopicMap[video.id] {
                return subtopicId
            }
        }

        return nil
    }

    static func distanceFromViewportTop(_ frame: CGRect, visibleTop: CGFloat) -> CGFloat {
        if frame.minY <= visibleTop, frame.maxY >= visibleTop {
            return visibleTop - frame.minY
        }
        if frame.minY > visibleTop {
            return frame.minY - visibleTop
        }
        return visibleTop - frame.maxY
    }
}
