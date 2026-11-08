# HIRAKU check — plugin CI "vỏ mỏng"

Plugin chỉ gọi API của HIRAKU, chờ kết quả, in tóm tắt, ghi tệp SARIF và trả mã thoát.
Plugin **không chứa** bảng 38 tiêu chí, quy tắc vá, prompt hay cách tính độ tin cậy. Toàn bộ phần đó chạy trên máy chủ HIRAKU.
Vì vậy mã plugin có thể công khai.

| Tệp | Dùng cho |
|---|---|
| `action.yml` + `hiraku-check.sh` | GitHub Actions (composite: bash, curl, jq, openssl) |
| `gitlab-ci.yml` | GitLab CI (dùng cùng `hiraku-check.sh`) |
| `hiraku-check.sh` | Jenkins, CircleCI…: đặt biến `HK_*` rồi chạy `bash hiraku-check.sh` |

## 1. Chuẩn bị trên cổng HIRAKU (ADMIN dự án)

Vào **Cài đặt dự án** → mục **CI/CD qua API**.

1. **Xác minh tên miền bản xem trước**: nhập tên miền, ví dụ `stg.example.jp`. Mọi tên miền con, như `pr-12.stg.example.jp`, đều được tính.
   Đặt mã xác minh theo một trong hai cách, rồi bấm **Kiểm tra**:
   - Tệp `https://stg.example.jp/.well-known/hiraku-verify.txt` chứa mã.
   - Bản ghi DNS TXT `_hiraku.stg.example.jp` chứa mã.
2. Chọn cách xác thực:
   - **GitHub (khuyên dùng)**: thêm repo `owner/repo` vào mục OIDC. Repo khách không phải giữ khóa dài hạn nào.
   - **CI khác**: tạo **khóa API**. Khóa chỉ hiện **một lần**, nên lưu ngay vào biến bí mật của CI.

## 2. GitHub Actions

```yaml
# .github/workflows/a11y.yml
on: [pull_request]
permissions: { id-token: write, contents: read, security-events: write }
jobs:
  hiraku:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      # … build & deploy bản xem trước, lấy URL vào steps.deploy.outputs.url …
      - id: hiraku
        uses: synthgora/hiraku-check@v1
        with:
          project: AOBA-1029
          preview-url: ${{ steps.deploy.outputs.url }}
          site-dir: public            # tự lấy các tệp .html đổi trong PR; hoặc dùng pages: "/ /news.html"
          gate: standard              # standard | strict | report-only
      - if: always()
        uses: github/codeql-action/upload-sarif@v3
        with: { sarif_file: hiraku.sarif, category: hiraku }
```

Thêm `ai: "true"` thì AI góp ý thêm 5 tiêu chí cần người (1.1.1, 1.3.2, 2.4.4, 2.4.6, 3.3.2):
- Cặp AI nghi không đạt hiện là **AI nghi không đạt**, mức `note` trong SARIF, và **không bao giờ chặn merge**.
- Chi phí tính vào ngân sách dự án, có trần riêng mỗi lượt quét: 20 cặp, ¥300.
- Dự án chọn "Không AI" thì bỏ qua bước này.
- Mỗi lượt sẽ mất khoảng 1–3 phút thay vì 10 giây.

Muốn PR chỉ báo **lỗi mới** thì chạy thêm một lần trên nhánh chính với `baseline: "true"`, để đặt kết quả nhánh chính làm mốc.

## 3. Quy tắc chặn merge

| Nhóm | standard | strict | report-only |
|---|---|---|---|
| 3 tiêu chí máy ghi (1.4.2, 1.4.3, 4.1.1) không đạt | **chặn** | **chặn** | báo |
| 15 tiêu chí máy gợi ý | cảnh báo | **chặn nếu là lỗi mới** so với mốc | báo |
| 20 tiêu chí chỉ chuyên gia | báo "cần chuyên gia" | báo | báo |

AI không bao giờ tự chặn merge. Mặc định lượt quét CI không gọi AI. Khi bật `ai: "true"`, AI chỉ ghi chú. Kết luận cuối vẫn do chuyên gia đưa ra trên cổng HIRAKU.

## 4. Bảo mật

- **GitHub dùng OIDC.** HIRAKU kiểm repo và nhánh trong token, rồi cấp token 15 phút.
- **Khóa API chỉ lưu dạng băm SHA-256.** Khóa có hạn và thu hồi được ngay trên cổng.
- **Mọi request ghi đều phải ký HMAC-SHA256, kèm dấu thời gian lệch tối đa ±5 phút** (chống giả mạo và phát lại):
  - Header `X-Hiraku-Timestamp: <giây unix>`.
  - Header `X-Hiraku-Signature: sha256=<hex>`.
  - Khóa HMAC là `sha256_hex(credential)`; thông điệp là `"<timestamp>." + body`.
- **Có giới hạn lượt:**
  - Mỗi khóa hoặc repo tối đa 30 lượt quét mỗi giờ.
  - Mỗi lượt quét tối đa 20 trang.
  - Mỗi dự án tối đa 2000 trang mỗi tháng.
- **Kết quả chỉ ở dạng rút gọn:** mã tiêu chí, nhóm, trang, selector, kết quả. Không có lý do của AI, prompt hay điểm tin cậy.
