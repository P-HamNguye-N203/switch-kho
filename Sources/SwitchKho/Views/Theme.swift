import AppKit
import SwiftUI

extension Color {
    /// Teal from the app icon; lighter in dark mode so it keeps its contrast.
    static let brand = Color(nsColor: NSColor(name: "brand") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.35, green: 0.74, blue: 0.76, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.44, blue: 0.47, alpha: 1)
    })
    /// Amber from the app icon, for things worth a look (not errors).
    static let brandAmber = Color(nsColor: NSColor(srgbRed: 0.94, green: 0.55, blue: 0.13, alpha: 1))
}

enum VN {
    static let locale = Locale(identifier: "vi_VN")
}

extension Date {
    /// Always Vietnamese, whatever the system language.
    func vi(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: VN.locale))
    }
}

extension View {
    /// Page content starts at the top-left and fills the detail column.
    func pageLayout(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Empty and loading states take the remaining space and sit in its middle.
    func fillCentered() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A titled group of rows on a raised surface, as wide as the page allows.
struct Card<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.headline).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
            if let footer {
                Text(footer).font(.callout).foregroundStyle(.secondary).padding(.leading, 4)
            }
        }
    }
}

/// A search box that reads as one: icon, large field, clear button.
struct SearchBox: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Xoá ô tìm")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// A large figure with a caption, for the overview.
struct Figure: View {
    let value: String
    let caption: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
            Text(caption).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
