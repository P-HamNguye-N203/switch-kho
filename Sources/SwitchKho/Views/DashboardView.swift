import KhoCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showHolding = false
    @State private var pendingAdopt: VolumeInfo?
    @State private var askRestore: VolumeInfo?
    @AppStorage("overview.hideNoBackupNotice") private var hideNoBackupNotice = false

    /// Apps not opened for this many days are offered for archiving.
    static let idleAppDays = 90

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                alerts
                Card { hero }
                suggestions
                khoSection
                holdingSection
                environmentSection
            }
            .padding(24)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Tổng quan")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.scanApps()
                    model.scanCleanup()
                } label: {
                    Label("Quét lại", systemImage: "arrow.clockwise")
                }
                .labelStyle(.titleAndIcon)
                .help("Đo lại dung lượng app và tìm rác có thể dọn (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isScanningApps || model.isScanningCleanup)
                if model.kho != nil {
                    Button { model.eject() } label: { Label("Tháo Kho", systemImage: "eject") }
                        .labelStyle(.titleAndIcon)
                        .help("Dừng việc đang chép, thoát app chạy từ Kho rồi tháo ổ an toàn")
                        .disabled(model.isEjecting)
                }
            }
        }
        .onAppear {
            if model.appDataMap == nil && !model.isScanningApps { model.scanApps() }
            if model.cleanupCandidates.isEmpty && !model.isScanningCleanup { model.scanCleanup() }
        }
        .sheet(isPresented: $showHolding) { HoldingListView() }
        .confirmationDialog("Dùng ổ này làm Kho?", isPresented: Binding(presenting: $pendingAdopt),
                            presenting: pendingAdopt) { v in
            Button("Dùng \(v.name) làm Kho") { model.adopt(v) }
            Button("Thôi", role: .cancel) {}
        } message: { v in
            Text("Switch Kho ghi một dấu nhận vào \(v.name)/SwitchKho/.kho-id. Chỉ ổ có dấu này mới nhận dữ liệu được cất.")
        }
        .confirmationDialog("Ổ này có sổ cái sao lưu", isPresented: Binding(presenting: $askRestore),
                            presenting: askRestore) { v in
            Button("Khôi phục sổ cái từ ổ này") { Task { await model.restoreLedger(from: v) } }
            Button("Không, dùng làm Kho mới") {
                // Let this dialog finish closing before the next one opens.
                DispatchQueue.main.async { pendingAdopt = v }
            }
            Button("Thôi", role: .cancel) {}
        } message: { _ in
            Text("Ổ này đã từng làm Kho. Khôi phục sổ cái để thấy lại mọi thứ đã cất (Switch Kho sẽ thoát, hãy mở lại).")
        }
    }

    // MARK: Alerts

    @ViewBuilder
    private var alerts: some View {
        let liveProblems = model.liveIssues.values.contains { $0.contains { $0 != .ok && $0 != .khoMissing } }
        if model.guardNotice != nil || liveProblems {
            Card {
                if let notice = model.guardNotice {
                    HStack {
                        StatusLabel(notice, systemImage: "hand.raised.fill", tint: .red)
                        Spacer()
                        Button("Đã hiểu") { model.guardNotice = nil }
                    }
                }
                if liveProblems {
                    HStack {
                        StatusLabel("Một app chạy từ Kho có liên kết cần xử lý", systemImage: "exclamationmark.triangle.fill")
                        Spacer()
                        Button("Xem") { model.section = .live }
                    }
                }
            }
        }
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        if let v = model.internalVolume {
            let used = max(0, v.total - v.availableForImportant)
            let fraction = v.total > 0 ? Double(used) / Double(v.total) : 0
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 32) {
                    Figure(value: ByteFormat.string(v.availableForImportant), caption: "còn trống trên máy",
                           tint: fraction > 0.9 ? .orange : .primary)
                    if let k = model.khoVolume {
                        Figure(value: ByteFormat.string(k.available), caption: "còn trống trên Kho")
                    }
                    if model.holdingBytes > 0 {
                        Figure(value: ByteFormat.string(model.holdingBytes), caption: "trong vùng chờ")
                    }
                    Spacer()
                }
                ProgressView(value: fraction)
                    .tint(fraction > 0.9 ? .orange : .brand)
                    .accessibilityLabel("Ổ trong máy")
                    .accessibilityValue("Đã dùng \(Int(fraction * 100)) phần trăm")
                Text("Đã dùng \(ByteFormat.string(used)) trên \(ByteFormat.string(v.total)) · \(Int(fraction * 100))%")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 6)
        } else {
            Text("Không đọc được ổ trong").foregroundStyle(.secondary)
        }
    }

    // MARK: Suggestions

    private struct Suggestion: Identifiable {
        let id: String
        let title: String
        let detail: String
        let bytes: Int64
        let systemImage: String
        let go: SidebarSection
    }

    private var suggestionItems: [Suggestion] {
        var out: [Suggestion] = []
        let cleanable = model.safeCleanupCandidates
        let cleanBytes = model.safeCleanupBytes
        if cleanBytes > 0 {
            out.append(Suggestion(id: "cleanup", title: "Dọn cache và rác", detail: "\(cleanable.count) nhóm xoá an toàn, app tự tạo lại",
                                  bytes: cleanBytes, systemImage: "trash", go: .cleanup))
        }
        let cutoff = Date().addingTimeInterval(-Double(Self.idleAppDays) * 86_400)
        let idle = (model.appDataMap?.footprints ?? []).filter {
            !$0.app.isAppStore && ($0.app.lastUsed?.date ?? .distantPast) < cutoff
        }
        let idleBytes = idle.reduce(Int64(0)) { $0 + $1.total }
        if idleBytes > 0 {
            out.append(Suggestion(id: "apps", title: "Cất app ít dùng vào Kho",
                                  detail: "\(idle.count) app không mở trong \(Self.idleAppDays) ngày",
                                  bytes: idleBytes, systemImage: "shippingbox", go: .apps))
        }
        let staleBytes = model.staleList.reduce(Int64(0)) { $0 + $1.size }
        if staleBytes > 0 {
            out.append(Suggestion(id: "files", title: "Cất file lâu không dùng",
                                  detail: "\(model.staleList.count) file không mở trong \(model.staleDays) ngày",
                                  bytes: staleBytes, systemImage: "doc.on.doc", go: .analyzer))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    @ViewBuilder
    private var suggestions: some View {
        let items = suggestionItems
        Card(title: "Gợi ý giải phóng",
             footer: items.isEmpty ? nil : "Cất vào Kho luôn qua vùng chờ \(model.holdDays) ngày, hoàn tác được.") {
            if items.isEmpty {
                if model.isScanningApps || model.isScanningCleanup {
                    // Same height as two suggestions, so the page does not jump when they arrive.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Đang tìm chỗ có thể giải phóng… (khoảng nửa phút)").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                } else {
                    Text("Chưa tìm thấy gì đáng giải phóng. Bấm Quét để đo lại.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(items) { s in
                    Button { model.section = s.go } label: {
                        HStack(spacing: 12) {
                            Image(systemName: s.systemImage)
                                .font(.title3).foregroundStyle(Color.brand)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title)
                                Text(s.detail).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteFormat.string(s.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Mở màn \(s.go.title)")
                    if s.id != items.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: Kho

    @ViewBuilder
    private var khoSection: some View {
        Card(title: "Kho") {
            if model.savedKhoUUID == nil {
                Text("Chọn ổ ngoài dùng làm Kho. Switch Kho không tự chọn.").foregroundStyle(.secondary)
                if model.externalVolumes.isEmpty {
                    StatusLabel("Chưa thấy ổ ngoài nào. Hãy cắm ổ Kho.", systemImage: "externaldrive.badge.questionmark",
                                tint: .secondary)
                }
                ForEach(model.externalVolumes) { v in volumeRow(v) }
            } else if let v = model.khoVolume {
                StatusLabel("Đang cắm · \(v.name)", systemImage: "externaldrive.fill.badge.checkmark", tint: .green)
                CapacityBar(label: "Kho \(v.name)", total: v.total, free: v.available)
            } else {
                StatusLabel("Kho chưa cắm — vẫn tìm được trong Danh mục", systemImage: "externaldrive.badge.xmark",
                            tint: .secondary)
            }
            if let problem = model.khoProblem {
                StatusLabel(problem, systemImage: "exclamationmark.triangle.fill")
            }
            if model.offerLedgerRestore {
                StatusLabel("Bản sao lưu sổ cái trên Kho có nhiều thao tác hơn sổ cái trong máy. Switch Kho không ghi đè nó.",
                            systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    private func volumeRow(_ v: VolumeInfo) -> some View {
        HStack {
            Image(systemName: "externaldrive").foregroundStyle(.secondary)
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
            Button("Dùng làm Kho") {
                if model.volumeHasLedgerBackup(v) && model.ledgerIsEmpty {
                    askRestore = v
                } else {
                    pendingAdopt = v
                }
            }
            .disabled(!v.isAPFS)
        }
    }

    // MARK: Holding

    private var holdingSection: some View {
        Card(title: "Vùng chờ") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.holdingRows.count) lần cất · \(ByteFormat.string(model.holdingBytes))").monospacedDigit()
                    Text("Bản gốc được giữ \(model.holdDays) ngày rồi mới xoá; hoàn tác được trong thời gian đó.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Xem vùng chờ…") { model.refreshOperations(); showHolding = true }
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
    }

    // MARK: Environment

    @ViewBuilder
    private var environmentSection: some View {
        if !model.hasFullDiskAccess || (model.hasTimeMachine == false && !hideNoBackupNotice) {
            Card(title: "Hệ thống") {
                if !model.hasFullDiskAccess {
                    HStack {
                        StatusLabel("Chưa có Full Disk Access nên một số thư mục không đọc được.", systemImage: "lock.shield")
                        Spacer()
                        Button("Mở Cài đặt") { model.openPrivacySettings("Privacy_AllFiles") }
                        Button("Kiểm lại") { model.checkEnvironment() }
                    }
                }
                if model.hasTimeMachine == false && !hideNoBackupNotice {
                    HStack {
                        StatusLabel("Không có sao lưu Time Machine — sau vùng chờ, dữ liệu chỉ còn một bản trên Kho.",
                                    systemImage: "clock.badge.exclamationmark", tint: .secondary)
                        Spacer()
                        Button("Đã biết, ẩn đi") { hideNoBackupNotice = true }
                    }
                }
            }
        }
    }
}
