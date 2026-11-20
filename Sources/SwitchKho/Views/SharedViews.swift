import KhoCore
import SwiftUI

extension Binding where Value == Bool {
    /// True while `item` is set; dismissing (Esc, click outside) clears the item.
    init<T: Sendable>(presenting item: Binding<T?>) {
        self.init(get: { item.wrappedValue != nil },
                  set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// Status text whose meaning never rests on color alone: a tinted icon plus readable text.
struct StatusLabel: View {
    let text: String
    let systemImage: String
    var tint: Color = .orange

    init(_ text: String, systemImage: String, tint: Color = .orange) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
    }
}

/// Byte count aligned for columns.
struct BytesText: View {
    let bytes: Int64?
    var body: some View {
        Text(bytes.map(ByteFormat.string) ?? "—")
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

