import AppKit
import KhoCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var errorsOnly = false
    @State private var entries: [ActivityRow] = []

    struct ActivityRow: Identifiable {
        let id: Int
        let entry: ActivityEntry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Chỉ lỗi", isOn: $errorsOnly).toggleStyle(.checkbox)
                Spacer()
                Button("Làm mới") { reload() }
                Button("Hiện file DB trong Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.ledgerURL])
                }
            }
            let shown = errorsOnly ? entries.filter { !$0.entry.ok } : entries
            if shown.isEmpty {
                ContentUnavailableView(errorsOnly ? "Không có lỗi" : "Chưa có hoạt động", systemImage: "list.bullet.rectangle")
            } else {
                Table(shown) {
                    TableColumn("Thời gian") { r in
                        Text(r.entry.at.formatted(date: .numeric, time: .shortened)).monospacedDigit()
                    }
                    .width(130)
                    TableColumn("Thao tác") { r in Text(r.entry.action).lineLimit(1) }
                    TableColumn("Đường dẫn") { r in
                        Text(r.entry.path ?? "").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            .help(r.entry.path ?? "")
                    }
                    TableColumn("Chi tiết") { r in
                        Text(r.entry.detail ?? "").lineLimit(1).truncationMode(.tail).help(r.entry.detail ?? "")
                    }
                    TableColumn("Kết quả") { r in
                        if r.entry.ok {
                            Label("Xong", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Lỗi", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                    .width(70)
                }
                .textSelection(.enabled)
            }
        }
        .padding(20)
        .navigationTitle("Nhật ký")
        .onAppear { reload() }
        .onChange(of: model.operationsGeneration) { reload() }
    }

    private func reload() {
        let list = (try? model.ledger.recentActivity(limit: 1000)) ?? []
        entries = list.enumerated().map { ActivityRow(id: $0.offset, entry: $0.element) }
    }
}
