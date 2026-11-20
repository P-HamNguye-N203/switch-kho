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
            if candidates.isEmpty {
                if model.isScanningCleanup {
                    ProgressView("Đang tìm cache và rác…").fillCentered()
                } else {
                    ContentUnavailableView(
                        model.cleanupCandidates.isEmpty ? "Chưa quét" : "Không có gì để dọn cho app này",
                        systemImage: "trash",
                        description: Text("Bấm Quét để tìm cache và rác có thể xoá an toàn."))
                        .fillCentered()
                }
            } else {
                header
                List {
                    ForEach(candidates) { c in row(c) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .pageLayout()
        .navigationTitle("Dọn dẹp")
        .navigationSubtitle(candidates.isEmpty ? "" : "Có thể giải phóng khoảng \(ByteFormat.string(candidates.reduce(Int64(0)) { $0 + $1.estimatedBytes }))")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.scanCleanup() } label: { Label("Quét", systemImage: "arrow.clockwise") }
                    .help("Tìm lại cache và rác (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanningCleanup)
            }
        }
        .onAppear { if model.cleanupCandidates.isEmpty && !model.isScanningCleanup { model.scanCleanup() } }
        .sheet(item: Binding(get: { confirm.map(ConfirmBox.init) }, set: { if $0 == nil { confirm = nil } })) { box in
            confirmSheet(box.items)
        }
    }

    /// Selection summary and the one primary action of the screen.
    private var header: some View {
        let selectable = candidates.filter { !$0.manualOnly }
        let chosenBytes = selectedCandidates.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { !selectable.isEmpty && selectable.allSatisfy { selected.contains($0.id) } },
                                 set: { on in
                                     if on { selected.formUnion(selectable.map(\.id)) } else { selected.subtract(selectable.map(\.id)) }
                                 })) {
                Text("Chọn tất cả")
            }
            .toggleStyle(.checkbox)
            if let filter = model.cleanupFilter {
                Label("Chỉ \(appName(filter))", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.brand)
                Button("Bỏ lọc") { model.cleanupFilter = nil }.buttonStyle(.link)
            }
            Spacer()
            if selectedCandidates.isEmpty {
                Text("Chọn nhóm cần dọn").foregroundStyle(.secondary)
            } else {
                Text("\(selectedCandidates.count) nhóm · \(ByteFormat.string(chosenBytes))").monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Dọn…") { confirm = selectedCandidates }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
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
