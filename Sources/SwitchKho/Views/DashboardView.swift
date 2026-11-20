import KhoCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showHolding = false
    @State private var pendingAdopt: VolumeInfo?
    @State private var askRestore: VolumeInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = model.lastError {
                    GroupBox {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(error)
                            Spacer()
                            Button("Ẩn") { model.lastError = nil }
                        }
                    }
                }
                internalCard
                khoCard
                holdingCard
                warnings
            }
            .padding(20)
        }
        .navigationTitle("Tổng quan")
        .sheet(isPresented: $showHolding) { HoldingListView() }
        .confirmationDialog("Dùng ổ này làm Kho?", isPresented: .constant(pendingAdopt != nil), presenting: pendingAdopt) { v in
            Button("Dùng ổ này làm Kho") { model.adopt(v); pendingAdopt = nil }
            Button("Thôi", role: .cancel) { pendingAdopt = nil }
        } message: { v in
            Text("Switch Kho sẽ ghi một dấu nhận vào \(v.name)/SwitchKho/.kho-id. Chỉ ổ có dấu này mới nhận dữ liệu được cất.")
        }
        .confirmationDialog("Ổ này có sổ cái sao lưu", isPresented: .constant(askRestore != nil), presenting: askRestore) { v in
            Button("Có (có ở bản sau)") {}.disabled(true)
            Button("Không, dùng làm Kho mới") { pendingAdopt = v; askRestore = nil }
            Button("Thôi", role: .cancel) { askRestore = nil }
        } message: { _ in
            Text("Khôi phục sổ cái từ ổ này? Tính năng khôi phục có ở bản sau.")
        }
    }

    private var internalCard: some View {
        GroupBox("Ổ trong máy") {
            if let v = model.internalVolume {
                CapacityBar(total: v.total, free: v.availableForImportant).padding(4)
            } else {
                Text("Không đọc được ổ trong").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var khoCard: some View {
        GroupBox("Kho") {
            VStack(alignment: .leading, spacing: 8) {
                if model.savedKhoUUID == nil {
                    Text("Chọn Kho").font(.headline)
                    Text("Chọn ổ ngoài dùng làm Kho. Switch Kho không tự chọn.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.externalVolumes.isEmpty {
                        Text("Chưa thấy ổ ngoài nào. Hãy cắm ổ Kho.").foregroundStyle(.secondary)
                    }
                    ForEach(model.externalVolumes) { v in
                        HStack {
                            Image(systemName: "externaldrive")
                            Text(v.name)
                            Text("\(ByteFormat.string(v.available)) trống · \(v.format ?? "?")")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Dùng ổ này làm Kho") {
                                if model.volumeHasLedgerBackup(v) && model.ledgerIsEmpty {
                                    askRestore = v
                                } else {
                                    pendingAdopt = v
                                }
                            }
                            .disabled(!v.isAPFS)
                        }
                    }
                } else if let v = model.khoVolume {
                    HStack {
                        Text("● Đang cắm").foregroundStyle(.green)
                        Text(v.name)
                        Spacer()
                        Button("Eject") { model.eject() }
                    }
                    CapacityBar(total: v.total, free: v.available)
                } else {
                    Text("○ Chưa cắm").foregroundStyle(.secondary)
                }
                if let problem = model.khoProblem {
                    Text(problem).foregroundStyle(.orange)
                }
                if model.offerLedgerRestore {
                    Text("Bản sao lưu sổ cái trên Kho có nhiều thao tác hơn sổ cái trong máy. Switch Kho không ghi đè nó.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
    }

    private var holdingCard: some View {
        GroupBox("Vùng chờ") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Đang trong vùng chờ: \(ByteFormat.string(model.holdingBytes)) · tự xoá sau \(model.holdDays) ngày")
                        .foregroundStyle(model.holdingNeedsAttention ? .orange : .primary)
                    Spacer()
                    Button("Xem") { model.refreshOperations(); showHolding = true }
                }
                if model.holdingNeedsAttention {
                    Text("Cắm Kho để xoá vùng chờ đã đến hạn").font(.caption).foregroundStyle(.orange)
                }
                let attention = model.holdingRows.filter { $0.op.error != nil || $0.op.needsReview }.count
                if attention > 0 {
                    Text("\(attention) thao tác cần xem").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if !model.hasFullDiskAccess {
            GroupBox {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Switch Kho chưa có Full Disk Access nên một số thư mục không đọc được.")
                    Spacer()
                    Button("Mở Cài đặt") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("Kiểm lại") { model.checkEnvironment() }
                }
            }
        }
        if model.hasTimeMachine == false {
            Text("Không có sao lưu (đã chấp nhận rủi ro)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
