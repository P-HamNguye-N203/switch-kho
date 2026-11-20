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
                if let notice = model.guardNotice {
                    HStack {
                        StatusLabel(notice, systemImage: "hand.raised.fill", tint: .red)
                        Spacer()
                        Button("Đã hiểu") { model.guardNotice = nil }
                    }
                    .padding(10)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if model.liveIssues.values.contains(where: { $0.contains { $0 != .ok && $0 != .khoMissing } }) {
                    HStack {
                        StatusLabel("Một app chạy từ Kho có liên kết cần xử lý", systemImage: "exclamationmark.triangle.fill")
                        Spacer()
                        Button("Xem") { model.section = .live }
                    }
                }
                internalCard
                khoCard
                holdingCard
                warnings
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Tổng quan")
        .sheet(isPresented: $showHolding) { HoldingListView() }
        .confirmationDialog("Dùng ổ này làm Kho?", isPresented: Binding(presenting: $pendingAdopt),
                            presenting: pendingAdopt) { v in
            Button("Dùng ổ này làm Kho") { model.adopt(v) }
            Button("Thôi", role: .cancel) {}
        } message: { v in
            Text("Switch Kho sẽ ghi một dấu nhận vào \(v.name)/SwitchKho/.kho-id. Chỉ ổ có dấu này mới nhận dữ liệu được cất.")
        }
        .confirmationDialog("Ổ này có sổ cái sao lưu", isPresented: Binding(presenting: $askRestore),
                            presenting: askRestore) { v in
            Button("Không, dùng làm Kho mới") {
                // Let this dialog finish closing before the next one opens.
                DispatchQueue.main.async { pendingAdopt = v }
            }
            Button("Thôi", role: .cancel) {}
        } message: { _ in
            Text("Ổ này đã từng làm Kho và có bản sao lưu sổ cái. Khôi phục sổ cái từ ổ này có ở bản sau; hiện chỉ dùng được như Kho mới.")
        }
    }

    private var internalCard: some View {
        GroupBox("Ổ trong máy") {
            if let v = model.internalVolume {
                CapacityBar(label: "Ổ trong máy", total: v.total, free: v.availableForImportant).padding(4)
            } else {
                Text("Không đọc được ổ trong").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var khoCard: some View {
        GroupBox("Kho") {
            VStack(alignment: .leading, spacing: 10) {
                if model.savedKhoUUID == nil {
                    Text("Chọn Kho").font(.headline)
                    Text("Chọn ổ ngoài dùng làm Kho. Switch Kho không tự chọn.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.externalVolumes.isEmpty {
                        StatusLabel("Chưa thấy ổ ngoài nào. Hãy cắm ổ Kho.", systemImage: "externaldrive.badge.questionmark",
                                    tint: .secondary)
                    }
                    ForEach(model.externalVolumes) { v in volumeRow(v) }
                } else if let v = model.khoVolume {
                    HStack {
                        StatusLabel("Đang cắm · \(v.name)", systemImage: "circle.fill", tint: .green)
                        Spacer()
                        Button("Eject") { model.eject() }
                    }
                    CapacityBar(label: "Kho \(v.name)", total: v.total, free: v.available)
                } else {
                    StatusLabel("Chưa cắm", systemImage: "circle", tint: .secondary)
                }
                if let problem = model.khoProblem {
                    StatusLabel(problem, systemImage: "exclamationmark.triangle.fill")
                }
                if model.offerLedgerRestore {
                    StatusLabel("Bản sao lưu sổ cái trên Kho có nhiều thao tác hơn sổ cái trong máy. Switch Kho không ghi đè nó.",
                                systemImage: "exclamationmark.triangle.fill")
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func volumeRow(_ v: VolumeInfo) -> some View {
        HStack {
            Image(systemName: "externaldrive")
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name)
                Text("\(ByteFormat.string(v.available)) trống · \(v.format ?? "không rõ định dạng")")
                    .font(.callout).foregroundStyle(.secondary)
                if !v.isAPFS {
                    Text("Kho phải là ổ APFS. Hãy định dạng lại ổ này bằng Disk Utility nếu muốn dùng.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
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

    private var holdingCard: some View {
        GroupBox("Vùng chờ") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Đang trong vùng chờ: \(ByteFormat.string(model.holdingBytes)) · tự xoá sau \(model.holdDays) ngày")
                        .monospacedDigit()
                    Spacer()
                    Button("Xem") { model.refreshOperations(); showHolding = true }
                }
                if model.holdingNeedsAttention {
                    StatusLabel("Vùng chờ lớn hoặc ổ trong sắp đầy. Cắm Kho để xoá phần đã đến hạn.",
                                systemImage: "exclamationmark.triangle.fill")
                }
                let attention = model.holdingRows.filter { $0.op.error != nil || $0.op.needsReview }.count
                if attention > 0 {
                    StatusLabel("\(attention) thao tác cần xem", systemImage: "exclamationmark.circle.fill")
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if !model.hasFullDiskAccess {
            GroupBox {
                HStack {
                    StatusLabel("Switch Kho chưa có Full Disk Access nên một số thư mục không đọc được.",
                                systemImage: "lock.shield")
                    Spacer()
                    Button("Mở Cài đặt") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("Kiểm lại") { model.checkEnvironment() }
                }
            }
        }
        if model.hasTimeMachine == false {
            Text("Không có sao lưu Time Machine (đã chấp nhận rủi ro)").font(.callout).foregroundStyle(.secondary)
        }
    }
}
