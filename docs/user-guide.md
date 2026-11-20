# Hướng dẫn sử dụng Switch Kho

Switch Kho giải phóng ổ trong của máy Mac bằng cách dời dữ liệu sang một ổ ngoài gọi là **Kho**. Mọi lần dời đều qua **vùng chờ**: bản gốc được giữ lại trên máy một thời gian (mặc định 7 ngày) để bạn hoàn tác được, sau đó mới bị xoá.

## 1. Cài đặt

Chạy trong Terminal, tại thư mục dự án:

```bash
scripts/create-signing-identity.sh --auto   # chỉ lần đầu: tạo chứng chỉ ký riêng cho máy này
scripts/install.sh                          # build, ký và cài vào ~/Applications/Switch Kho.app
```

Mỗi lần build lại, app được ký bằng cùng chứng chỉ, nên macOS giữ nguyên các quyền đã cấp.

## 2. Cấp quyền

Mở **Switch Kho › Cài đặt…** (⌘,):

- **Full Disk Access**: bấm "Mở cài đặt Full Disk Access", thêm `~/Applications/Switch Kho.app` và bật lên. Thiếu quyền này, Switch Kho không đọc được nhiều thư mục trong `~/Library`.
- **App Management**: cần khi cất cả app. Bấm "Mở cài đặt App Management" và bật Switch Kho.
- **Mở cùng macOS**: bật trong Cài đặt. Đây là điều kiện để người gác hoạt động (xem mục 8). Khi mở cùng máy, Switch Kho chỉ hiện biểu tượng trên menu bar, không mở cửa sổ.

Sau khi cấp quyền, hãy thoát rồi mở lại Switch Kho.

## 3. Chọn Kho

Kho phải là ổ ngoài định dạng **APFS**. Ở màn **Tổng quan**, thẻ "Chọn Kho" liệt kê các ổ ngoài. Bấm "Dùng ổ này làm Kho". Switch Kho ghi một file nhận dạng vào ổ, nên đổi tên ổ không làm mất Kho.

Đổi sang ổ khác ở **Cài đặt › Kho**. Các thao tác cũ vẫn gắn với Kho cũ.

## 4. Tổng quan và vùng chờ

Màn **Tổng quan** cho thấy dung lượng còn trống của máy và của Kho, cùng danh sách vùng chờ.

- **Hoàn tác** trong thời gian giữ: bản gốc về đúng chỗ cũ, bản trên Kho bị xoá.
- Hết thời gian giữ, Switch Kho **kiểm bản trên Kho** rồi mới xoá bản gốc. Nếu lúc đó Kho không cắm, việc xoá chờ tới lần cắm Kho sau.
- Số ngày giữ chỉnh được ở Cài đặt (1–30 ngày).

## 5. Phân tích

Màn **Phân tích** có hai cách xem:

- **Theo ứng dụng**: mỗi app chiếm bao nhiêu, gồm cả dữ liệu trong `~/Library`. Thư mục không rõ của app nào có thể gán tay (chuột phải › "Gán cho ứng dụng…").
- **Cây thư mục**: chọn một thư mục để xem dung lượng theo cây, các file lớn nhất và file lâu không dùng. Chuột phải một mục để **Cất vào Kho**.

## 6. Dọn dẹp

Màn **Dọn dẹp** gom các nhóm có thể xoá. Bấm "Xem trước" để biết chính xác sẽ xoá gì.

| Nhóm | Cách xoá |
|---|---|
| Xcode DerivedData | Xoá hẳn (Xcode tạo lại khi build) |
| Cache của từng app, cache Electron, cache Chrome | Xoá hẳn; app phải đang thoát |
| Cache gói (npm, pip, Homebrew…) | Lệnh dọn của chính công cụ, hoặc xoá hẳn |
| File cài đặt cũ (.dmg, .pkg trong Downloads) | Vào Thùng rác |
| `node_modules` của dự án lâu không đụng tới | Vào Thùng rác |
| Thùng rác | Xoá hẳn |

Dọn dẹp không qua vùng chờ, vì đây là dữ liệu tạo lại được hoặc đã nằm trong Thùng rác.

