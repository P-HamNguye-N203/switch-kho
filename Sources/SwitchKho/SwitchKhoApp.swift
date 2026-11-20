import AppKit
import SwiftUI

@main
struct SwitchKhoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        // Before anything else: the self-test must not take the lock or touch the ledger.
        if SelfTest.requested { SelfTest.runAndExit() }
        _model = State(initialValue: AppModel.launch())
    }

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
            .modifier(HideWhenLaunchedAtLogin())
            .environment(model)
        }
        .commands {
            CommandGroup(after: .importExport) {
                Button("Xuất ngân sách dung lượng…") { model.exportBudget() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("Switch Kho")
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private func detail(_ section: SidebarSection) -> some View {
        switch section {
        case .overview: DashboardView()
        case .analyzer: AnalyzerView()
        case .cleanup: CleanupView()
        case .apps: AppsView()
        case .live: LiveView()
        case .files: DualPaneView()
        case .catalog: CatalogView()
        case .rules: RulesView()
        case .activity: ActivityView()
        }
    }
}

/// Opened at login, Switch Kho only needs its menu bar item; the window would be in the way.
private struct HideWhenLaunchedAtLogin: ViewModifier {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var checked = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !checked else { return }
            checked = true
            if AppDelegate.launchedAtLogin {
                AppDelegate.launchedAtLogin = false
                dismissWindow(id: "main")
            }
        }
    }
}
