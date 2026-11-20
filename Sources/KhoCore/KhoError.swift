import Foundation

/// Errors surfaced to the user. Messages are Vietnamese because they are shown verbatim in the UI.
public enum KhoError: LocalizedError, Equatable, Sendable {
    case blocked(String)
    case notFound(String)
    case verifyFailed(String)
    case khoOffline
    case appRunning(String)
    case notDeletable(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case destinationOccupied(String)
    case invalidState(String)
    case alreadyManaged(String)
    case sourceChanged(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let p):
            return "Không được phép thao tác trên vùng được bảo vệ: \(p)"
        case .notFound(let p):
            return "Không tìm thấy: \(p)"
        case .verifyFailed(let p):
            return "Bản sao không khớp với bản gốc, đã huỷ: \(p)"
        case .khoOffline:
            return "Ổ Kho chưa được cắm."
        case .appRunning(let n):
            return "Ứng dụng đang chạy, hãy thoát trước: \(n)"
        case .notDeletable(let p):
            return "Không có quyền xoá bản gốc: \(p)"
        case .insufficientSpace(let needed, let available):
            return "Không đủ chỗ trống: cần \(ByteFormat.string(needed)), còn \(ByteFormat.string(available))."
        case .destinationOccupied(let p):
            return "Chỗ đích đã có dữ liệu: \(p)"
        case .invalidState(let m):
            return "Trạng thái không hợp lệ: \(m)"
        case .alreadyManaged(let m):
            return "Mục này đã thuộc một thao tác khác của Switch Kho (\(m))."
        case .sourceChanged(let p):
            return "File đã thay đổi trong lúc chép, thao tác đã được huỷ an toàn: \(p)"
        case .io(let m):
            return m
        }
    }
}
