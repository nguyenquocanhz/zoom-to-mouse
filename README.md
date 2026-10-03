# OBS Zoom to Mouse

Lua script cho OBS Studio: **zoom màn hình theo con trỏ chuột**, khung hình mượt mà bám theo chuột, tự zoom khi click (kiểu Screen Studio). Dùng cho video hướng dẫn, dạy code, demo phần mềm.

Bản fork được bảo trì của [BlankSourceCode/obs-zoom-to-mouse](https://github.com/BlankSourceCode/obs-zoom-to-mouse). Yêu cầu **OBS Studio 28+** (khuyên dùng 30+), chạy trên Windows, macOS và Linux (X11).

## Có gì mới trong v1.1.0

**Sửa lỗi**
- **Transform gốc không được khôi phục.** Khi đổi scene, đổi source hoặc gỡ script, code gọi `obs_sceneitem_get_info2` (đọc) thay vì `obs_sceneitem_set_info2` (ghi), nên source bị kẹt ở bounding box do script tự chuyển đổi. Giờ đã trả đúng transform gốc.
- **Đọc vượt danh sách màn hình** (`for i = 0, item_count`): bị lệch 1, đọc một phần tử không tồn tại.
- **`is_display_capture` luôn trả `true`** khi tắt "Allow any zoom source". Giờ kiểm tra đúng loại source.
- **Khung follow luôn hụt 1px ở mép màn hình**: lerp tiến tiệm cận rồi bị `floor()`. Giờ snap về đích khi còn cách dưới nửa pixel.
- **Tốc độ zoom/follow phụ thuộc FPS**: canvas 30fps zoom chậm gấp đôi 60fps. Giờ tính theo thời gian thực.
- **Easing sai**: bản cũ lerp từ vị trí *hiện tại* với hệ số đã ease, nên đường cong thực tế khác hẳn ease-in-out. Giờ lerp từ điểm bắt đầu animation.
- Tắt follow khi đang zoom thì timer vẫn chạy mỗi frame dù không làm gì. Giờ timer dừng hẳn.
- Thoát OBS / đổi Scene Collection lúc đang zoom thì filter crop bị lưu luôn vào scene. Giờ dọn trước khi OBS lưu.
- Máy Linux thiếu thư viện X11 thì script lỗi ngay khi load. Giờ chỉ báo cảnh báo.

**Tối ưu**
- Chỉ gọi `obs_source_update` khi giá trị crop (pixel nguyên) thật sự đổi. Lúc khung đứng yên hoặc animation chậm thì gần như không tốn gì.

**Tính năng mới**
- **Auto zoom on click** + tự zoom ra khi để yên chuột (Windows, macOS, Linux X11).
- Hotkey **zoom in more / zoom in less** để đổi mức zoom ngay khi đang zoom.
- Bấm hotkey giữa lúc đang animation sẽ **đảo chiều** ngay tại chỗ, không phải chờ animation xong.
- **Scale filter Lanczos + Sharpen** khi zoom (xem phần trên).
- Tìm Zoom Source cả trong **Group**, không chỉ trong nested scene.
- Hỗ trợ OBS 28–29 (tự dùng `obs_sceneitem_get_info` nếu không có bản `...2`).
- Zoom Factor tối đa 10×, bước 0.1.

## Cài đặt

1. Tải [`obs-zoom-to-mouse.lua`](obs-zoom-to-mouse.lua) và để vào một thư mục **cố định** (OBS chỉ nhớ đường dẫn, xóa file đi là mất script).
2. Thêm một **Display Capture** (Windows/macOS) hoặc **Screen Capture (XSHM)** (Linux X11) vào scene.
3. Mở **Tools** (Công cụ) → **Scripts**, bấm **`+`** ở góc dưới bên trái và chọn `obs-zoom-to-mouse.lua`.
4. Ở khung cài đặt bên phải, chọn **Zoom Source** là Display Capture vừa tạo.
5. **Settings → Hotkeys**, gõ "zoom" để lọc:
   - **Toggle zoom to mouse**: bật/tắt zoom (ví dụ `Ctrl+Shift+Z`)
   - **Toggle follow mouse during zoom**: bật/tắt khung bám theo chuột
   - **Zoom to mouse: zoom in more / zoom in less**: phóng to/thu nhỏ thêm khi đang zoom
6. Muốn không phải bấm phím thì bật **Auto zoom on click**: click chuột trái là tự zoom vào chỗ vừa click, để yên chuột vài giây là tự zoom ra.

Script lỗi hoặc zoom lệch: bật **Enable debug logging**, rồi mở **Tools → Scripts → Script Log** để xem.

## Các tùy chọn

| Tùy chọn | Ý nghĩa | Gợi ý |
|---|---|---|
| Zoom Factor | Mức phóng to (1–10×) | 2 cho màn 1080p, 2.5–3 cho màn 4K |
| Zoom Step (hotkey) | Mỗi lần bấm zoom more/less thay đổi bao nhiêu | 0.5 |
| Zoom Speed | Tốc độ animation zoom vào/ra | 0.04–0.08 |
| **Scale filter while zoomed** | Bộ lọc phóng ảnh khi đang zoom | **Lanczos** (nét nhất) |
| **Sharpen while zoomed** | Độ làm nét, tăng dần theo mức zoom (0 = tắt) | 0.1–0.2 |
| Auto zoom on click | Click chuột trái trong vùng màn hình thì tự zoom | Bật cho video hướng dẫn |
| Auto zoom out after (s) | Không động chuột bao nhiêu giây thì tự zoom ra (0 = không bao giờ) | 2–4 giây |
| Auto follow mouse | Khung tự bám chuột khi đang zoom | Bật |
| Follow Speed | Tốc độ khung đuổi theo chuột | 0.15–0.3 |
| Follow Border | Chuột vào sát mép bao nhiêu % thì khung bắt đầu chạy theo | 5–15 |
| Lock Sensitivity | Khung chạy tới gần chuột bao nhiêu px thì đứng yên | 4 |
| Auto Lock on reverse direction | Kéo chuột ngược lại thì khung dừng (giống kéo camera trong game RTS) | Tùy thích |
| Allow any zoom source | Cho zoom cả source không phải Display Capture (webcam, window capture...) | Khi bật phải nhập **Set manual source position** |
| Set manual source position | Tự nhập vị trí và kích thước màn hình khi script không tự đoán được | Dùng khi zoom bị lệch |

## Zoom bị mờ: vì sao và cách làm nét

Khi zoom 2× trên màn 1080p, OBS cắt một vùng 960×540 rồi **phóng nó lên 1920×1080**. Vùng đó chỉ có 1/4 số điểm ảnh, nên dù làm gì cũng không thể nét như ảnh gốc. Nhưng có thể làm nó **trông nét hơn nhiều**:

1. **Scale filter = Lanczos** (mặc định từ v1.1.0). OBS mặc định phóng ảnh bằng *bilinear* nên chữ bị nhòe. Lanczos giữ cạnh chữ sắc hơn rõ rệt. Script chỉ đổi khi đang zoom và trả lại như cũ khi zoom ra.
2. **Sharpen while zoomed = 0.1–0.2**. Script tự thêm filter Sharpen, độ nét tăng dần theo mức zoom (đầy đủ ở 2×) và tự tắt khi zoom ra. Đẩy quá 0.3 sẽ bị viền răng cưa.
3. **Quay màn hình độ phân giải cao hơn canvas.** Đây là cách duy nhất cho zoom *thật sự* nét. Màn 4K + canvas 1080p: zoom 2× vẫn đủ 1920×1080 điểm ảnh thật, gần như không mất chi tiết. Chỉnh ở *Settings → Video*: **Base (Canvas) Resolution** = độ phân giải màn hình, **Output (Scaled) Resolution** = 1920×1080, **Downscale Filter** = Lanczos.
4. **Đừng zoom quá tay**: trên màn 1080p, 1.5–2× là hợp lý. Từ 3× trở lên chữ sẽ to nhưng vỡ.
5. **Đủ bitrate**: lúc khung chạy theo chuột, cả hình thay đổi liên tục. Bitrate thấp thì hình bị nhòe khi chuyển động. Ghi video nên dùng CQP/CRF khoảng 18–20; stream 1080p60 nên từ 6000 Kbps.
6. Tăng font hệ thống / zoom IDE (Ctrl + `+`) trước khi quay. Đây vẫn là cách rẻ nhất để chữ nét.

## Giới hạn

- **Linux Wayland**: không đọc được vị trí chuột của hệ thống. Hãy đăng nhập phiên X11 ("Ubuntu on Xorg").
- macOS: lần đầu có thể cần cấp quyền *Accessibility / Input Monitoring* cho OBS thì auto zoom on click mới nhận click.
- Nhiều màn hình: script đọc vị trí màn hình từ tên trong danh sách Display Capture. Nếu zoom bị lệch, bật **Set manual source position** và nhập X/Y/Width/Height của màn hình đó.

---

## Test

Test chạy bằng LuaJIT (cùng engine Lua mà OBS dùng) với một bản giả lập `obslua`, nên không cần mở OBS:

```bash
sudo apt install luajit         # macOS: brew install luajit
tests/run.sh                    # kiểm cú pháp + chạy 53 test
python3 tests/mutate.py         # mutation test: cài lại lỗi vào script, test phải đỏ
```

`mutate.py` cài lại từng lỗi vào bản sao script, gồm cả các lỗi của v1.0.1 ở trên (restore transform, đọc vượt danh sách màn hình, hụt 1px, phụ thuộc FPS...), và yêu cầu test phải **đỏ**. Hiện tại cả 19 mutant đều bị bắt. Script đã được load thử trong OBS 30.0.2 thật, log không có lỗi. Phần đọc chuột và click (FFI) vẫn cần thử trên máy có màn hình.

## Lịch sử phiên bản

### v1.0.1 (Optimized Version)

*   **Fix Toggle Key:** Xử lý triệt để lỗi không nhận phím tắt Bật/Tắt bằng cơ chế quản lý trạng thái (boolean toggle) ổn định trong on\_toggle\_key.
    
*   **Cập nhật OBS API (v29.1+):** Thay thế hàm cũ bằng obs\_sceneitem\_get\_info2 và obs\_sceneitem\_set\_info2 để ngăn chặn lỗi Crash và triệt tiêu các cảnh báo (warnings) trên các phiên bản OBS Studio mới.
    
*   **Tối ưu hóa hiệu năng (Optimize Frame):**
    
    *   **Early Return:** Thuật toán thông minh tự động bỏ qua tính toán (dừng script\_tick) khi Zoom đang tắt và tỷ lệ scale đã về mặc định, giúp giải phóng 100% CPU/GPU cho tác vụ này.
        
    *   **FFI Memory Optimization:** Cấp phát bộ nhớ FFI (cursor\_pt) một lần duy nhất thay vì 60 lần/giây, loại bỏ hoàn toàn hiện tượng rác RAM (Garbage Collection).
        
    *   **Scene Item Caching:** Lưu trữ cache của Source thay vì vòng lặp quét (find source) liên tục mỗi khung hình.
        

## Tín dụng & Bản quyền

*   **Tác giả kịch bản gốc:** [@BlankSourceCode](https://github.com/BlankSourceCode)
*   **Tối ưu & Cải tiến:** [@nguyenquocanhz](https://github.com/nguyenquocanhz)
*   **Giấy phép (License):** MIT License
