import KhoCore
import SwiftUI

/// Bottom of the window: error banner, success notice, then the running job.
struct BottomStatusArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.lastError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Ẩn") { model.lastError = nil }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.orange.opacity(0.12))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
            }
            if let notice = model.notice {
                StatusLabel(notice, systemImage: "checkmark.circle.fill", tint: .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(.bar)
                    .transition(.opacity)
            }
            JobStatusBar()
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .animation(.easeOut(duration: 0.2), value: model.lastError)
    }
}

struct JobStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let job = model.runningJob {
            HStack(spacing: 12) {
                if job.fraction > 0 {
                    ProgressView(value: job.fraction).frame(width: 180)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.callout)
                    if !job.detail.isEmpty {
                        Text(job.detail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                let queued = model.jobs.filter { $0.state == .queued }.count
                if queued > 0 { Text("còn \(queued) việc chờ").font(.callout).foregroundStyle(.secondary) }
                Button("Huỷ") { model.cancelRunningJob() }
                    .disabled(!job.cancellable)
                    .help(job.cancellable ? "Dừng việc đang chạy"
                          : "Việc này không huỷ giữa chừng được để giữ an toàn dữ liệu")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Việc đang chạy: \(job.title)")
        }
    }
}
