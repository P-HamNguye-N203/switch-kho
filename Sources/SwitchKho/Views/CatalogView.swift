import AppKit
import KhoCore
import SwiftUI

/// Search everything on the Kho (works with the Kho unplugged) and manage personal archives.
struct CatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = Mode.search
    @State private var query = ""
    @State private var results: [CatalogEntry] = []
    @State private var selection: Set<CatalogEntry.ID> = []
    @State private var confirmBack: LedgerOperation?
    @State private var status: (volume: IndexedVolume?, rows: Int64) = (nil, 0)

    enum Mode: String, CaseIterable { case search = "Tìm trong kho", archived = "Đã cất" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .search: searchPane
            case .archived: archivedPane
            }
        }
        .pageLayout()
        .navigationTitle("Danh mục")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Chế độ", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.indexKhoIfStale(force: true) } label: { Label("Lập chỉ mục lại", systemImage: "arrow.clockwise") }
                    .help("Đọc lại toàn bộ Kho vào danh mục")
                    .disabled(model.kho == nil)
            }
        }
        .onAppear(perform: takeQuery)
        .onChange(of: model.catalogQuery) { takeQuery() }
        .confirmationDialog("Lấy về chỗ cũ?", isPresented: Binding(presenting: $confirmBack),
                            presenting: confirmBack) { op in
            Button("Lấy về") { model.bringBackPersonal(op) }
            Button("Thôi", role: .cancel) {}
        } message: { op in
            Text(op.state == .holding
                 ? "Bản gốc trong vùng chờ được đưa về chỗ cũ; bản trên Kho bị xoá."
                 : "Bản trên Kho được chép về chỗ cũ rồi xoá khỏi Kho. Nếu chỗ cũ đã có dữ liệu mới, việc lấy về sẽ dừng.")
        }
    }

    // MARK: Search

    /// A search typed in the menu bar.
    private func takeQuery() {
        guard let q = model.catalogQuery else { return }
        model.catalogQuery = nil
        mode = .search
        query = q
    }

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchBox(prompt: "Tìm theo tên hoặc đường dẫn — không cần dấu", text: $query)
                .task(id: query) {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    let found = await model.catalogSearch(query)
                    guard !Task.isCancelled else { return }
                    results = found
                }
            if query.trimmingCharacters(in: .whitespaces).count < 2 {
                ContentUnavailableView("Tìm mọi thứ trên Kho", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Gõ ít nhất 2 ký tự. Không cần dấu, và vẫn tìm được khi Kho đã rút."))
                    .fillCentered()
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query).fillCentered()
            } else {
                Table(results, selection: $selection) {
                    TableColumn("Tên") { e in
                        Label(e.item.name, systemImage: e.item.isDirectory ? "folder" : "doc").lineLimit(1)
                    }
                    TableColumn("Đường dẫn trong Kho") { e in
                        Text(e.item.relPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                    TableColumn("Cỡ") { e in
                        Text(e.item.isDirectory ? "—" : ByteFormat.string(e.item.size)).monospacedDigit()
                    }
                    .width(80)
                    TableColumn("Sửa") { e in
                        Text(e.item.modified.map { $0.vi(date: .numeric, time: .omitted) } ?? "—")
                    }
                    .width(90)
                    TableColumn("Trạng thái") { e in
                        if model.url(for: e) != nil {
                            Text("● Trực tuyến").foregroundStyle(.green)
                        } else {
                            Text("○ Ngoại tuyến").foregroundStyle(.secondary)
                        }
                    }
                    .width(100)
                }
                .contextMenu(forSelectionType: CatalogEntry.ID.self) { ids in
                    if let entry = results.first(where: { ids.contains($0.id) }) { actions(entry) }
                } primaryAction: { ids in
                    if let entry = results.first(where: { ids.contains($0.id) }), let url = model.url(for: entry) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            footer
        }
    }

    @ViewBuilder
    private func actions(_ entry: CatalogEntry) -> some View {
        let url = model.url(for: entry)
        Button("Mở") { if let url { NSWorkspace.shared.open(url) } }.disabled(url == nil)
        Button("Hiện trong Finder") { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            .disabled(url == nil)
        if let op = model.operation(for: entry) {
            Divider()
            Button("Lấy về chỗ cũ") { confirmBack = op }
                .disabled(model.kho == nil || model.busyOps.contains(op.id))
        }
    }

    private var footer: some View {
        HStack {
            if let v = status.volume {
                Text("Lập chỉ mục lúc \(v.lastIndexed.vi(date: .abbreviated, time: .shortened)) · \(v.files) file · \(ByteFormat.string(v.bytes))")
                    .monospacedDigit()
            } else if model.kho == nil {
                Text("Kho chưa cắm — kết quả lấy từ lần lập chỉ mục trước.")
            } else if status.rows > 0 {
                Text("Danh mục chưa đầy đủ — lần lập chỉ mục trước bị dừng giữa chừng.")
            } else {
                Text("Kho chưa được lập chỉ mục.")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .task(id: "\(model.catalogGeneration)-\(model.kho?.uuid ?? "")-\(model.jobs.count)") {
            status = await model.catalogStatus()
        }
    }

    // MARK: Archived

    @ViewBuilder
    private var archivedPane: some View {
        let ops = model.personalArchives
        if ops.isEmpty {
            ContentUnavailableView("Chưa cất gì", systemImage: "archivebox",
                                   description: Text("Chuột phải một thư mục hay file trong Phân tích › Theo thư mục, hoặc dùng màn Hai khung."))
                .fillCentered()
        } else {
            List(ops, id: \.id) { op in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(op.title ?? "#\(op.id)").font(.headline)
                        Text(op.state == .holding
                             ? "Trong vùng chờ đến \(op.holdingUntil?.vi(date: .abbreviated, time: .omitted) ?? "—")"
                             : "Chỉ còn trên Kho")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busyOps.contains(op.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(op.state == .holding ? "Hoàn tác" : "Lấy về") { confirmBack = op }
                            .disabled(model.kho == nil || model.kho?.uuid != op.khoUUID)
                            .help(model.kho == nil ? "Cắm Kho trước" : "")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
