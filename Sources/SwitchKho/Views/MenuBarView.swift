import AppKit
import KhoCore
import SwiftUI

/// Quick status and controls while the window is closed.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = model.guardNotice {
                StatusLabel(notice, systemImage: "hand.raised.fill", tint: .red)
            }
            row("Kho", systemImage: model.kho == nil ? "externaldrive" : "externaldrive.fill",
                value: model.khoVolume.map { "\(ByteFormat.string($0.available)) trống" } ?? "Chưa cắm")
            row("Máy", systemImage: "internaldrive",
                value: model.internalVolume.map { "\(ByteFormat.string($0.availableForImportant)) trống" } ?? "—")
            let waiting = model.holdingRows.filter(\.overdue).count
            row("Vùng chờ", systemImage: "tray.full",
                value: ByteFormat.string(model.holdingBytes) + (waiting > 0 ? " · \(waiting) chờ cắm Kho để xoá" : ""))
            if let ops = model.liveGuard?.liveOperations(), !ops.isEmpty {
                Divider()
                Text("Chạy từ Kho").font(.caption).foregroundStyle(.secondary)
                ForEach(ops, id: \.id) { op in
                    let ok = LiveIntegrity.summary(model.liveIssues[op.id] ?? []) == .ok
                    Label(op.title ?? "#\(op.id)", systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? Color.green : Color.orange)
                }
            }
            if let job = model.runningJob {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title).lineLimit(1)
                    ProgressView(value: job.fraction)
                    Text("\(Int(job.fraction * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Divider()
            TextField("Tìm trong Kho", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    model.catalogQuery = query
                    model.section = .catalog
                    openMain()
                }
            HStack {
                Button("Tháo Kho an toàn") { model.eject() }
                    .disabled(model.kho == nil || model.isEjecting)
                Spacer()
                Button("Mở Switch Kho") { openMain() }
            }
            Button("Thoát Switch Kho") { NSApp.terminate(nil) }
                .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ title: String, systemImage: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

extension AppModel {
    /// Menu bar symbol: a problem with live data beats everything else.
    var menuBarSymbol: String {
        if liveIssues.values.contains(where: { LiveIntegrity.summary($0) != .ok && LiveIntegrity.summary($0) != .khoMissing }) {
            return "exclamationmark.triangle"
        }
        return kho == nil ? "externaldrive" : "externaldrive.fill"
    }
}
