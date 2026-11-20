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

struct AppFootprintTable: View {
    @Environment(AppModel.self) private var model
    let map: AppDataMap

    var rows: [FootprintRow] {
        map.footprints.map { fp in
            FootprintRow(
                id: fp.app.id, name: fp.app.name, data: fp.dataAllocated, bundle: fp.bundleAllocated,
                total: fp.total, lastUsed: fp.app.lastUsed, hasVM: fp.hasVMImage, running: model.isRunning(fp.app),
                children: fp.folders.isEmpty ? nil : fp.folders.map { f in
                    FootprintRow(id: f.id, name: "\(f.area.rawValue)/\(f.url.lastPathComponent)", data: f.allocated,
                                 bundle: nil, total: f.allocated, lastUsed: nil, hasVM: f.hasVMImage, running: nil)
                })
        }
    }

    var body: some View {
        Table(rows, children: \.children) {
            TableColumn("Ứng dụng", value: \.name)
            TableColumn("Dữ liệu") { Text(ByteFormat.string($0.data)) }
            TableColumn("Bundle") { r in Text(r.bundle.map(ByteFormat.string) ?? "") }
            TableColumn("Tổng") { Text(ByteFormat.string($0.total)).bold() }
            TableColumn("Dùng lần cuối") { r in
                if let u = r.lastUsed {
                    Text("\(u.date.formatted(date: .abbreviated, time: .omitted)) (\(u.source.label))")
                }
            }
            TableColumn("Ảnh máy ảo") { r in
                if r.hasVM { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            TableColumn("Đang chạy") { r in
                if r.running == true { Text("● chạy").foregroundStyle(.green) }
            }
        }
    }
}
