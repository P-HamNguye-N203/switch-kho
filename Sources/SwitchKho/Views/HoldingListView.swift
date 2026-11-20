import KhoCore
import SwiftUI

struct HoldingListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCommit: HoldingRow?
    @State private var confirmReviewed: HoldingRow?
    @State private var confirmAccept: HoldingRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Vùng chờ").font(.title2.bold())
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.holdingRows.isEmpty && (model.recoveryReport?.orphanHoldingDirs.isEmpty ?? true) {
                ContentUnavailableView("Vùng chờ trống", systemImage: "tray")
            }
            List {
                ForEach(model.holdingRows) { row in
                    rowView(row)
                }
                if let orphans = model.recoveryReport?.orphanHoldingDirs, !orphans.isEmpty {
                    Section("Vùng chờ mồ côi") {
                        ForEach(orphans, id: \.self) { name in
                            HStack {
                                Text(name).font(.callout.monospaced())
                                Text(ByteFormat.string(model.orphanSize(name))).foregroundStyle(.secondary)
                                Spacer()
                                Button("Mở trong Finder") { model.revealOrphan(name) }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
        .confirmationDialog("Xoá vùng chờ ngay?", isPresented: .constant(confirmCommit != nil), presenting: confirmCommit) { row in
            Button("Xoá ngay", role: .destructive) { model.commitNow(row.op.id); confirmCommit = nil }
            Button("Thôi", role: .cancel) { confirmCommit = nil }
        } message: { _ in
            Text("Không thể hoàn tác sau bước này. Bản trên Kho sẽ được băm lại trước khi xoá.")
        }
        .confirmationDialog("Chấp nhận bản hiện tại trên Kho?", isPresented: .constant(confirmAccept != nil), presenting: confirmAccept) { row in
            Button("Chấp nhận bản trên Kho", role: .destructive) { model.acceptKhoCopy(row.op.id); confirmAccept = nil }
            Button("Thôi", role: .cancel) { confirmAccept = nil }
        } message: { _ in
            Text("Bản trên Kho khác lúc cất (có thể do bạn sửa qua liên kết). Sau khi chấp nhận, bản cũ trong vùng chờ sẽ được xoá ở lần dọn kế tiếp. Hãy mở trong Finder kiểm trước.")
        }
        .confirmationDialog("Đánh dấu đã kiểm?", isPresented: .constant(confirmReviewed != nil), presenting: confirmReviewed) { row in
            Button("Đã kiểm") { model.markReviewed(row.op.id); confirmReviewed = nil }
            Button("Thôi", role: .cancel) { confirmReviewed = nil }
        } message: { _ in
            Text("Chỉ đánh dấu khi bạn đã xem vùng chờ và bản trên Kho đều đúng.")
        }
    }

    @ViewBuilder
    private func rowView(_ row: HoldingRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.op.title ?? "Thao tác #\(row.op.id)").font(.headline)
                Text(ByteFormat.string(row.bytes)).foregroundStyle(.secondary)
                Spacer()
                actions(row)
            }
            Text(row.items.map(\.originalURL.lastPathComponent).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if row.op.needsReview {
                Text("Khôi phục từ bản sao lưu, cần kiểm").font(.caption).foregroundStyle(.orange)
            } else if row.overdue {
                Text(row.op.error ?? "Đã đến hạn, chờ cắm Kho để kiểm trước khi xoá")
                    .font(.caption).foregroundStyle(.orange)
            } else if let error = row.op.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let until = row.op.holdingUntil {
                Text("Tự xoá sau \(until.formatted(date: .abbreviated, time: .shortened)) (khi Kho cắm và kiểm khớp)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actions(_ row: HoldingRow) -> some View {
        if row.op.needsReview {
            Button("Mở trong Finder") { model.reveal(row) }
            Button("Đánh dấu đã kiểm") { confirmReviewed = row }
        } else {
            switch row.op.state {
            case .holding:
                if row.op.error != nil {
                    Button("Mở trong Finder") { model.reveal(row) }
                    Button("Chấp nhận bản trên Kho") { confirmAccept = row }.disabled(model.kho == nil)
                }
                Button("Hoàn tác") { model.undo(row.op.id) }
                Button("Xoá ngay") { confirmCommit = row }.disabled(model.kho == nil)
            case .undoing, .restoring, .moving, .committing:
                Button("Thử lại") { model.retry(row) }
            default:
                EmptyView()
            }
        }
    }
}
