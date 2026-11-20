import AppKit
import KhoCore
import SwiftUI

struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var rule: OffloadRule
    @State private var extText = ""
    @State private var candidates: [RuleCandidate]?
    @State private var chosen: Set<RuleCandidate.ID> = []
    @State private var previewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quy tắc").font(.headline)
            Form {
                TextField("Tên", text: $rule.name)
                LabeledContent("Thư mục") {
                    HStack {
                        Text((rule.folderPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Chọn…") { chooseFolder() }
                    }
                }
                Stepper("Không dùng ít nhất \(rule.minDaysUnused) ngày", value: $rule.minDaysUnused, in: 7...3650, step: 7)
                Stepper("Lớn ít nhất \(rule.minSizeMB) MB", value: $rule.minSizeMB, in: 0...100_000, step: 10)
                TextField("Đuôi file (phân tách bằng dấu phẩy, để trống = mọi loại)", text: $extText,
                          prompt: Text("dmg, zip, pkg"))
                Picker("Chế độ", selection: $rule.mode) {
                    Text("Gợi ý").tag(RuleMode.suggest)
                    Text("Tự động (mỗi 6 giờ khi Kho cắm)").tag(RuleMode.auto)
                }
                Toggle("Để lại liên kết ở chỗ cũ", isOn: $rule.leaveSymlink)
            }
            .formStyle(.grouped)
            if rule.mode == .auto {
                StatusLabel("Khi thiếu ngày mở, ngày sửa được dùng thay — file chỉ đọc bằng công cụ dòng lệnh có thể bị chọn nhầm. Hãy Xem trước.",
                            systemImage: "exclamationmark.triangle.fill")
            }
            preview
            HStack {
                Button("Xem trước") { runPreview() }.disabled(previewing)
                Spacer()
                Button("Thôi") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu") {
                    model.saveRule(normalized)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 640)
        .onAppear { extText = rule.extensions.joined(separator: ", ") }
    }

    private var normalized: OffloadRule {
        var r = rule
        r.extensions = extText.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
        return r
    }

    @ViewBuilder
    private var preview: some View {
        if previewing {
            ProgressView("Đang xét các mục…").frame(maxWidth: .infinity)
        } else if let candidates {
            if candidates.isEmpty {
                Text("Không có mục nào khớp quy tắc.").foregroundStyle(.secondary)
            } else {
                Table(candidates) {
                    TableColumn("") { c in
                        Toggle("", isOn: Binding(get: { chosen.contains(c.id) },
                                                 set: { if $0 { chosen.insert(c.id) } else { chosen.remove(c.id) } }))
                            .labelsHidden()
                            .accessibilityLabel("Chọn \(c.url.lastPathComponent)")
                    }
                    .width(24)
                    TableColumn("Tên") { c in
                        Label(c.url.lastPathComponent, systemImage: c.isDirectory ? "folder" : "doc").lineLimit(1)
                    }
                    TableColumn("Cỡ") { c in Text(ByteFormat.string(c.allocated)).monospacedDigit() }.width(80)
                    TableColumn("Dùng lần cuối") { c in Text(c.usage.date.vi(date: .numeric, time: .omitted)) }
                        .width(100)
                    TableColumn("Nguồn ngày") { c in Text(sourceName(c.usage.source)).foregroundStyle(.secondary) }
                        .width(110)
                }
                .frame(minHeight: 160)
                let picked = candidates.filter { chosen.contains($0.id) }
                HStack {
                    Text("Đã chọn \(picked.count) mục · \(ByteFormat.string(picked.reduce(0) { $0 + $1.allocated }))")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Cất các mục đã chọn") {
                        model.offloadPersonal(picked.map(\.url), leaveSymlink: rule.leaveSymlink)
                        dismiss()
                    }
                    .disabled(picked.isEmpty || model.kho == nil)
                    .help(model.kho == nil ? "Cắm Kho trước" : "")
                }
            }
        }
    }

    private func sourceName(_ s: UsageSource) -> String {
        switch s {
        case .lastUsedXattr: return "Ngày mở (Finder)"
        case .spotlight: return "Spotlight"
        case .modified: return "Ngày sửa"
        case .added: return "Ngày thêm"
        }
    }

    private func runPreview() {
        previewing = true
        let r = normalized
        Task {
            let found = await model.ruleCandidates(r)
            candidates = found
            chosen = Set(found.map(\.id))
            previewing = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: rule.folderPath)
        if panel.runModal() == .OK, let url = panel.url { rule.folderPath = url.path }
    }
}
