What's New in v1.0.1 (Optimized Version)
----------------------------------------

Bản phát hành này tập trung vào việc tương thích hoàn toàn với các phiên bản OBS mới nhất, đồng thời tối ưu hóa thuật toán để script chạy mượt mà, không gây ảnh hưởng đến FPS khi livestream hoặc quay video.

### Cải tiến & Sửa lỗi (Changelog)

*   **Fix Toggle Key:** Xử lý triệt để lỗi không nhận phím tắt Bật/Tắt bằng cơ chế quản lý trạng thái (boolean toggle) ổn định trong on\_toggle\_key.
    
*   **Cập nhật OBS API (v29.1+):** Thay thế hàm cũ bằng obs\_sceneitem\_get\_info2 và obs\_sceneitem\_set\_info2 để ngăn chặn lỗi Crash và triệt tiêu các cảnh báo (warnings) trên các phiên bản OBS Studio mới.
    
*   **Tối ưu hóa hiệu năng (Optimize Frame):**
    
    *   **Early Return:** Thuật toán thông minh tự động bỏ qua tính toán (dừng script\_tick) khi Zoom đang tắt và tỷ lệ scale đã về mặc định, giúp giải phóng 100% CPU/GPU cho tác vụ này.
        
    *   **FFI Memory Optimization:** Cấp phát bộ nhớ FFI (cursor\_pt) một lần duy nhất thay vì 60 lần/giây, loại bỏ hoàn toàn hiện tượng rác RAM (Garbage Collection).
        
    *   **Scene Item Caching:** Lưu trữ cache của Source thay vì vòng lặp quét (find source) liên tục mỗi khung hình.
        

### Hướng dẫn cài đặt

1.  Tải file mã nguồn zoom-to-mouse-v1.0.1.zip ở phần **Assets** bên dưới và giải nén.
    
2.  Mở **OBS Studio** -> Chọn thanh menu **Tools** (Công cụ) -> **Scripts** (Kịch bản).
    
3.  Nhấn dấu + ở góc dưới bên trái và chọn file zoom\_to\_mouse.lua vừa giải nén.
    
4.  Ở khung cấu hình bên phải, chọn **Source** (Nguồn hiển thị) bạn muốn áp dụng.
    
5.  Vào **Settings** (Cài đặt) -> **Hotkeys** (Phím tắt) để gán phím Bật/Tắt zoom.
    

### Tín dụng & Bản quyền

*   **Tác giả kịch bản gốc:** [@BlankSourceCode](https://github.com/BlankSourceCode)
    
*   **Tối ưu & Cải tiến:** @[nguyenquocanhz](https://github.com/nguyenquocanhz)
    
*   **Giấy phép (License):** MIT License
