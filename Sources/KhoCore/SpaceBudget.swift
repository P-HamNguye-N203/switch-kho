import Foundation

public struct BudgetLine: Sendable, Hashable {
    public let source: String
    public let bytes: Int64
    public let route: String
    public let note: String
}

/// What could realistically be moved off the internal disk, per source and route.
public enum SpaceBudget {
    public static let cleanCache = "Dọn cache"
    public static let coldArchive = "Cất lạnh"
    public static let runFromKho = "Chạy từ Kho"
    public static let notMovable = "Không cất được"
    static let minimum: Int64 = 500 * 1_000_000

    public static func estimate(map: AppDataMap, caches: Int64, personalStale: Int64,
                                packageCache: Int64 = 0) -> [BudgetLine] {
        var lines: [BudgetLine] = []
        for fp in map.footprints where fp.total >= minimum {
            let name = fp.app.name
            let cache = fp.folders.filter(\.area.isCache).reduce(Int64(0)) { $0 + $1.allocated }
            if cache > 0 {
                lines.append(BudgetLine(source: name, bytes: cache, route: cleanCache, note: "Tạo lại được"))
            }
            let support = fp.folders.filter { $0.area == .applicationSupport }
            let supportBytes = support.reduce(Int64(0)) { $0 + $1.allocated }
            let rest = fp.total - cache
            if fp.app.ownerIsRoot || fp.app.isAppStore {
                lines.append(BudgetLine(source: name, bytes: rest, route: notMovable,
                                        note: fp.app.isAppStore ? "App Store" : "Bundle thuộc root"))
            } else {
                lines.append(BudgetLine(source: name, bytes: rest, route: coldArchive,
                                        note: "Bundle và dữ liệu, chỉ khi không dùng thường xuyên"))
            }
            if supportBytes > 0 {
                if support.contains(where: \.hasVMImage) {
                    lines.append(BudgetLine(source: name, bytes: supportBytes, route: notMovable,
                                            note: "Có ảnh đĩa máy ảo, không chạy từ Kho"))
                } else {
                    lines.append(BudgetLine(source: name, bytes: supportBytes, route: runFromKho,
                                            note: "Application Support, khi Kho cắm"))
                }
            }
        }
        lines.append(BudgetLine(source: "File cá nhân cũ", bytes: personalStale, route: coldArchive, note: "Lâu không dùng"))
        lines.append(BudgetLine(source: "Package cache", bytes: packageCache, route: cleanCache, note: "npm, pip, uv, pnpm, huggingface"))
        lines.append(BudgetLine(source: "Cache chung", bytes: caches, route: cleanCache, note: "~/Library/Caches"))
        return lines
    }

    public static func totals(_ lines: [BudgetLine]) -> [String: Int64] {
        lines.reduce(into: [:]) { $0[$1.route, default: 0] += $1.bytes }
    }

    public static func markdown(_ lines: [BudgetLine], generated: Date = Date()) -> String {
        var s = "# Ngân sách dung lượng\n\nTạo lúc \(generated.formatted(date: .abbreviated, time: .shortened)).\n\n"
        s += "| Nguồn | Dung lượng | Tuyến | Ghi chú |\n|---|---:|---|---|\n"
        for l in lines.sorted(by: { $0.bytes > $1.bytes }) {
            s += "| \(l.source) | \(ByteFormat.string(l.bytes)) | \(l.route) | \(l.note) |\n"
        }
        s += "\n## Tổng theo tuyến\n\n"
        for (route, bytes) in totals(lines).sorted(by: { $0.value > $1.value }) {
            s += "- \(route): \(ByteFormat.string(bytes))\n"
        }
        return s
    }
}
