import AppKit
import KhoCore
import SwiftUI

struct FileRow: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let lastUsed: Date?

    /// One folder's direct children, folders first. Read off the main thread.
    static func list(_ dir: URL) async -> [FileRow] {
        await Task.detached {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                          .contentModificationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return urls.compactMap { url -> FileRow? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                let isDir = (v.isDirectory ?? false) && !(v.isSymbolicLink ?? false)
                return FileRow(url: url, isDirectory: isDir, size: Int64(v.totalFileAllocatedSize ?? 0),
                               modified: v.contentModificationDate, lastUsed: FileUsage.lastUsedXattr(url))
            }
            .sorted { a, b in
                a.isDirectory != b.isDirectory ? a.isDirectory
                    : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
        }.value
    }
}

/// A folder listing with back/up navigation, multi-select, open on double-click and drag/drop.
struct FilePane: View {
    @Environment(AppModel.self) private var model
    let title: String
    @Binding var folder: URL
    @Binding var selection: Set<FileRow.ID>
    /// Called with dropped file URLs.
    var onDrop: ([URL]) -> Void
    @State private var rows: [FileRow] = []
    @State private var history: [URL] = []

    var selectedURLs: [URL] { rows.filter { selection.contains($0.id) }.map(\.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Button { goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(history.isEmpty).help("Lùi").accessibilityLabel("Lùi")
                Button { go(folder.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }
                    .disabled(folder.path == "/").help("Lên thư mục cha").accessibilityLabel("Lên thư mục cha")
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Table(rows, selection: $selection) {
                TableColumn("Tên") { r in
                    Label(r.url.lastPathComponent, systemImage: r.isDirectory ? "folder" : "doc")
                        .lineLimit(1)
                        .draggable(r.url)
                }
                TableColumn("Cỡ") { r in
                    Text(r.isDirectory ? "—" : ByteFormat.string(r.size)).monospacedDigit()
                }
                .width(70)
                TableColumn("Ngày sửa") { r in Text(r.modified.map(Self.date) ?? "—") }.width(85)
                TableColumn("Dùng lần cuối") { r in Text(r.lastUsed.map(Self.date) ?? "—") }.width(85)
            }
            .contextMenu(forSelectionType: FileRow.ID.self) { ids in
                let urls = rows.filter { ids.contains($0.id) }.map(\.url)
                Button("Mở") { urls.forEach { NSWorkspace.shared.open($0) } }
                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                Button("Xem nhanh") { quickLook(urls) }
            } primaryAction: { ids in
                guard let row = rows.first(where: { ids.contains($0.id) }) else { return }
                if row.isDirectory { go(row.url) } else { NSWorkspace.shared.open(row.url) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let foreign = urls.filter { !FileOps.same($0.deletingLastPathComponent(), folder) }
                guard !foreign.isEmpty else { return false }
                onDrop(foreign)
                return true
            }
        }
        .task(id: "\(folder.path)-\(model.filesGeneration)-\(model.operationsGeneration)") {
            rows = await FileRow.list(folder)
            selection = selection.filter { id in rows.contains { $0.id == id } }
        }
    }

    static func date(_ d: Date) -> String { d.formatted(date: .numeric, time: .omitted) }

    private func go(_ url: URL) {
        history.append(folder)
        folder = url
        selection = []
    }

    private func goBack() {
        guard let last = history.popLast() else { return }
        folder = last
        selection = []
    }

    private func quickLook(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            _ = try? await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), ["-p"] + urls.map(\.path),
                                             timeout: 600)
        }
    }
}
