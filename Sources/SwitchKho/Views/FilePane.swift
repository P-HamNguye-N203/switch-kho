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

/// Total allocated size of a folder, cancellable; `nil` when cancelled.
private func folderSize(_ url: URL, isCancelled: () -> Bool) -> Int64? {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                 options: [], errorHandler: { _, _ in true }) else { return 0 }
    var total: Int64 = 0
    var n = 0
    for case let f as URL in e {
        n += 1
        if n % 2000 == 0 && isCancelled() { return nil }
        total += Int64((try? f.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
    }
    return total
}

/// Folds case, accents and "đ" so "hoa don" finds "Hoá đơn".
private func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
}

/// Items under `root` whose folded name contains `needle`. Hands out the hits so far every
/// quarter second, so results appear while a big tree is still being walked. Skips
/// `~/Library` and `node_modules`: slow to walk and rarely what someone is looking for.
private func searchTree(_ root: URL, needle: String, limit: Int, isCancelled: () -> Bool,
                        onBatch: ([FileRow]) -> Void) {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                  .contentModificationDateKey]
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                 errorHandler: { _, _ in true }) else { onBatch([]); return }
    let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
    var out: [FileRow] = []
    var n = 0
    var lastSent = Date()
    for case let url as URL in e {
        n += 1
        if out.count >= limit || (n % 500 == 0 && isCancelled()) { break }
        let name = url.lastPathComponent
        if name == "node_modules" || url.path == library {
            e.skipDescendants()
            continue
        }
        if fold(name).contains(needle), let v = try? url.resourceValues(forKeys: Set(keys)) {
            let isDir = (v.isDirectory ?? false) && !(v.isSymbolicLink ?? false)
            out.append(FileRow(url: url, isDirectory: isDir, size: Int64(v.totalFileAllocatedSize ?? 0),
                               modified: v.contentModificationDate, lastUsed: nil))
        }
        if Date().timeIntervalSince(lastSent) > 0.25 {
            onBatch(out)
            lastSent = Date()
        }
    }
    onBatch(out)
}

/// A folder listing with back/up navigation, folder sizes, search, multi-select,
/// open on double-click and drag/drop.
struct FilePane: View {
    @Environment(AppModel.self) private var model
    let title: String
    @Binding var folder: URL
    @Binding var selection: Set<FileRow.ID>
    /// Called with dropped file URLs.
    var onDrop: ([URL]) -> Void
    @State private var rows: [FileRow] = []
    @State private var history: [URL] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var query = ""
    @State private var found: [FileRow]?
    @State private var searching = false