## 7. Cất cả app

Màn **Ứng dụng**: chọn một app để xem nó có cất được không.

- **Bị chặn**: app từ App Store, app hệ thống, app thuộc root, app đang chạy, dữ liệu dùng chung với app khác.
- **Cảnh báo**: app có Sparkle hoặc của Adobe, dữ liệu sandbox (Containers), tiến trình chạy nền (LaunchAgent).

Cất app dời cả bundle `.app` lẫn dữ liệu của nó lên Kho. **Lấy về** chép lại đúng chỗ, đăng ký lại với macOS và kiểm chữ ký. Nếu chữ ký hỏng sau khi lấy về, đừng mở app mà hãy cài lại. Nếu chỗ cũ đã có bản cài mới, Switch Kho dừng lại và không ghi đè.

## 8. Chạy từ Kho

Màn **Chạy từ Kho** dời thư mục `Application Support` của một app lên Kho và để lại một liên kết ở chỗ cũ. App vẫn chạy bình thường **khi Kho đang cắm**.

**Quy tắc vàng: luôn tháo Kho bằng nút "Tháo Kho an toàn" của Switch Kho** (trên menu bar hoặc trong app), không kéo ổ vào Thùng rác và không rút cáp. Nút này dừng các việc đang chép, thoát các app chạy từ Kho rồi mới tháo ổ.

- **Người gác** tắt app chạy từ Kho nếu nó được mở khi Kho vắng, và báo trên menu bar.
- **Docker, máy ảo, Kiri** bị chặn: chúng giữ file ảnh đĩa lớn mở liên tục, hoặc nằm trên ổ mạng, nên không chịu được việc Kho biến mất.
- **"Có bản tạo khi Kho vắng"** (`symlinkReplaced`): app đã tạo một thư mục thật ở chỗ liên kết khi Kho không cắm. Bấm "Giữ bản trên Kho" để chép thư mục đó lên Kho, đặt lại liên kết và không mất gì. Bản đó nằm ở mục "Bản tạo khi Kho vắng", lấy về cạnh chỗ cũ được.
- **"Đưa về máy"** chép bản hiện tại trên Kho về chỗ cũ, thay liên kết bằng thư mục thật.

## 9. File cá nhân, danh mục, quy tắc

**Cất file cá nhân**: chuột phải trong cây thư mục hoặc dùng màn Hai khung. File được đặt vào `Kho/SwitchKho/Archive/` theo đúng đường dẫn gốc. Switch Kho bỏ qua file vừa sửa trong 10 phút và file đang mở ở app khác, và báo lý do.

**Danh mục**: Switch Kho lập chỉ mục mọi thứ trên Kho mỗi ngày một lần khi Kho cắm (nút "Lập chỉ mục lại" để làm ngay).

- Tìm không cần dấu ("hoa don" ra "Hoá đơn"), cần ít nhất 2 ký tự.
- **Vẫn tìm được khi Kho đã rút**; kết quả khi đó ghi "○ Ngoại tuyến".
- Tab **Đã cất** liệt kê các lần cất file cá nhân, với Hoàn tác hoặc Lấy về.
- Có thể tìm nhanh từ ô tìm trên menu bar.

**Quy tắc**: màn **Quy tắc** gợi ý hoặc tự cất các mục lâu không dùng trong một thư mục (ví dụ: `.dmg` trong Downloads không mở quá 90 ngày).

- Luôn bấm **Xem trước**. Cột "Nguồn ngày" cho biết ngày dùng lấy từ đâu: "Ngày mở (Finder)" đáng tin nhất; "Ngày sửa" có thể chọn nhầm file chỉ được đọc.
- Chế độ **Tự động** chạy mỗi 6 giờ khi Kho cắm. Mọi lần cất đều qua vùng chờ.

## 10. Hai khung

Màn **Hai khung**: bên trái là máy, bên phải là Kho.

