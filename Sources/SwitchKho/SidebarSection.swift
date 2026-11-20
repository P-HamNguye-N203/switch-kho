import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview, analyzer, cleanup, apps, live, files, catalog, rules, activity

    var id: String { rawValue }

    /// Sidebar groups, in order: what the app is for, then the Kho, then housekeeping.
    enum Group: String, CaseIterable {
        case start = "", free = "Giải phóng dung lượng", kho = "Kho", system = "Hệ thống"
    }

    var group: Group {
        switch self {
        case .overview: return .start
        case .analyzer, .cleanup, .apps: return .free
        case .live, .files, .catalog, .rules: return .kho
        case .activity: return .system
        }
    }

    var title: String {
        switch self {
        case .overview: return "Tổng quan"
        case .analyzer: return "Phân tích"
        case .cleanup: return "Dọn dẹp"
        case .apps: return "Ứng dụng"
        case .live: return "Chạy từ Kho"
        case .files: return "Hai khung"
        case .catalog: return "Danh mục"
        case .rules: return "Quy tắc"
        case .activity: return "Nhật ký"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .analyzer: return "chart.bar.xaxis"
        case .cleanup: return "trash"
        case .apps: return "app.badge"
        case .live: return "bolt.horizontal"
        case .files: return "rectangle.split.2x1"
        case .catalog: return "doc.text.magnifyingglass"
        case .rules: return "wand.and.stars"
        case .activity: return "list.bullet.rectangle"
        }
    }
}
