import AppKit
import KhoCore
import SwiftUI

/// One row in the app table: an app, or one of its data folders.
struct FootprintRow: Identifiable, Hashable {
    let id: String
    let name: String
    let data: Int64
    let bundle: Int64?
    let total: Int64
    let lastUsed: UsageDate?
    let hasVM: Bool
    let running: Bool?
    var children: [FootprintRow]?

    var bundleSort: Int64 { bundle ?? -1 }
    var lastUsedSort: Date { lastUsed?.date ?? .distantPast }
}

extension UsageSource {
    var label: String {
        switch self {
        case .lastUsedXattr: return "mở lần cuối"
        case .spotlight: return "Spotlight"
        case .modified: return "ngày sửa"
        case .added: return "ngày thêm"
        }
    }
}

/// Warning icon for large VM disk images, with text for tooltips and VoiceOver.
struct VMImageBadge: View {
    var body: some View {
        Image(systemName: "shippingbox.fill")
            .foregroundStyle(.orange)
            .help("Có ảnh đĩa máy ảo từ 1 GiB trở lên")
            .accessibilityLabel("Có ảnh đĩa máy ảo")
    }
}

struct AppFootprintTable: View {
    @Environment(AppModel.self) private var model
    let map: AppDataMap
    @Binding var selection: FootprintRow.ID?
    @State private var sortOrder = [KeyPathComparator(\FootprintRow.total, order: .reverse)]

    var rows: [FootprintRow] {
        let base = map.footprints.map { fp in
            FootprintRow(
                id: fp.app.id, name: fp.app.name, data: fp.dataAllocated, bundle: fp.bundleAllocated,
                total: fp.total, lastUsed: fp.app.lastUsed, hasVM: fp.hasVMImage, running: model.isRunning(fp.app),
                children: fp.folders.isEmpty ? nil : fp.folders.map { f in
                    FootprintRow(id: f.id, name: "\(f.area.rawValue)/\(f.url.lastPathComponent)", data: f.allocated,
                                 bundle: nil, total: f.allocated, lastUsed: nil, hasVM: f.hasVMImage, running: nil)
                })
        }
        return base.sorted(using: sortOrder).map { row in
            var r = row
            r.children = row.children?.sorted(using: sortOrder)
            return r
        }
    }

    var body: some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Ứng dụng", value: \.name) { r in
                Text(r.name).lineLimit(1).truncationMode(.middle).help(r.name)
            }
            .width(min: 160, ideal: 240)
            TableColumn("Dữ liệu", value: \.data) { BytesText(bytes: $0.data) }.width(min: 70, ideal: 90)
            TableColumn("Bundle", value: \.bundleSort) { BytesText(bytes: $0.bundle) }.width(min: 70, ideal: 90)
            TableColumn("Tổng", value: \.total) { BytesText(bytes: $0.total).bold() }.width(min: 70, ideal: 90)
            TableColumn("Dùng lần cuối", value: \.lastUsedSort) { r in
                if let u = r.lastUsed {
                    Text(u.date.vi(date: .abbreviated, time: .omitted)).monospacedDigit()
                        .help("Nguồn: \(u.source.label)")
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Ảnh máy ảo") { r in
                if r.hasVM { VMImageBadge() }
            }
            .width(70)
            TableColumn("Đang chạy") { r in
                if r.running == true {
                    StatusLabel("Đang chạy", systemImage: "circle.fill", tint: .green)
                }
            }
            .width(min: 80, ideal: 90)
        }
        .contextMenu(forSelectionType: FootprintRow.ID.self) { ids in
            if let id = ids.first, let app = map.footprints.first(where: { $0.app.id == id })?.app {
                Button("Dọn cache của \(app.name)") { model.showCleanup(for: app.bundleID) }
                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            } else if let id = ids.first {
                Button("Hiện trong Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
                }
            }
        }
    }
}
