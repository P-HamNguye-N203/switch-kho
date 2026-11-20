import AppKit
import KhoCore
import SwiftUI

struct FolderTreeView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [ScanNode] = []
    @State private var selection: ScanNode.ID?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Chọn thư mục…") { choose() }
                Button("Quét thư mục nhà") { model.scanFolder(FileManager.default.homeDirectoryForCurrentUser) }
                Spacer()
                Stepper("Lâu không dùng: \(model.staleDays) ngày", value: $model.staleDays, in: 30...1000, step: 30)
                    .frame(maxWidth: 260)
            }
            if let scan = model.folderScan {
                let current = path.last ?? scan.root
                breadcrumb(scan.root)
                HSplitView {
                    List(current.children, selection: $selection) { node in
                        HStack {
                            Image(systemName: node.isDirectory ? "folder" : "doc")
                            Text(node.name)
                            Spacer()
                            Text(ByteFormat.string(node.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if node.isDirectory { path.append(node) } }
                        .contextMenu { Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) } }
                    }
                    .frame(minWidth: 320)
                    VStack(alignment: .leading) {
                        Text("Lớn nhất").font(.headline)
                        List(scan.largestFiles.prefix(50)) { f in
                            fileRow(f.url, f.size)
                        }
                        Text("Lâu không dùng (\(model.staleDays) ngày)").font(.headline)
                        List(model.staleFiles().prefix(50)) { f in
                            fileRow(f.url, f.size)
                        }
                    }
                    .frame(minWidth: 280)
                }
                if scan.unreadable > 0 {
                    Text("\(scan.unreadable) mục không đọc được (cần Full Disk Access?)")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                ContentUnavailableView("Chưa quét", systemImage: "folder.badge.questionmark",
                                       description: Text("Chọn một thư mục để xem dung lượng theo cây."))
            }
        }
        .onChange(of: model.folderScan?.root.url) { path = [] }
    }

    private func breadcrumb(_ root: ScanNode) -> some View {
        HStack(spacing: 4) {
            Button(root.name) { path = [] }.buttonStyle(.link)
            ForEach(Array(path.enumerated()), id: \.element.id) { i, node in
                Text("›").foregroundStyle(.secondary)
                Button(node.name) { path = Array(path.prefix(i + 1)) }.buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    private func fileRow(_ url: URL, _ size: Int64) -> some View {
        HStack {
            Text(url.lastPathComponent).lineLimit(1)
            Spacer()
            Text(ByteFormat.string(size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .help(url.path)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { model.scanFolder(url) }
    }
}
