import AppKit
import KhoCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var confirm: [CleanupCandidate]?

    private var candidates: [CleanupCandidate] { model.visibleCleanupCandidates }
    private var selectedCandidates: [CleanupCandidate] {
        candidates.filter { selected.contains($0.id) && !$0.manualOnly }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if candidates.isEmpty {
                if model.isScanningCleanup {
                    ProgressView("Đang tìm…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        model.cleanupCandidates.isEmpty ? "Chưa quét" : "Không có gì để dọn cho app này",
                        systemImage: "sparkles",
                        description: Text("Bấm Quét để tìm cache và rác có thể xoá an toàn."))
                }
            } else {
                List {
                    ForEach(candidates) { c in row(c) }
                }
            }
        }
        .padding(20)
        .navigationTitle("Dọn dẹp")
        .onAppear { if model.cleanupCandidates.isEmpty && !model.isScanningCleanup { model.scanCleanup() } }
        .sheet(item: Binding(get: { confirm.map(ConfirmBox.init) }, set: { if $0 == nil { confirm = nil } })) { box in
            confirmSheet(box.items)
        }
    }

    private var toolbar: some View {
        HStack {
            Button(model.cleanupCandidates.isEmpty ? "Quét" : "Quét lại") { model.scanCleanup() }
                .disabled(model.isScanningCleanup)
            if let filter = model.cleanupFilter {
                Label(appName(filter), systemImage: "line.3.horizontal.decrease.circle")
                    .font(.callout)
                Button("Bỏ lọc") { model.cleanupFilter = nil }.buttonStyle(.link)
            }
            Spacer()
            let total = candidates.reduce(Int64(0)) { $0 + $1.estimatedBytes }
            Text("Ước tính: \(ByteFormat.string(total))").monospacedDigit().foregroundStyle(.secondary)
            Button("Dọn \(selectedCandidates.count) mục đã chọn") { confirm = selectedCandidates }
                .disabled(selectedCandidates.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func row(_ c: CleanupCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if c.manualOnly {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                        .help("Chỉ dọn từng mục, không chọn hàng loạt")
                        .accessibilityLabel("Chỉ dọn từng mục")
                } else {
                    Toggle(isOn: Binding(get: { selected.contains(c.id) },
                                         set: { if $0 { selected.insert(c.id) } else { selected.remove(c.id) } })) {
                        EmptyView()
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Chọn \(c.title)")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.headline)
                    Text(c.detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(c.estimatedBytes > 0 ? ByteFormat.string(c.estimatedBytes) : "—")
                    .monospacedDigit()
                if case .command(_, _, .some) = c.method {
                    Button("Xem trước") { model.previewCleanup(c) }
                }
                if model.cleanupRunning.contains(c.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Dọn") { confirm = [c] }
                }
            }
            HStack(spacing: 12) {
                if let req = model.requirementText(c.requirement) {
                    StatusLabel(req, systemImage: "app.badge.checkmark", tint: .blue)
                }
                if let warning = c.warning {
                    StatusLabel(warning, systemImage: "exclamationmark.triangle.fill")
                }
            }
            if !c.paths.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(get: { expanded.contains(c.id) },
                                        set: { if $0 { expanded.insert(c.id) } else { expanded.remove(c.id) } })) {
                    ForEach(c.paths.prefix(200), id: \.self) { url in
                        Text(url.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .help(url.path)
                            .contextMenu {
                                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                    }
                    if c.paths.count > 200 { Text("… và \(c.paths.count - 200) mục khác").font(.caption) }
                } label: {
                    Text("\(c.paths.count) đường dẫn").font(.callout)
                }
            }
            if let preview = model.cleanupPreviews[c.id] {
                ScrollView {
                    Text(preview).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)
    }

    private func confirmSheet(_ items: [CleanupCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1 ? "Dọn \(items[0].title)?" : "Dọn \(items.count) nhóm?").font(.headline)
            Text("Cache được xoá hẳn (app tự tạo lại). File cài đặt cũ và node_modules được đưa vào Thùng rác.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(items) { c in
                    Section(c.title) {
                        if let warning = c.warning {
                            StatusLabel(warning, systemImage: "exclamationmark.triangle.fill")
                        }
                        switch c.method {
                        case .paths(let urls, let deletion):
                            Text(deletion == .trash ? "Đưa vào Thùng rác:" : "Xoá hẳn:").font(.callout)
                            ForEach(urls.prefix(50), id: \.self) {
                                Text($0.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            }
                            if urls.count > 50 { Text("… và \(urls.count - 50) mục khác").font(.caption) }
                        case .command(let exe, let args, _):
                            Text("Chạy: \(exe.lastPathComponent) \(args.joined(separator: " "))")
                                .font(.caption.monospaced())
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Thôi") { confirm = nil }.keyboardShortcut(.cancelAction)
                Button("Dọn", role: .destructive) {
                    model.runCleanup(items)
                    selected.subtract(items.map(\.id))
                    confirm = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
    }

    private func appName(_ bundleID: String) -> String {
        model.appDataMap?.footprints.first { $0.app.bundleID == bundleID }?.app.name ?? bundleID
    }
}

/// Identifiable wrapper so a list of candidates can drive a sheet.
private struct ConfirmBox: Identifiable {
    let items: [CleanupCandidate]
    var id: String { items.map(\.id).joined(separator: "|") }
}
