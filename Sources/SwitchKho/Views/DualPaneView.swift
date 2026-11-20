import KhoCore
import SwiftUI

/// This Mac on the left, the Kho on the right: offload, bring back, or copy either way.
struct DualPaneView: View {
    @Environment(AppModel.self) private var model
    @State private var leftFolder = FileManager.default.homeDirectoryForCurrentUser
    @State private var rightFolder: URL?
    @State private var leftSelection: Set<FileRow.ID> = []
    @State private var rightSelection: Set<FileRow.ID> = []
    /// The pane the last selection was made in decides the direction of "Chép".
    @State private var copyToKho = true
    @State private var confirmBack: LedgerOperation?

    private var leftURLs: [URL] { leftSelection.map { URL(fileURLWithPath: $0) } }
    private var rightURLs: [URL] { rightSelection.map { URL(fileURLWithPath: $0) } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FilePane(title: "Máy", folder: $leftFolder, selection: $leftSelection) { urls in
                bringBack(urls)
            }
            .frame(minWidth: 320)
            middle
            if let kho = model.kho {
                FilePane(title: "Kho", folder: Binding(get: { rightFolder ?? kho.layout.archive },
                                                       set: { rightFolder = $0 }),
                         selection: $rightSelection) { urls in
                    model.offloadPersonal(urls, leaveSymlink: model.leaveSymlinkByDefault)
                }
                .frame(minWidth: 320)
            } else {
                ContentUnavailableView {
                    Label("Kho chưa được cắm", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text("Danh mục vẫn tìm được các file đã nằm trên Kho.")
                } actions: {
                    Button("Mở Danh mục") { model.section = .catalog }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .navigationTitle("Hai khung")
        .onChange(of: leftSelection) { if !leftSelection.isEmpty { copyToKho = true } }
        .onChange(of: rightSelection) { if !rightSelection.isEmpty { copyToKho = false } }
        .onChange(of: model.kho?.uuid) { rightFolder = nil; rightSelection = [] }
        .confirmationDialog("Lấy về chỗ cũ?", isPresented: Binding(presenting: $confirmBack),
                            presenting: confirmBack) { op in
            Button("Lấy về") { model.bringBackPersonal(op) }
            Button("Thôi", role: .cancel) {}
        } message: { op in
            Text("Lấy về cả thao tác \"\(op.title ?? "#\(op.id)")\". Nếu chỗ cũ đã có dữ liệu mới, việc lấy về sẽ dừng.")
        }
    }

    private var middle: some View {
        VStack(spacing: 10) {
            Spacer()
            Button("Cất →") { model.offloadPersonal(leftURLs, leaveSymlink: model.leaveSymlinkByDefault) }
                .disabled(leftURLs.isEmpty || model.kho == nil)
                .help("Cất các mục chọn bên trái vào Kho (qua vùng chờ)")
            Button("← Lấy về") { bringBack(rightURLs) }
                .disabled(rightURLs.isEmpty || model.kho == nil)
                .help("Lấy về chỗ cũ những mục đã cất; mục đặt tay vào Kho chỉ chép về được")
            Button(copyToKho ? "Chép →" : "← Chép") { copy() }
                .disabled((copyToKho ? leftURLs : rightURLs).isEmpty || model.kho == nil)
                .help("Chép, không xoá bản gốc")
            Spacer()
        }
        .buttonStyle(.bordered)
        .frame(width: 110)
    }

    private func bringBack(_ urls: [URL]) {
        let ops = Set(urls.compactMap { model.archiveOperation(forKhoURL: $0) })
        if let op = ops.first, ops.count == 1 {
            confirmBack = op
        } else if ops.count > 1 {
            model.lastError = "Các mục chọn thuộc nhiều lần cất khác nhau — hãy lấy về từng lần ở Danh mục › Đã cất."
        } else {
            model.lastError = "Mục này không có trong sổ cái (có thể đặt tay vào Kho). Hãy dùng \"← Chép\" để chép về."
        }
    }

    private func copy() {
        if copyToKho {
            guard let kho = model.kho else { return }
            model.copyOnly(leftURLs, into: rightFolder ?? kho.layout.archive)
        } else {
            model.copyOnly(rightURLs, into: leftFolder)
        }
    }
}
