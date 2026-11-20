import KhoCore
import SwiftUI

struct CapacityBar: View {
    let total: Int64
    let free: Int64

    var body: some View {
        let used = max(0, total - free)
        let fraction = total > 0 ? Double(used) / Double(total) : 0
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction)
                .tint(fraction > 0.9 ? .orange : .accentColor)
            Text("Đã dùng \(ByteFormat.string(used)) / \(ByteFormat.string(total)) · còn trống \(ByteFormat.string(free))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
