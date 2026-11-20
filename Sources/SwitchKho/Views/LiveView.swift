import AppKit
import KhoCore
import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var confirmBack: LedgerOperation?
    @State private var loginEnabled = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !loginEnabled {
                HStack {
                    StatusLabel("Người gác chỉ hoạt động khi Switch Kho đang chạy — hãy bật mở cùng máy",
                                systemImage: "exclamationmark.shield.fill")
                    Spacer()
                    if LoginItem.needsApproval {
                        Button("Mở Cài đặt Mục đăng nhập") { LoginItem.openSettings() }
                    } else {
                        Button("Bật mở cùng máy") {
                            do { try LoginItem.setEnabled(true) } catch { model.lastError = error.localizedDescription }
                            loginEnabled = LoginItem.isEnabled
                        }
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if let notice = model.guardNotice {
                HStack {
                    StatusLabel(notice, systemImage: "hand.raised.fill", tint: .red)
                    Spacer()
                    Button("Đã hiểu") { model.guardNotice = nil }
                }
            }
            liveList
        }
        .pageLayout()
        .navigationTitle("Chạy từ Kho")
        .navigationSubtitle("Chỉ mở được khi Kho cắm · luôn tháo Kho bằng Switch Kho")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Thêm app", systemImage: "plus") }
                    .disabled(model.kho == nil)
                    .help(model.kho == nil ? "Cắm Kho trước" : "Chọn một app để chạy dữ liệu của nó từ Kho")
            }
        }
        .onAppear {
            loginEnabled = LoginItem.isEnabled
            model.refreshOperations()
            model.liveGuard?.reloadLiveApps()
            model.checkLiveIntegrity()
            if model.appDataMap == nil && !model.isScanningApps { model.scanApps() }
            if model.liveSelection != nil { adding = true }
        }
        .sheet(isPresented: $adding, onDismiss: { model.liveSelection = nil }) { AddLiveSheet() }
        .confirmationDialog("Đưa dữ liệu về máy?", isPresented: Binding(presenting: $confirmBack),
                            presenting: confirmBack) { op in
            Button("Đưa về máy") { model.bringBackLive(op) }
            Button("Thôi", role: .cancel) {}
        } message: { _ in
            Text("Bản hiện tại trên Kho được chép về chỗ cũ; liên kết được thay bằng thư mục thật.")
        }
    }

    private var operations: [LedgerOperation] { model.liveGuard?.liveOperations() ?? [] }

    /// Copies kept from while the Kho was away, now only on the Kho.
    private var keptCopies: [LedgerOperation] {
        ((try? model.ledger.operations(states: [.committed, .restoring])) ?? []).filter { op in
            op.kind == .appLive && ((try? model.ledger.items(op.id)) ?? []).contains { $0.role == .setAside }
        }
    }

    @ViewBuilder
    private var liveList: some View {
        let ops = operations
        if ops.isEmpty {
            ContentUnavailableView {
                Label("Chưa có app nào chạy từ Kho", systemImage: "externaldrive.connected.to.line.below")
            } description: {
                Text("Dữ liệu Application Support của app được dời lên Kho, chỗ cũ là một liên kết. App vẫn chạy bình thường khi Kho đang cắm.")
            } actions: {
                Button("Thêm app…") { adding = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.kho == nil)
            }
            .fillCentered()
        } else {
            List {
                ForEach(ops, id: \.id) { op in row(op) }
                if !keptCopies.isEmpty {
                    Section("Bản tạo khi Kho vắng (trên Kho)") {
                        ForEach(keptCopies, id: \.id) { op in
                            HStack {
                                Text(op.title ?? "#\(op.id)")
                                Spacer()
                                Button("Lấy về cạnh chỗ cũ") { model.bringBackLive(op) }
                                    .disabled(model.kho == nil || model.busyOps.contains(op.id))
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ op: LedgerOperation) -> some View {
        let statuses = model.liveIssues[op.id] ?? []
        let summary = LiveIntegrity.summary(statuses)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(op.title ?? "#\(op.id)").font(.headline)
                Spacer()
                statusLabel(summary)
                if model.busyOps.contains(op.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Đưa về máy") { confirmBack = op }
                        .disabled(model.kho == nil || model.kho?.uuid != op.khoUUID)
                        .help(model.kho == nil ? "Cắm Kho và thoát app trước" : "")
                }
            }
            if let error = op.error { StatusLabel(error, systemImage: "xmark.octagon.fill", tint: .red) }
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                fixRow(op, status)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusLabel(_ s: LiveStatus) -> some View {
        switch s {
        case .ok: StatusLabel("Bình thường", systemImage: "checkmark.circle.fill", tint: .green)
        case .khoMissing: StatusLabel("Kho chưa cắm — app sẽ bị tắt nếu mở", systemImage: "externaldrive.badge.xmark", tint: .secondary)
        case .symlinkMissing: StatusLabel("Mất liên kết", systemImage: "link.badge.plus")
        case .symlinkReplaced: StatusLabel("Có bản tạo khi Kho vắng", systemImage: "exclamationmark.triangle.fill")
        case .targetMissing: StatusLabel("Dữ liệu trên Kho không còn", systemImage: "xmark.octagon.fill", tint: .red)
        }
    }

    @ViewBuilder
    private func fixRow(_ op: LedgerOperation, _ status: LiveStatus) -> some View {
        let canFix = model.kho != nil && !model.busyOps.contains(op.id)
        switch status {
        case .symlinkReplaced(let url):
            HStack {
                Text(url.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Giữ bản trên Kho") { model.keepCopyMadeWhileAway(op, folder: url) }.disabled(!canFix)
                    .help("Chép thư mục này lên Kho rồi nối lại liên kết; không mất gì")
                Button("Mở trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        case .symlinkMissing(let url):
            HStack {
                Text(url.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Tạo lại liên kết") { model.relinkLive(op, original: url) }.disabled(!canFix)
            }
        case .targetMissing(let url):
            HStack {
                Text("Dữ liệu trên Kho không còn — kiểm tra Kho").font(.callout)
                Spacer()
                Button("Mở Kho trong Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
                }
            }
        case .ok, .khoMissing:
            EmptyView()
        }
    }
}

/// Pick an app and the folders to run from the Kho.
private struct AddLiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bundleID: String?
    @State private var chosen: Set<String> = []

    private var candidates: [AppFootprint] {
        (model.appDataMap?.footprints ?? []).filter { !LiveRelocator.eligibleFolders($0).isEmpty }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chạy app từ Kho").font(.headline)
            if model.appDataMap == nil {
                ProgressView("Đang quét app…")
            }
            Picker("Ứng dụng", selection: $bundleID) {
                Text("Chọn app").tag(String?.none)
                ForEach(candidates) { fp in Text(fp.app.name).tag(Optional(fp.app.bundleID)) }
            }
            if let fp = model.footprint(bundleID) {
                let e = model.liveEligibility(fp)
                ForEach(e.blockers, id: \.self) { StatusLabel($0, systemImage: "xmark.octagon.fill", tint: .red) }
                List(LiveRelocator.eligibleFolders(fp)) { folder in
                    Toggle(isOn: Binding(get: { chosen.contains(folder.id) },
                                         set: { if $0 { chosen.insert(folder.id) } else { chosen.remove(folder.id) } })) {
                        HStack {
                            Text(folder.url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Text(ByteFormat.string(folder.allocated)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 140)
                let folders = LiveRelocator.eligibleFolders(fp).filter { chosen.contains($0.id) }
                Text("Giải phóng khoảng \(ByteFormat.string(folders.reduce(0) { $0 + $1.allocated })) sau \(model.holdDays) ngày trong vùng chờ.")
                    .monospacedDigit().foregroundStyle(.secondary)
                StatusLabel("Không mở được khi Kho chưa cắm; luôn tháo Kho bằng nút Eject của Switch Kho.",
                            systemImage: "exclamationmark.triangle.fill")
                HStack {
                    Spacer()
                    Button("Thôi") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Chạy từ Kho") {
                        model.relocateLive(fp, folders: folders)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!e.allowed || folders.isEmpty || model.kho == nil)
                }
            } else {
                Spacer()
                HStack { Spacer(); Button("Thôi") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(20)
        .frame(width: 540, height: 480)
        .onAppear { select(model.liveSelection) }
        .onChange(of: bundleID) { select(bundleID) }
    }

    private func select(_ id: String?) {
        bundleID = id
        chosen = Set((model.footprint(id).map(LiveRelocator.eligibleFolders) ?? []).map(\.id))
    }
}
