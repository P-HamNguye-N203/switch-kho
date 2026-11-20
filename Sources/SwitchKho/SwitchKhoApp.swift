import AppKit
import SwiftUI

@main
struct SwitchKhoApp: App {
    @State private var selection: SidebarSection? = .overview

    var body: some Scene {
        WindowGroup(id: "main") {
            NavigationSplitView {
                List(SidebarSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            } detail: {
                Text((selection ?? .overview).title)
                    .font(.title)
            }
        }

        MenuBarExtra("Switch Kho", systemImage: "externaldrive.fill") {
            MenuBarContent()
        }
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