- **Cất →**: cất các mục chọn bên trái vào Kho (qua vùng chờ). Kéo từ trái sang phải cũng vậy.
- **← Lấy về**: lấy về chỗ cũ một mục đã cất. Kéo từ phải sang trái cũng vậy. Mục bạn tự đặt vào Kho (không có trong sổ cái) chỉ chép về được.
- **Chép**: chép theo chiều của khung vừa chọn, không xoá bản gốc, có kiểm nội dung.

Nhấp đúp để mở thư mục hoặc file; chuột phải để Hiện trong Finder hoặc Xem nhanh.

## 11. Xử lý sự cố

- **Mất quyền sau khi build lại**: chạy `tccutil reset All local.switchkho.app`, rồi cấp lại Full Disk Access và App Management (mục 2).
- **Kho không được nhận**: kiểm ổ có phải APFS và có thư mục `SwitchKho` không. Nếu bạn cắm hai ổ cùng tên `Kho`, Switch Kho nhận theo file nhận dạng, không theo tên. Chọn lại ở Cài đặt › Kho nếu cần.
- **File `.switchkho-partial-…`**: bản chép dở khi máy tắt hoặc Kho bị rút giữa chừng. Switch Kho tự xoá chúng khi khởi động và khi cắm lại Kho.
- **Vùng chờ chưa xoá dù đã quá hạn**: Switch Kho chờ cắm Kho để kiểm bản trên Kho trước khi xoá bản gốc. Cắm Kho là xong.
- **Khôi phục sổ cái từ Kho** (cài lại máy, mất thư mục dữ liệu): Cài đặt › Kho › "Khôi phục sổ cái từ Kho". Chỉ làm được khi sổ cái trong máy chưa có thao tác nào. Các thao tác chưa xong được đánh dấu cần kiểm; Switch Kho thoát, hãy mở lại.
- **Nhật ký**: màn Nhật ký ghi mọi việc đã làm; bật "Chỉ lỗi" để xem lỗi.

## 12. Giới hạn đã biết

- **Không phải sao lưu.** Sau thời gian giữ, dữ liệu chỉ còn một bản trên Kho. Hãy sao lưu Kho riêng nếu dữ liệu quan trọng.
- **Hard link** được chép thành các file riêng, nên có thể chiếm nhiều chỗ hơn trên Kho.
- **Người gác chỉ phản ứng sau** (tắt app vừa mở khi Kho vắng) và chỉ khi Switch Kho đang chạy. Thoát Switch Kho trong lúc có app chạy từ Kho sẽ có cảnh báo.
- **App chạy từ Kho chỉ đọc được dữ liệu sau khi Switch Kho đã mở và nhận Kho** (liên kết đi qua thư mục dữ liệu của Switch Kho). Vì vậy hãy giữ "Mở cùng macOS" bật.
- **Dữ liệu sandbox (Containers)** mất lớp bảo vệ App Data của macOS khi nằm trong vùng chờ và trên Kho.
- **"Hoàn tác" với app chạy từ Kho** chép bản hiện tại trên Kho về máy, không trả lại bản cũ lúc mới dời.
- **Chứng chỉ ký**: mật khẩu keychain ký được lưu trong login keychain để build tự động. Trong lúc keychain ký đang mở (tối đa 15 phút sau khi build), một tiến trình khác cùng tài khoản có thể dùng chứng chỉ này để ký và mượn quyền của Switch Kho.
- **Đừng tự đặt file vào thư mục của một lần cất còn trong vùng chờ** (bằng Finder). Hoàn tác lần cất đó xoá cả thư mục trên Kho, kể cả file bạn thêm vào. Nút "Chép" của Switch Kho đã chặn trường hợp này.
- **Kéo thả** sang khung Kho cất ngay mà không hỏi lại (vẫn hoàn tác được trong vùng chờ); kéo có thể chỉ mang theo một mục, nên muốn cất nhiều mục thì chọn rồi bấm "Cất →".
- **Phiên thử riêng** (`--data-dir`) chỉ có ở bản cài nghiệm thu `scripts/install.sh --test-sessions`; bản cài thường bỏ qua tuỳ chọn này. Cài lại bằng `scripts/install.sh` sau khi thử xong.
