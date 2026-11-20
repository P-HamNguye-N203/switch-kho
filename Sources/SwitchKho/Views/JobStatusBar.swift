import KhoCore
import SwiftUI

struct JobStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let job = model.runningJob {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.callout)
                    if !job.detail.isEmpty {
                        Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ProgressView(value: job.fraction).frame(maxWidth: 220)
                Spacer()
                let queued = model.jobs.filter { $0.state == .queued }.count
                if queued > 0 { Text("\(queued) việc chờ").font(.caption).foregroundStyle(.secondary) }
                Button("Huỷ") { model.cancelRunningJob() }
                    .disabled(!job.cancellable)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