    /// What the table shows: the folder, or search hits from the folder and everything below it.
    private var shown: [FileRow] { query.count >= 2 ? (found ?? []) : rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: title == "Kho" ? "externaldrive.fill" : "laptopcomputer")
                    .font(.headline).foregroundStyle(title == "Kho" ? Color.brand : .primary)
                Button { goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(history.isEmpty).help("Lùi").accessibilityLabel("Lùi")
                Button { go(folder.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }
                    .disabled(folder.path == "/").help("Lên thư mục cha").accessibilityLabel("Lên thư mục cha")
                Spacer()
            }
            breadcrumb
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tìm theo tên trong \(folder.path == FileManager.default.homeDirectoryForCurrentUser.path ? "Nhà" : folder.lastPathComponent) và thư mục con", text: $query)
                    .textFieldStyle(.plain)
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Xoá ô tìm")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            Table(of: FileRow.self, selection: $selection) {
                TableColumn("Tên") { r in
                    Label {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.url.lastPathComponent).lineLimit(1)
                            if query.count >= 2 {
                                Text(relative(r.url.deletingLastPathComponent()))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    } icon: {
                        Image(systemName: r.isDirectory ? "folder.fill" : "doc").foregroundStyle(r.isDirectory ? Color.accentColor : .secondary)
                    }
                    .help(r.url.path)
                }
                TableColumn("Cỡ") { r in sizeText(r) }.width(80)
                TableColumn("Ngày sửa") { r in Text(r.modified.map(Self.date) ?? "—") }.width(85)
                TableColumn("Dùng lần cuối") { r in Text(r.lastUsed.map(Self.date) ?? "—") }.width(85)
            } rows: {
                ForEach(shown) { r in
                    TableRow(r).draggable(r.url)
                }
            }
            .contextMenu(forSelectionType: FileRow.ID.self) { ids in
                let picked = shown.filter { ids.contains($0.id) }
                if let dir = picked.first, picked.count == 1, dir.isDirectory {
                    Button("Mở thư mục") { go(dir.url) }
                }
                Button("Mở bằng app mặc định") { picked.forEach { NSWorkspace.shared.open($0.url) } }
                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url)) }
                Button("Xem nhanh") { quickLook(picked.map(\.url)) }
            } primaryAction: { ids in
                guard let row = shown.first(where: { ids.contains($0.id) }) else { return }
                if row.isDirectory { go(row.url) } else { NSWorkspace.shared.open(row.url) }
            }
            .overlay {
                if shown.isEmpty && !searching {
                    Text(query.count >= 2 ? "Không tìm thấy \"\(query)\"" : "Thư mục trống — kéo file vào đây")
                        .foregroundStyle(.secondary)
                }
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
            await measureFolders(rows.filter(\.isDirectory).map(\.url))
        }
        .task(id: "\(folder.path)|\(query)") { await search() }
    }

    // MARK: Pieces

    /// Each folder from the root of this pane to here, clickable.
    private var breadcrumb: some View {
        let parts = folder.pathComponents
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, name in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    let url = URL(fileURLWithPath: NSString.path(withComponents: Array(parts[0...i])))
                    Button(i == 0 ? "Ổ đĩa" : (url.path == FileManager.default.homeDirectoryForCurrentUser.path ? "Nhà" : name)) {
                        if !FileOps.same(url, folder) { go(url) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(i == parts.count - 1 ? .primary : .secondary)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func sizeText(_ r: FileRow) -> some View {
        if !r.isDirectory {
            Text(ByteFormat.string(r.size)).monospacedDigit()
        } else if let s = sizes[r.url.path] {
            Text(ByteFormat.string(s)).monospacedDigit()
        } else {
            ProgressView().controlSize(.mini).accessibilityLabel("Đang tính cỡ")
        }
    }

    private func relative(_ url: URL) -> String {
        let base = folder.path
        return url.path.hasPrefix(base) ? "." + url.path.dropFirst(base.count) : url.path
    }

    // MARK: Work

    /// Sizes folders one by one off the main thread; stops when the folder changes.
    private func measureFolders(_ dirs: [URL]) async {
        for dir in dirs where sizes[dir.path] == nil {
            if Task.isCancelled { return }
            let size = await Task.detached(priority: .utility) {
                folderSize(dir, isCancelled: { Task.isCancelled })
            }.value
            if let size { sizes[dir.path] = size }
        }
    }

    /// Searches this folder and its subfolders by name, at most 500 hits, showing hits as they come.
    private func search() async {
        guard query.count >= 2 else { found = nil; searching = false; return }
        try? await Task.sleep(for: .milliseconds(250))   // let typing settle
        if Task.isCancelled { return }
        searching = true
        found = []
        defer { searching = false }
        let needle = fold(query), root = folder
        let stream = AsyncStream<[FileRow]> { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                searchTree(root, needle: needle, limit: 500, isCancelled: { Task.isCancelled },
                           onBatch: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
        for await batch in stream {
            if Task.isCancelled { return }
            found = batch
        }
        if !Task.isCancelled { await measureFolders((found ?? []).filter(\.isDirectory).map(\.url)) }
    }

    static func date(_ d: Date) -> String { d.vi(date: .numeric, time: .omitted) }

    private func go(_ url: URL) {
        history.append(folder)
        folder = url
        selection = []
        query = ""
    }

    private func goBack() {
        guard let last = history.popLast() else { return }
        folder = last
        selection = []
        query = ""
    }

    private func quickLook(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            _ = try? await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), ["-p"] + urls.map(\.path),
                                             timeout: 600)
        }
    }
}
