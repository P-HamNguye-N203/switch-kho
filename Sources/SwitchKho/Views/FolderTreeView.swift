import AppKit
import KhoCore
import SwiftUI

struct FolderTreeView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<ScanNode.ID> = []

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Chọn thư mục…") { choose() }
                Button("Quét thư mục nhà") { model.scanFolder(FileManager.default.homeDirectoryForCurrentUser) }
                if model.isScanningFolder {
                    ProgressView().controlSize(.small)
                    Text("Đang quét…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("Lâu không dùng: \(model.staleDays) ngày", value: $model.staleDays, in: 30...1000, step: 30)
                    .monospacedDigit()
                    .frame(maxWidth: 260)
            }
            .disabled(model.isScanningFolder)
            if let scan = model.folderScan {
                let current = model.folderPath.last ?? scan.root
                breadcrumb(scan.root)
                HSplitView {
                    List(current.children, selection: $selection) { node in
                        HStack {
                            Image(systemName: node.isDirectory ? "folder" : "doc")
                            Text(node.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(ByteFormat.string(node.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu(forSelectionType: ScanNode.ID.self) { ids in
                        Button("Hiện trong Finder") { reveal(ids, in: current) }
                        offloadButtons(current.children.filter { ids.contains($0.id) }.map(\.url))
                    } primaryAction: { ids in
                        // Double-click or Return opens a folder.
                        if let node = current.children.first(where: { ids.contains($0.id) && $0.isDirectory }) {
                            model.folderPath.append(node)
                            selection = []
                        }
                    }
                    .frame(minWidth: 320)
                    VStack(alignment: .leading) {
                        Text("Lớn nhất").font(.headline)
                        List(scan.largestFiles.prefix(50)) { f in fileRow(f.url, f.size) }
                        Text("Lâu không dùng (\(model.staleDays) ngày)").font(.headline)
                        if model.staleList.isEmpty {
                            Text("Không có file từ 10 MB trở lên lâu không dùng.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                        } else {
                            List(model.staleList.prefix(50)) { f in fileRow(f.url, f.size) }
                        }
                    }
                    .frame(minWidth: 280)
                }
                if scan.unreadable > 0 {
                    StatusLabel("\(scan.unreadable) mục không đọc được (cần Full Disk Access?)",
                                systemImage: "lock.fill")
                }
            } else {
                ContentUnavailableView("Chưa quét", systemImage: "folder.badge.questionmark",
                                       description: Text("Chọn một thư mục để xem dung lượng theo cây."))
                    .fillCentered()
            }
        }
    }

    private func breadcrumb(_ root: ScanNode) -> some View {
        HStack(spacing: 4) {
            Button(root.name) { model.folderPath = [] }.buttonStyle(.link)
            ForEach(Array(model.folderPath.enumerated()), id: \.element.id) { i, node in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button(node.name) { model.folderPath = Array(model.folderPath.prefix(i + 1)) }.buttonStyle(.link)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Đường dẫn")
    }

    private func fileRow(_ url: URL, _ size: Int64) -> some View {
        HStack {
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(ByteFormat.string(size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .help(url.path)
        .contextMenu {
            Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            offloadButtons([url])
        }
    }

    @ViewBuilder
    private func offloadButtons(_ urls: [URL]) -> some View {
        Divider()
        Button("Cất vào Kho") { model.offloadPersonal(urls) }
            .disabled(urls.isEmpty || model.kho == nil)
        Button("Cất vào Kho, để lại liên kết") { model.offloadPersonal(urls, leaveSymlink: true) }
            .disabled(urls.isEmpty || model.kho == nil)
    }

    private func reveal(_ ids: Set<ScanNode.ID>, in node: ScanNode) {
        let urls = node.children.filter { ids.contains($0.id) }.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { model.scanFolder(url) }
    }
}
