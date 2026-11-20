import AppKit
import KhoCore
import SwiftUI

struct AnalyzerView: View {
    enum Tab: String, CaseIterable { case apps = "Theo ứng dụng", folders = "Theo thư mục" }

    @Environment(AppModel.self) private var model
    @State private var tab = Tab.apps
    @State private var assigning: AppDataFolder?
    @State private var assignTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
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
            Button("Quét") { model.scanApps() }
            Group {
                Button("Dọn cache") {}
                Button("Cất cả app") {}
                Button("Chạy từ Kho") {}
            }
            .disabled(true)
            .help("Có ở bản sau")
            Text("Có ở bản sau").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu("Thêm") {
                if NSEvent.modifierFlags.contains(.option) {
                    Button("Xuất ngân sách…") { model.exportBudget() }
                }
                Button("Quét lại") { model.scanApps() }
            }
            .frame(maxWidth: 100)
        }
        if let map = model.appDataMap {
            AppFootprintTable(map: map)
            if map.unreadable > 0 {
                Text("\(map.unreadable) thư mục không đọc được (cần Full Disk Access?)")
                    .font(.caption).foregroundStyle(.orange)
            }
            GroupBox("Không rõ app (\(map.unassigned.count))") {
                List(map.unassigned) { f in
                    HStack {
                        Text("\(f.area.rawValue)/\(f.url.lastPathComponent)")
                        if f.hasVMImage { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        Spacer()
                        Text(ByteFormat.string(f.allocated)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contextMenu { Button("Gán cho ứng dụng…") { assignTo = ""; assigning = f } }
                }
                .frame(minHeight: 160)
            }
        } else {
            ContentUnavailableView("Chưa quét", systemImage: "app.dashed",
                                   description: Text("Bấm Quét để đo dung lượng của từng ứng dụng."))
        }
    }

    private func assignSheet(_ folder: AppDataFolder) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gán \(folder.url.lastPathComponent) cho ứng dụng").font(.headline)
            Picker("Ứng dụng", selection: $assignTo) {
                Text("Chọn…").tag("")
                ForEach(model.appDataMap?.footprints.map(\.app) ?? []) { app in
                    Text(app.name).tag(app.bundleID)
                }
            }
            HStack {
                Spacer()
                Button("Thôi") { assigning = nil }
                Button("Gán") {
                    model.assign(folder, to: assignTo)
                    assigning = nil
                }
                .disabled(assignTo.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
