import KhoCore
import SwiftUI

struct CapacityBar: View {
    let label: String
    let total: Int64
    let free: Int64

    var body: some View {
        let used = max(0, total - free)
        let fraction = total > 0 ? Double(used) / Double(total) : 0
        let summary = "Đã dùng \(ByteFormat.string(used)) / \(ByteFormat.string(total)) · còn trống \(ByteFormat.string(free))"
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction)
                .tint(fraction > 0.9 ? .orange : .brand)
            HStack(spacing: 6) {
                if fraction > 0.9 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(summary).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(summary)
    }
}
