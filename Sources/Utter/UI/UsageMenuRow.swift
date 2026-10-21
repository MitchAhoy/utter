import SwiftUI

/// Colour band for how much of today's allowance is left.
enum UsageLevel: Equatable {
    case plenty, middling, low

    /// Green at 60% and above, yellow from 40% to 60%, red below 40%.
    init(fraction: Double) {
        self = fraction >= 0.6 ? .plenty : fraction >= 0.4 ? .middling : .low
    }

    var color: Color {
        switch self {
        case .plenty: .green
        case .middling: .yellow
        case .low: .red
        }
    }
}

/// One menu row: model name and percentage, a coloured bar, and the exact count.
struct UsageMenuRow: View {
    let title: String
    let remaining: Int
    let limit: Int
    let detail: String?

    private var fraction: Double { limit > 0 ? min(1, max(0, Double(remaining) / Double(limit))) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(UsageLevel(fraction: fraction).color)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(UsageLevel(fraction: fraction).color)
                        .frame(width: max(fraction > 0 ? 6 : 0, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text("\(remaining.formatted()) of \(limit.formatted()) left" + (detail.map { " · \($0)" } ?? ""))
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(width: 290, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
