import AppKit
import KhoCore
import SwiftUI

struct AppsView: View {
    enum Tab: String, CaseIterable { case local = "Trên máy", kho = "Trong kho" }

    @Environment(AppModel.self) private var model
    @SceneStorage("apps.tab") private var tab = Tab.local
    @State private var confirmArchive: AppFootprint?
    @State private var confirmUndo: LedgerOperation?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Picker("Cách xem", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            switch tab {
            case .local: localTab
            case .kho: khoTab
            }
        }
        .padding(20)
        .navigationTitle("Ứng dụng")
        .onAppear {
            if model.appDataMap == nil && !model.isScanningApps { model.scanApps() }
            model.refreshOperations()
        }
        .onChange(of: model.appsSelection) {
            if let fp = model.footprint(model.appsSelection) { model.checkEligibility(fp) }
        }
        .sheet(item: $confirmArchive) { fp in archiveSheet(fp) }
        .confirmationDialog("Hoàn tác cất app?", isPresented: Binding(presenting: $confirmUndo),
                            presenting: confirmUndo) { op in
            Button("Hoàn tác") { model.restoreApp(op) }
            Button("Thôi", role: .cancel) {}
        } message: { _ in
            Text("App và dữ liệu được trả về chỗ cũ từ vùng chờ.")
        }
    }

    // MARK: On this Mac

    private var footprints: [AppFootprint] {
        (model.appDataMap?.footprints ?? []).sorted {
            ($0.app.lastUsed?.date ?? .distantPast) < ($1.app.lastUsed?.date ?? .distantPast)
        }
    }

    @ViewBuilder
    private var localTab: some View {
        @Bindable var model = model
        HStack {
            Button(model.appDataMap == nil ? "Quét" : "Quét lại") { model.scanApps() }
                .disabled(model.isScanningApps)
            if model.isScanningApps { ProgressView().controlSize(.small) }
            Spacer()
            if model.kho == nil {
                StatusLabel("Cắm Kho để cất app", systemImage: "externaldrive.badge.xmark", tint: .secondary)
            }
        }
        HSplitView {
            Table(footprints, selection: Binding(
                get: { model.appsSelection.flatMap { id in footprints.first { $0.app.bundleID == id }?.id } },
                set: { id in model.appsSelection = footprints.first { $0.id == id }?.app.bundleID })) {
                TableColumn("Ứng dụng") { fp in Text(fp.app.name).lineLimit(1) }
                    .width(min: 140, ideal: 200)
                TableColumn("Nguồn") { fp in Text(source(fp.app)).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90)
                TableColumn("Tổng") { fp in BytesText(bytes: fp.total) }.width(min: 70, ideal: 90)
                TableColumn("Dùng lần cuối") { fp in
                    if let d = fp.app.lastUsed?.date {
                        Text(d.formatted(date: .abbreviated, time: .omitted)).monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 90, ideal: 110)
            }
            .frame(minWidth: 420)
            detailPane.frame(minWidth: 280)
        }
    }

    private func source(_ app: InstalledApp) -> String {
        if app.isAppStore { return "App Store" }
        if app.isAdobe { return "Adobe" }
        if app.hasSparkle { return "Sparkle" }
        return "Thường"
    }

    @ViewBuilder
    private var detailPane: some View {
        if let fp = model.footprint(model.appsSelection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(fp.app.name).font(.title3.bold())
                    Text("Bundle \(ByteFormat.string(fp.bundleAllocated)) · dữ liệu \(ByteFormat.string(fp.dataAllocated))")
                        .monospacedDigit().foregroundStyle(.secondary)
                    if let e = model.eligibility[fp.app.bundleID] {
                        ForEach(e.blockers, id: \.self) { StatusLabel($0, systemImage: "xmark.octagon.fill", tint: .red) }
                        ForEach(e.warnings, id: \.self) { StatusLabel($0, systemImage: "exclamationmark.triangle.fill") }
                        if fp.hasVMImage {
                            StatusLabel("Có ảnh đĩa máy ảo: chỉ cất lạnh, không chạy từ Kho được", systemImage: "shippingbox.fill")
                        }
                        Button("Cất vào kho…") { confirmArchive = fp }
                            .disabled(!e.allowed || model.kho == nil)
                            .help(model.kho == nil ? "Cắm Kho trước" : e.allowed ? "" : "Xem lý do chặn ở trên")
                    } else {
                        ProgressView("Đang kiểm điều kiện…").controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        } else {
            ContentUnavailableView("Chọn một app", systemImage: "app.dashed",
                                   description: Text("App ít dùng nhất nằm trên cùng."))
        }
    }

    private func archiveSheet(_ fp: AppFootprint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cất \(fp.app.name) vào Kho?").font(.headline)
            Text("App và dữ liệu được chép có xác minh lên Kho, rồi bản gốc vào vùng chờ \(model.holdDays) ngày. Muốn dùng lại thì bấm \"Lấy về\".")
                .font(.callout).foregroundStyle(.secondary)
            List {
                row(fp.app.url, fp.bundleAllocated)
                ForEach(fp.folders) { row($0.url, $0.allocated) }
            }
            .frame(minHeight: 180)
            ForEach(model.eligibility[fp.app.bundleID]?.warnings ?? [], id: \.self) {
                StatusLabel($0, systemImage: "exclamationmark.triangle.fill")
            }
            HStack {
                Spacer()
                Button("Thôi") { confirmArchive = nil }.keyboardShortcut(.cancelAction)
                Button("Cất vào kho") {
                    model.archiveApp(fp)
                    confirmArchive = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    private func row(_ url: URL, _ bytes: Int64) -> some View {
        HStack {
            Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).help(url.path)
            Spacer()
            Text(ByteFormat.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: In the Kho

    @ViewBuilder
    private var khoTab: some View {
        if model.archivedApps.isEmpty {
            ContentUnavailableView("Chưa cất app nào", systemImage: "archivebox",
                                   description: Text("App đã cất vào Kho sẽ hiện ở đây."))
        } else {
            List(model.archivedApps, id: \.id) { op in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(op.title ?? "#\(op.id)").font(.headline)
                        Text(statusText(op)).font(.callout).foregroundStyle(.secondary)
                        if let error = op.error { StatusLabel(error, systemImage: "xmark.octagon.fill", tint: .red) }
                    }
                    Spacer()
                    if model.busyOps.contains(op.id) {
                        ProgressView().controlSize(.small)
                    } else if op.state == .holding {
                        Button("Hoàn tác") { confirmUndo = op }
                    } else if op.state == .committed || op.state == .restoring {
                        Button("Lấy về") { model.restoreApp(op) }
                            .disabled(model.kho == nil || model.kho?.uuid != op.khoUUID)
                            .help(model.kho == nil ? "Cắm Kho để lấy về" : "")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func statusText(_ op: LedgerOperation) -> String {
        switch op.state {
        case .holding:
            let until = op.holdingUntil?.formatted(date: .abbreviated, time: .omitted) ?? "?"
            return "Trong vùng chờ tới \(until), hoàn tác được"
        case .committed: return "Chỉ còn trên Kho"
        case .restoring, .undoing: return "Đang đưa về dở, bấm để thử lại"
        default: return op.state.rawValue
        }
    }
}
