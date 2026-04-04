import SwiftUI

struct SectionHeaderView: View {
    let name: String
    let count: Int
    var totalCount: Int?
    let topicId: Int64
    let progress: Double
    var showProgress: Bool = true
    var highlightTerms: [String] = []
    var displayMode: TopicDisplayMode = .saved
    var progressTitle: String?
    var progressDetail: String?
    var onDisplayModeChange: ((TopicDisplayMode) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: TopicTheme.iconName(for: name))
                    .font(.title3)
                    .foregroundStyle(TopicTheme.iconColor(for: name))

                HighlightedText(name, terms: highlightTerms)
                    .font(.title3.bold())

                Group {
                    if let total = totalCount {
                        Text("\(count) of \(total)")
                    } else {
                        Text("\(count)")
                    }
                }
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

                Toggle(isOn: Binding(
                    get: { displayMode == .watchCandidates },
                    set: { isOn in
                        onDisplayModeChange?(isOn ? .watchCandidates : .saved)
                    }
                )) {
                    Label("Watch?", systemImage: "sparkles")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(displayMode == .watchCandidates ? "Showing watch candidates" : "Show watch candidates")
                .accessibilityLabel("Watch?")
                .accessibilityValue(displayMode == .watchCandidates ? "On" : "Off")

                Spacer()
            }
            .padding(.horizontal, GridConstants.horizontalPadding)
            .padding(.vertical, 10)

            if showProgress, let progressTitle, let progressDetail {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(progress, 0), 1), total: 1)
                        .progressViewStyle(.linear)
                        .controlSize(.small)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(progressTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(progressDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, GridConstants.horizontalPadding)
                .padding(.bottom, 10)
                .transition(.opacity)
            } else {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.1))
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * max(progress, 0))
                            .animation(.easeOut(duration: GridConstants.progressAnimationDuration), value: progress)
                    }
                }
                .frame(height: GridConstants.progressBarHeight)
                .opacity(showProgress ? 1 : 0)
                .accessibilityHidden(!showProgress)
            }
        }
        .background(.bar)
    }
}
