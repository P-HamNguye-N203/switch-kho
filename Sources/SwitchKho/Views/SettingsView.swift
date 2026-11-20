import KhoCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var holdDays = 7
    @State private var leaveSymlink = false
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var chosenVolume: String?
    @State private var confirmChange: VolumeInfo?
    @State private var confirmRestore: VolumeInfo?

    private var chosen: VolumeInfo? { model.externalVolumes.first { $0.id == chosenVolume } }

    var body: some View {
        Form {
            Section("Vùng chờ") {
                Stepper("Giữ bản gốc \(holdDays) ngày trước khi xoá", value: $holdDays, in: 1...30)
                    .onChange(of: holdDays) { model.holdDays = holdDays }
                Toggle("Để lại liên kết ở chỗ cũ khi cất file cá nhân", isOn: $leaveSymlink)
                    .onChange(of: leaveSymlink) { model.leaveSymlinkByDefault = leaveSymlink }
            }
            Section("Kho") {
                Picker("Ổ", selection: $chosenVolume) {
                    Text("Chọn ổ").tag(String?.none)
                    ForEach(model.externalVolumes) { v in
                        Text(v.uuid == model.savedKhoUUID ? "\(v.name) (Kho hiện tại)" : v.name).tag(Optional(v.id))
                    }
                }
                HStack {
                    let busy = !(model.liveGuard?.liveApps.isEmpty ?? true)
                        || model.jobs.contains { $0.state == .running || $0.state == .queued }
                    Button("Dùng ổ này làm Kho") { confirmChange = chosen }
                        .disabled(chosen == nil || chosen?.uuid == model.savedKhoUUID || busy)
                        .help(busy ? "Hãy đưa các app chạy từ Kho về máy và chờ các công việc xong trước khi đổi Kho" : "")
                    Button("Khôi phục sổ cái từ Kho") { confirmRestore = chosen ?? model.khoVolume }
                        .disabled(!((chosen ?? model.khoVolume).map(model.canRestoreLedger) ?? false))
                        .help("Chỉ dùng được khi sổ cái trong máy chưa có thao tác nào và ổ có bản sao lưu")
                }
            }
            Section("Hệ thống") {
                Toggle("Mở cùng macOS", isOn: Binding(get: { loginEnabled }, set: { on in
                    do { try LoginItem.setEnabled(on) } catch { model.lastError = error.localizedDescription }
                    loginEnabled = LoginItem.isEnabled
                }))
                .disabled(!model.usesDefaultDataDir)
                if LoginItem.needsApproval {
                    Button("Mở Cài đặt Mục đăng nhập") { LoginItem.openSettings() }
                }
                Button("Mở cài đặt Full Disk Access") { model.openPrivacySettings("Privacy_AllFiles") }
                Button("Mở cài đặt App Management") { model.openPrivacySettings("Privacy_AppBundles") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .onAppear {
            holdDays = model.holdDays
            leaveSymlink = model.leaveSymlinkByDefault
            loginEnabled = LoginItem.isEnabled
            chosenVolume = model.khoVolume?.id
        }
        .confirmationDialog("Đổi Kho?", isPresented: Binding(presenting: $confirmChange),
                            presenting: confirmChange) { v in
            Button("Dùng \(v.name) làm Kho") { model.adopt(v) }
            Button("Thôi", role: .cancel) {}
        } message: { _ in
            Text("Các thao tác cũ vẫn gắn với Kho cũ: muốn lấy về hay xoá vùng chờ của chúng thì phải cắm lại Kho cũ.")
        }
        .confirmationDialog("Khôi phục sổ cái từ Kho?", isPresented: Binding(presenting: $confirmRestore),
                            presenting: confirmRestore) { v in
            Button("Khôi phục rồi thoát") { Task { await model.restoreLedger(from: v) } }
            Button("Thôi", role: .cancel) {}
        } message: { _ in
            Text("Các thao tác chưa xong sẽ được đánh dấu cần kiểm. Switch Kho sẽ thoát; hãy mở lại sau đó.")
        }
    }
}
