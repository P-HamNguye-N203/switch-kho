import AppKit
import KhoCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var confirm: [CleanupCandidate]?
    @State private var showSmall = false

    private var filtered: [CleanupCandidate] {
        let all = model.visibleCleanupCandidates
        return showSmall ? all : all.filter { $0.estimatedBytes >= AppModel.smallCleanupBytes }
    }
    private var safe: [CleanupCandidate] {
        filtered.filter { !$0.manualOnly }.sorted { $0.estimatedBytes > $1.estimatedBytes }
    }
    private var review: [CleanupCandidate] {
        filtered.filter(\.manualOnly).sorted { $0.estimatedBytes > $1.estimatedBytes }
    }
    private var hiddenSmall: Int {
        model.visibleCleanupCandidates.filter { $0.estimatedBytes < AppModel.smallCleanupBytes }.count
    }
    private var selectedCandidates: [CleanupCandidate] { safe.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.visibleCleanupCandidates.isEmpty {
                if model.isScanningCleanup {
                    ProgressView("Đang tìm cache và rác…").fillCentered()
                } else {
                    ContentUnavailableView {
                        Label(model.cleanupCandidates.isEmpty ? "Chưa quét" : "Không có gì để dọn cho app này",
                              systemImage: "trash")
                    } description: {
                        Text("Tìm cache và rác có thể xoá an toàn.")
                    } actions: {
                        Button("Quét ngay") { model.scanCleanup() }.buttonStyle(.borderedProminent)
                    }
                    .fillCentered()
                }
            } else {
                header
                List {
                    if !safe.isEmpty {
                        Section {
                            ForEach(safe) { c in row(c) }
                        } header: {
                            Text("Xoá an toàn · \(ByteFormat.string(safe.reduce(0) { $0 + $1.estimatedBytes }))")
                        } footer: {
                            Text("Cache được app tự tạo lại khi cần. File cài đặt cũ và node_modules vào Thùng rác.")
                        }
                    }
                    if !review.isEmpty {
                        Section {
                            ForEach(review) { c in row(c) }
                        } header: {
                            Text("Cần xem kỹ · không rõ app nào dùng")
                        } footer: {
                            Text("Dọn từng mục một, sau khi chắc không còn app nào cần.")
                        }
                    }
                    if hiddenSmall > 0 || showSmall {
                        Button(showSmall ? "Ẩn các nhóm dưới 1 MB" : "Hiện thêm \(hiddenSmall) nhóm nhỏ dưới 1 MB") {
                            showSmall.toggle()
                        }
                        .buttonStyle(.link)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .pageLayout()
        .navigationTitle("Dọn dẹp")
        .navigationSubtitle(model.safeCleanupBytes > 0 && model.cleanupFilter == nil
                            ? "Có thể giải phóng an toàn khoảng \(ByteFormat.string(model.safeCleanupBytes))" : "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.scanCleanup() } label: { Label("Quét lại", systemImage: "arrow.clockwise") }
                    .labelStyle(.titleAndIcon)
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
        let chosenBytes = selectedCandidates.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { !safe.isEmpty && safe.allSatisfy { selected.contains($0.id) } },
                                 set: { on in
                                     if on { selected.formUnion(safe.map(\.id)) } else { selected.subtract(safe.map(\.id)) }
                                 })) {
                Text("Chọn tất cả nhóm an toàn")
            }
            .toggleStyle(.checkbox)
            .disabled(safe.isEmpty)
            if let filter = model.cleanupFilter {
                Label("Chỉ \(appName(filter))", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.brand)
                Button("Bỏ lọc") { model.cleanupFilter = nil }.buttonStyle(.link)
            }
            Spacer()
            if selectedCandidates.isEmpty {
                Text("Đánh dấu các nhóm muốn dọn").foregroundStyle(.secondary)
            } else {
                Text("Đã chọn \(selectedCandidates.count) nhóm · \(ByteFormat.string(chosenBytes))").monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Dọn…") { confirm = selectedCandidates }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// True when the app this group belongs to has to be quit first and is open right now.
    private func blockedByRunningApp(_ c: CleanupCandidate) -> Bool {
        guard case .mustBeQuit(let app) = c.requirement else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL.map { FileOps.same($0, app) } ?? false }
    }

    @ViewBuilder
    private func row(_ c: CleanupCandidate) -> some View {
        let running = blockedByRunningApp(c)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                if c.manualOnly {
                    Image(systemName: "questionmark.folder").foregroundStyle(.secondary).frame(width: 16)
                        .accessibilityHidden(true)
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
                    Text(c.title)
                    HStack(spacing: 6) {
                        Text(c.paths.count == 1 ? (c.paths[0].path as NSString).abbreviatingWithTildeInPath : c.detail)
                            .lineLimit(1).truncationMode(.middle)
                        if running, let req = model.requirementText(c.requirement) {
                            Text("·")
                            // Informational: cleaning simply waits for the app to be quit.
                            Label("đang mở, " + req.lowercased(), systemImage: "app.badge.clock")
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    if let warning = c.warning, !c.manualOnly {
                        StatusLabel(warning, systemImage: "exclamationmark.triangle.fill").font(.callout)
                    }
                }
                Spacer(minLength: 12)
                Text(c.estimatedBytes > 0 ? ByteFormat.string(c.estimatedBytes) : "—")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
                if case .command(_, _, .some) = c.method {
                    Button("Xem trước") { model.previewCleanup(c) }
                }
                if model.cleanupRunning.contains(c.id) {
                    ProgressView().controlSize(.small)
                } else if c.manualOnly {
                    Button("Dọn…") { confirm = [c] }
                }
            }
            if c.paths.count > 1 {
                DisclosureGroup(
                    isExpanded: Binding(get: { expanded.contains(c.id) },
                                        set: { if $0 { expanded.insert(c.id) } else { expanded.remove(c.id) } })) {
                    ForEach(c.paths.prefix(200), id: \.self) { url in
                        Text((url.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .help(url.path)
                            .contextMenu {
                                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                    }
                    if c.paths.count > 200 { Text("… và \(c.paths.count - 200) mục khác").font(.caption) }
                } label: {
                    Text("Xem \(c.paths.count) vị trí").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
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
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            if !c.paths.isEmpty {
                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting(c.paths) }
            }
            Button("Dọn riêng nhóm này…") { confirm = [c] }
        }
        .help(c.paths.count == 1 ? c.paths[0].path : c.detail)
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
