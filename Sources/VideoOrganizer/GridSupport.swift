import AppKit
import SwiftUI

/// A section of the video grid representing one topic (or creator group within a topic).
struct TopicSection: Identifiable, Equatable {
    let topicId: Int64
    let topicName: String
    let videos: [VideoGridItemModel]
    var totalCount: Int?
    var headerCountOverride: Int? = nil
    var videoSubtopicMap: [String: Int64] = [:]
    var displayMode: TopicDisplayMode = .saved
    var creatorName: String? = nil
    var creatorChannelId: String? = nil
    var creatorChannelUrl: URL? = nil
    var channelIconUrl: URL? = nil
    var topicNames: [String] = []

    var id: String {
        if let creator = creatorName {
            return "creator-\(topicId)-\(creator)"
        }
        return "topic-\(topicId)"
    }
}

struct VideoGridItemModel: Identifiable, Equatable {
    let id: String
    let topicId: Int64?
    let title: String
    let channelName: String?
    let topicName: String?
    let thumbnailUrl: URL?
    let viewCount: String?
    let publishedAt: String?
    let duration: String?
    let channelIconUrl: URL?
    let channelId: String?
    let candidateScore: Double?
    let stateTag: String?
    let isPlaceholder: Bool
    let placeholderMessage: String?
}

extension View {
    func onDoubleClick(perform action: @escaping () -> Void) -> some View {
        modifier(DoubleClickModifier(action: action))
    }

    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct DoubleClickModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay { DoubleClickView(action: action) }
    }
}

private struct DoubleClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DoubleClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DoubleClickNSView)?.action = action
    }
}

private final class DoubleClickNSView: NSView {
    var action: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            action?()
        } else {
            nextResponder?.mouseDown(with: event)
        }
    }
}
