import AppKit
import KhoCore
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
                Sidebar()
                    .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            } detail: {
                detail(model.section ?? .overview)
                    .safeAreaInset(edge: .bottom, spacing: 0) { BottomStatusArea() }
            }
            .frame(minWidth: 900, minHeight: 560)
            .environment(\.locale, VN.locale)
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
                .environment(\.locale, VN.locale)
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(\.locale, VN.locale)
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

/// Grouped sections, each with a count or a warning when something there needs a look.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.section) {
            ForEach(SidebarSection.Group.allCases, id: \.self) { group in
                let items = SidebarSection.allCases.filter { $0.group == group }
                if group.rawValue.isEmpty {
                    ForEach(items) { row($0) }
                } else {
                    Section(group.rawValue) { ForEach(items) { row($0) } }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .badge(badge(section))
            .tag(section)
    }

    private func badge(_ section: SidebarSection) -> Text? {
        switch section {
        case .overview:
            let n = model.holdingRows.filter { $0.op.error != nil || $0.op.needsReview }.count
            return n > 0 ? Text("\(n)").foregroundColor(.orange) : nil
        case .cleanup:
            let n = model.safeCleanupCandidates.count
            return n > 0 ? Text("\(n)") : nil
        case .live:
            let n = model.liveIssues.values.filter { LiveIntegrity.summary($0) != .ok && LiveIntegrity.summary($0) != .khoMissing }.count
            return n > 0 ? Text("\(n)").foregroundColor(.orange) : nil
        case .rules:
            let n = model.rules.filter { $0.enabled }.count
            return n > 0 ? Text("\(n)") : nil
        default:
            return nil
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
