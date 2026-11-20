# Switch Kho

[![CI](https://github.com/P-HamNguye-N203/switch-kho/actions/workflows/ci.yml/badge.svg)](https://github.com/P-HamNguye-N203/switch-kho/actions/workflows/ci.yml)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

Ứng dụng macOS bản địa giúp giải phóng ổ trong của máy Mac bằng cách dời dữ liệu sang một ổ ngoài gọi là **Kho**, an toàn và hoàn tác được.

*A native macOS app that frees up internal storage by moving data to an external APFS drive ("Kho"), with a verified copy, a holding period and full undo.*

## Tính năng

| Màn | Làm gì |
|---|---|
| **Tổng quan** | Dung lượng còn trống của máy và Kho, gợi ý giải phóng xếp theo dung lượng, vùng chờ |
| **Phân tích** | Dung lượng theo ứng dụng (bundle + dữ liệu trong `~/Library`) và theo cây thư mục |
| **Dọn dẹp** | Tìm cache và rác xoá an toàn; mục không rõ chủ chỉ dọn từng cái |
| **Ứng dụng** | Cất cả app cùng dữ liệu vào Kho, lấy về khi cần |
| **Chạy từ Kho** | Dời dữ liệu Application Support lên Kho, chỗ cũ là liên kết; người gác thoát app khi Kho rút |
| **Hai khung** | Máy bên trái, Kho bên phải: cất, lấy về, chép, tìm theo tên, kéo thả |
| **Danh mục** | Tìm mọi file trên Kho kể cả khi Kho đã rút (SQLite FTS5, không cần dấu) |
| **Quy tắc** | Gợi ý hoặc tự cất file lâu không dùng theo thư mục, đuôi file, dung lượng |

## Mô hình an toàn

- **Chép có xác minh**: dữ liệu được chép rồi so khớp trước khi bản gốc bị động tới.
- **Vùng chờ**: bản gốc được giữ trên máy (mặc định 7 ngày, chỉnh 1–30) và hoàn tác được trong thời gian đó.
- **Kiểm trước khi xoá**: hết hạn giữ, bản trên Kho được kiểm lại; Kho không cắm thì việc xoá chờ lần cắm sau.
- **Sổ cái**: mọi thao tác đi qua một máy trạng thái lưu trong SQLite (`copying → moving → holding → committing → committed`, cùng các nhánh hoàn tác), nên app bị tắt giữa chừng vẫn khôi phục được. Sổ cái được sao lưu lên Kho.
- **Nhận dạng Kho** bằng dấu riêng ghi trên ổ, không dựa vào tên ổ.

## Yêu cầu

- macOS 15 trở lên
- Swift 6 (Xcode 16 hoặc Command Line Tools tương ứng)
- Một ổ ngoài định dạng **APFS** làm Kho

## Bắt đầu

```bash
git clone https://github.com/P-HamNguye-N203/switch-kho.git
cd switch-kho

scripts/test.sh                              # chạy bộ test
scripts/create-signing-identity.sh --auto    # lần đầu: tạo chứng chỉ ký cục bộ (giữ quyền giữa các lần build)
scripts/install.sh                           # build, ký và cài vào ~/Applications/Switch Kho.app
```

Sau khi cài, cấp **Full Disk Access** (và **App Management** nếu muốn cất app) cho Switch Kho trong Cài đặt hệ thống. Hướng dẫn đầy đủ: [docs/user-guide.md](docs/user-guide.md).

## Cấu trúc

```text
Sources/
  KhoCore/     Lõi không phụ thuộc giao diện: sổ cái, chép có xác minh, vùng chờ,
               cất app, chạy từ Kho, dọn dẹp, danh mục, quy tắc
  SwitchKho/   Ứng dụng SwiftUI: AppModel (@Observable) và các màn trong Views/
Tests/
  KhoCoreTests/  Swift Testing, chạy trên thư mục tạm, không đụng dữ liệu thật
scripts/       build, ký, cài, test, công cụ phụ
docs/          Hướng dẫn sử dụng
```

## Kiểm thử

```bash
scripts/test.sh                       # toàn bộ test
scripts/test.sh --filter Ledger       # một nhóm test
```

Test không ghi vào thư mục nhà hay Kho thật. Một nhóm test nhỏ chỉ chạy trên Kho thật khi đặt `SWITCHKHO_REAL_KHO=1`, và chỉ ghi vào thư mục `_selftest` trên Kho.

## Bản quyền

© 2026 Pham Nguyen. Bảo lưu mọi quyền — xem [LICENSE](LICENSE).
