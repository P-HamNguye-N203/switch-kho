import KhoCore
import SwiftUI

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: OffloadRule?
    @State private var confirmDelete: OffloadRule?

    var body: some View {
        let _ = model.catalogGeneration
        let rules = model.rules
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quy tắc gợi ý hoặc tự cất các mục lâu không dùng trong một thư mục. Mọi lần cất đều qua vùng chờ \(model.holdDays) ngày.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Thêm quy tắc…") {
                    editing = OffloadRule(name: "Quy tắc mới",
                                          folderPath: FileManager.default.homeDirectoryForCurrentUser
                                              .appendingPathComponent("Downloads").path,
                                          minDaysUnused: 90, minSizeMB: 50, extensions: [], mode: .suggest,
                                          leaveSymlink: false, enabled: true)
                }
            }
            if rules.isEmpty {
                ContentUnavailableView("Chưa có quy tắc", systemImage: "wand.and.stars",
                                       description: Text("Ví dụ: cất file .dmg trong Downloads không mở quá 90 ngày."))
            } else {
                List(rules) { rule in
                    HStack {
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                            var r = rule
                            r.enabled = on
                            model.saveRule(r)
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Bật quy tắc \(rule.name)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.headline)
                            Text(summary(rule)).font(.callout).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(rule.mode == .auto ? "Tự động" : "Gợi ý")
                            .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background((rule.mode == .auto ? Color.orange : Color.secondary).opacity(0.15),
                                        in: Capsule())
                        Button("Sửa…") { editing = rule }
                        Button("Xoá", role: .destructive) { confirmDelete = rule }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .navigationTitle("Quy tắc")
        .sheet(item: $editing) { rule in RuleEditorView(rule: rule) }
        .confirmationDialog("Xoá quy tắc?", isPresented: Binding(presenting: $confirmDelete),
                            presenting: confirmDelete) { rule in
            Button("Xoá \(rule.name)", role: .destructive) { model.deleteRule(rule) }
            Button("Thôi", role: .cancel) {}
        } message: { _ in Text("Các mục đã cất trước đó không bị ảnh hưởng.") }
    }

    private func summary(_ r: OffloadRule) -> String {
        let exts = r.extensions.isEmpty ? "mọi loại" : r.extensions.map { ".\($0)" }.joined(separator: ", ")
        return "\((r.folderPath as NSString).abbreviatingWithTildeInPath) · không dùng ≥ \(r.minDaysUnused) ngày · ≥ \(r.minSizeMB) MB · \(exts)"
    }
}
