import SwiftUI

/// A simple wrapping flow layout: places subviews left-to-right, wrapping to a
/// new line when the next subview wouldn't fit in the remaining horizontal
/// space. Used by the creator detail page's themes section so tag capsules
/// flow into multiple rows instead of being hidden behind a horizontal
/// ScrollView.
///
/// macOS 13+ Layout API. No external dependencies, no view-state churn —
/// pure measurement + placement based on `proposal.width` and each subview's
/// `sizeThatFits`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = layoutLines(maxWidth: maxWidth, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + CGFloat(max(0, lines.count - 1)) * lineSpacing
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        let lines = layoutLines(maxWidth: maxWidth, subviews: subviews)

        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for entry in line.entries {
                let size = entry.size
                subviews[entry.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    // MARK: - Internal layout pass

    private struct LineEntry {
        let index: Int
        let size: CGSize
    }

    private struct Line {
        var entries: [LineEntry] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutLines(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var current = Line()

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let projectedWidth = current.width == 0
                ? size.width
                : current.width + spacing + size.width

            if projectedWidth > maxWidth, !current.entries.isEmpty {
                lines.append(current)
                current = Line()
                current.entries.append(LineEntry(index: index, size: size))
                current.width = size.width
                current.height = size.height
            } else {
                if !current.entries.isEmpty {
                    current.width += spacing
                }
                current.entries.append(LineEntry(index: index, size: size))
                current.width += size.width
                current.height = max(current.height, size.height)
            }
        }
        if !current.entries.isEmpty {
            lines.append(current)
        }
        return lines
    }
}
