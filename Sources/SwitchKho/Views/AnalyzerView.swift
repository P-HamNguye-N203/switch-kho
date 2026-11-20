import AppKit
import KhoCore
import SwiftUI

struct AnalyzerView: View {
    enum Tab: String, CaseIterable { case apps = "Theo ứng dụng", folders = "Theo thư mục" }

    @Environment(AppModel.self) private var model
    @SceneStorage("analyzer.tab") private var tab = Tab.apps
    @State private var assigning: AppDataFolder?
    @State private var assignTo = ""
    @State private var tableSelection: FootprintRow.ID?

    private var selectedApp: InstalledApp? {
        model.appDataMap?.footprints.first { $0.app.id == tableSelection }?.app
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Cách xem", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            switch tab {
            case .apps: appsTab
            case .folders: FolderTreeView()
            }
        }
        .padding(20)
        .navigationTitle("Phân tích")
        .sheet(item: $assigning) { folder in assignSheet(folder) }
    }

    @ViewBuilder
    private var appsTab: some View {
        HStack {
            Button(model.appDataMap == nil ? "Quét" : "Quét lại") { model.scanApps() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isScanningApps)
            if model.isScanningApps {
                ProgressView().controlSize(.small)
                Text("Đang quét…").font(.callout).foregroundStyle(.secondary)
            }
            Button("Kiểm lại app đang chạy") { model.refreshRunning() }
                .disabled(model.appDataMap == nil)
            Spacer()
            Button(selectedApp.map { "Dọn cache của \($0.name)" } ?? "Dọn cache") {
                model.showCleanup(for: selectedApp?.bundleID)
            }
            .help("Mở màn Dọn dẹp, lọc theo app đang chọn trong bảng")
            Button(selectedApp.map { "Cất \($0.name)…" } ?? "Cất cả app") {
                model.showApps(select: selectedApp?.bundleID)
            }
            .help("Mở màn Ứng dụng với app đang chọn")
            Button(selectedApp.map { "Chạy \($0.name) từ Kho…" } ?? "Chạy từ Kho") {
                model.showLive(select: selectedApp?.bundleID)
            }
            .help("Dời dữ liệu Application Support của app lên Kho, chỗ cũ là liên kết")
        }
        if let map = model.appDataMap {
            AppFootprintTable(map: map, selection: $tableSelection)
            if map.unreadable > 0 {
                StatusLabel("\(map.unreadable) thư mục không đọc được (cần Full Disk Access?)", systemImage: "lock.fill")
            }
            GroupBox("Không rõ app (\(map.unassigned.count))") {
                List(map.unassigned) { f in
                    HStack {
                        Text("\(f.area.rawValue)/\(f.url.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                        if f.hasVMImage { VMImageBadge() }
                        Spacer()
                        Text(ByteFormat.string(f.allocated)).monospacedDigit().foregroundStyle(.secondary)
                        Button("Gán…") { assignTo = ""; assigning = f }
                            .buttonStyle(.borderless)
                            .help("Gán thư mục này cho một ứng dụng")
                    }
                    .help(f.url.path)
                    .contextMenu { Button("Gán cho ứng dụng…") { assignTo = ""; assigning = f } }
                }
                .frame(minHeight: 160)
            }
        } else {
            ContentUnavailableView("Chưa quét", systemImage: "app.dashed",
                                   description: Text("Bấm Quét (⌘R) để đo dung lượng của từng ứng dụng."))
        }
    }

    private func assignSheet(_ folder: AppDataFolder) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gán \(folder.url.lastPathComponent) cho ứng dụng").font(.headline)
            Text(folder.url.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Picker("Ứng dụng", selection: $assignTo) {
                Text("Chọn…").tag("")
                ForEach(model.appDataMap?.footprints.map(\.app) ?? []) { app in
                    Text(app.name).tag(app.bundleID)
                }
            }
            HStack {
                Spacer()
                Button("Thôi") { assigning = nil }.keyboardShortcut(.cancelAction)
                Button("Gán") {
                    model.assign(folder, to: assignTo)
                    assigning = nil
                }
                .disabled(assignTo.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
