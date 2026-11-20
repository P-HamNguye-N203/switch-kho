import AppKit
import SwiftUI

@main
struct SwitchKhoApp: App {
    @State private var model = AppModel.launch()

    var body: some Scene {
        WindowGroup(id: "main") {
            NavigationSplitView {
                List(SidebarSection.allCases, selection: $model.section) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            } detail: {
                detail(model.section ?? .overview)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { BottomStatusArea() }
            .environment(model)
        }
        .commands {
            CommandGroup(after: .importExport) {
                Button("Xuất ngân sách dung lượng…") { model.exportBudget() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
            }
        }

        MenuBarExtra("Switch Kho", systemImage: "externaldrive.fill") {
            MenuBarContent()
                .environment(model)
        }
    }

    @ViewBuilder
    private func detail(_ section: SidebarSection) -> some View {
        switch section {
        case .overview: DashboardView()
        case .analyzer: AnalyzerView()
        case .cleanup: CleanupView()
        case .apps: AppsView()
        case .live: LiveView()
        default:
            ContentUnavailableView(section.title, systemImage: section.systemImage,
                                   description: Text("Có ở bản sau"))
        }
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.guardNotice {
            Text(notice)
            Divider()
        }
        if model.kho != nil {
            Button("Tháo Kho an toàn") { model.eject() }
            Divider()
        }
        Button("Mở Switch Kho") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Thoát") {
            NSApp.terminate(nil)
        }
    }
}
