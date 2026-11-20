import KhoCore
import SwiftUI

struct HoldingListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCommit: HoldingRow?
    @State private var confirmReviewed: HoldingRow?
    @State private var confirmAccept: HoldingRow?

    private var orphans: [String] { model.recoveryReport?.orphanHoldingDirs ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Vùng chờ").font(.title2.bold())
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.holdingRows.isEmpty && orphans.isEmpty {
                ContentUnavailableView("Vùng chờ trống", systemImage: "tray",
                                       description: Text("Dữ liệu vừa cất sẽ nằm ở đây \(model.holdDays) ngày trước khi xoá."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.holdingRows) { row in rowView(row) }
                    if !orphans.isEmpty {
                        Section("Vùng chờ mồ côi") {
                            ForEach(orphans, id: \.self) { name in
                                HStack {
                                    Text(name).font(.callout.monospaced())
                                    Spacer()
                                    BytesText(bytes: model.orphanSize(name)).frame(width: 90)
                                    Button("Mở trong Finder") { model.revealOrphan(name) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
        .confirmationDialog("Xoá vùng chờ ngay?", isPresented: Binding(presenting: $confirmCommit),
                            presenting: confirmCommit) { row in
            Button("Xoá ngay", role: .destructive) { model.commitNow(row.op.id) }
            Button("Thôi", role: .cancel) {}
        } message: { _ in
            Text("Không thể hoàn tác sau bước này. Bản trên Kho sẽ được băm lại trước khi xoá.")
        }
        .confirmationDialog("Chấp nhận bản hiện tại trên Kho?", isPresented: Binding(presenting: $confirmAccept),
                            presenting: confirmAccept) { row in
            Button("Chấp nhận bản trên Kho", role: .destructive) { model.acceptKhoCopy(row.op.id) }
            Button("Thôi", role: .cancel) {}
        } message: { _ in
            Text("Bản trên Kho khác lúc cất (có thể do bạn sửa qua liên kết). Sau khi chấp nhận, bản cũ trong vùng chờ sẽ được xoá ở lần dọn kế tiếp. Hãy mở trong Finder kiểm trước.")
        }
        .confirmationDialog("Đánh dấu đã kiểm?", isPresented: Binding(presenting: $confirmReviewed),
                            presenting: confirmReviewed) { row in
            Button("Đã kiểm") { model.markReviewed(row.op.id) }
            Button("Thôi", role: .cancel) {}
        } message: { _ in
            Text("Chỉ đánh dấu khi bạn đã xem vùng chờ và bản trên Kho đều đúng.")
        }
    }

    @ViewBuilder
    private func rowView(_ row: HoldingRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.op.title ?? "Thao tác #\(row.op.id)").font(.headline)
                Text(ByteFormat.string(row.bytes)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if model.busyOps.contains(row.op.id) {
                    ProgressView().controlSize(.small)
                    Text("Đang xử lý").font(.callout).foregroundStyle(.secondary)
                } else {
                    actions(row)
                }
            }
            Text(row.items.map(\.originalURL.lastPathComponent).joined(separator: ", "))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                .help(row.items.map(\.originalURL.path).joined(separator: "\n"))
            status(row)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func status(_ row: HoldingRow) -> some View {
        if row.op.needsReview {
            StatusLabel("Khôi phục từ bản sao lưu, cần kiểm", systemImage: "exclamationmark.triangle.fill")
        } else if row.overdue {
            StatusLabel(row.op.error ?? "Đã đến hạn, chờ cắm Kho để kiểm trước khi xoá", systemImage: "clock.badge.exclamationmark")
        } else if let error = row.op.error {
            StatusLabel(error, systemImage: "xmark.octagon.fill", tint: .red)
        } else if let until = row.op.holdingUntil {
            Text("Tự xoá sau \(until.formatted(date: .abbreviated, time: .shortened)) (khi Kho cắm và kiểm khớp)")
                .font(.callout).foregroundStyle(.secondary)
        }
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
                    Button("Chấp nhận bản trên Kho") { confirmAccept = row }
                        .disabled(model.kho == nil)
                        .help(model.kho == nil ? "Cắm Kho để chấp nhận" : "")
                }
                // Live data must go through the checks for folders made while the Kho was away.
                Button("Hoàn tác") {
                    if row.op.kind == .appLive && row.items.contains(where: { $0.role == .normal }) {
                        model.bringBackLive(row.op)
                    } else {
                        model.undo(row.op.id)
                    }
                }
                Divider().frame(height: 16)
                Button("Xoá ngay", role: .destructive) { confirmCommit = row }
                    .disabled(model.kho == nil)
                    .help(model.kho == nil ? "Cắm Kho để kiểm bản trên Kho trước khi xoá" : "Xoá bản trong vùng chờ sau khi kiểm")
            case .undoing, .restoring, .moving, .committing:
                Button("Thử lại") { model.retry(row) }
            default:
                EmptyView()
            }
        }
    }
}
