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
            switch tab {
            case .apps: appsTab
            case .folders: FolderTreeView()
            }
        }
        .pageLayout()
        .navigationTitle("Phân tích")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Cách xem", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if tab == .apps {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.refreshRunning() } label: { Label("Kiểm app đang chạy", systemImage: "app.badge.checkmark") }
                        .help("Kiểm lại app nào đang chạy")
                        .disabled(model.appDataMap == nil)
                    Button { model.scanApps() } label: { Label("Quét", systemImage: "arrow.clockwise") }
                        .help("Đo lại dung lượng từng ứng dụng (⌘R)")
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(model.isScanningApps)
                }
            }
        }
        .sheet(item: $assigning) { folder in assignSheet(folder) }
    }

    @ViewBuilder
    private var appsTab: some View {
        if let app = selectedApp {
            HStack(spacing: 8) {
                Text(app.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Dọn cache") { model.showCleanup(for: app.bundleID) }
                    .help("Mở màn Dọn dẹp, lọc theo app này")
                Button("Cất vào Kho…") { model.showApps(select: app.bundleID) }
                    .help("Mở màn Ứng dụng với app này")
                Button("Chạy từ Kho…") { model.showLive(select: app.bundleID) }
                    .help("Dời dữ liệu Application Support của app lên Kho, chỗ cũ là liên kết")
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        if model.appDataMap == nil && model.isScanningApps {
            ProgressView("Đang đo dung lượng từng ứng dụng…").fillCentered()
        } else if let map = model.appDataMap {
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
                .fillCentered()
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
