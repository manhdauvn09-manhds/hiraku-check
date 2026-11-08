#!/usr/bin/env bash
# HIRAKU check — "vỏ mỏng" gọi API CI của HIRAKU (C3). Dùng chung cho GitHub Actions, GitLab CI, Jenkins…
# Cần: bash, curl, jq, openssl, sha256sum. Không chứa tiêu chí, quy tắc hay prompt: mọi xử lý nằm trên máy chủ.
#
# Biến vào (HK_*): PROJECT, PREVIEW_URL, PAGES, SITE_DIR, GATE, AI, API_URL, API_KEY, AUDIENCE, BASELINE, SARIF,
#                  TIMEOUT_MIN, PR_NUMBER, BASE_SHA, COMMIT_SHA (mặc định GITHUB_SHA / CI_COMMIT_SHA)
# Mã thoát: 0 = PASS/WARN, 1 = FAIL (chặn merge), 2 = lỗi cấu hình / gọi API.
set -euo pipefail

API="${HK_API_URL:-https://hiraku.synthgora.com}"
API="${API%/}/api/ci/v1"
GATE="${HK_GATE:-standard}"
SHA="${HK_COMMIT_SHA:-${GITHUB_SHA:-${CI_COMMIT_SHA:-}}}"
SARIF="${HK_SARIF:-hiraku.sarif}"
TIMEOUT=$(( ${HK_TIMEOUT_MIN:-15} * 60 ))

die() { echo "::error::HIRAKU: $*" >&2; exit 2; }

# ---------- chữ ký HMAC: khóa = sha256_hex(credential), thông điệp = "<ts>." + body
hk_sign() {   # $1 credential, $2 timestamp, $3 body  → in "sha256=<hex>"
  local key
  key=$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)
  printf 'sha256=%s' "$(printf '%s.%s' "$2" "$3" | openssl dgst -sha256 -hmac "$key" | awk '{print $NF}')"
}

[ "${HK_SOURCE_ONLY:-}" = "1" ] && return 0 2>/dev/null   # cho test: chỉ nạp hàm

command -v jq >/dev/null || die "cần jq"
[ -n "${HK_PROJECT:-}" ] || die "thiếu project"
[ -n "${HK_PREVIEW_URL:-}" ] || die "thiếu preview-url"
[ -n "$SHA" ] || die "không biết commit SHA"

# ---------- danh sách trang
PAGES="${HK_PAGES:-}"
if [ -z "${PAGES// /}" ] && [ -n "${HK_SITE_DIR:-}" ] && [ -n "${HK_BASE_SHA:-}" ]; then
  dir="${HK_SITE_DIR%/}/"
  PAGES=$(git diff --name-only "$HK_BASE_SHA" "$SHA" -- "$dir" 2>/dev/null | grep -Ei '\.html?$' | sed "s#^${dir}#/#; s#/index\.html\$#/#" | head -n 20 || true)
elif [ -z "${PAGES// /}" ] && [ -n "${HK_SITE_DIR:-}" ]; then
  # Không có PR (push nhánh chính / đặt mốc): quét mọi trang .html dưới site-dir (tối đa 20) để mốc đủ trang
  dir="${HK_SITE_DIR%/}/"
  PAGES=$(git ls-files -- "$dir" 2>/dev/null | grep -Ei '\.html?$' | sed "s#^${dir}#/#; s#/index\.html\$#/#" | sort | head -n 20 || true)
fi
[ -z "${PAGES//[[:space:]]/}" ] && PAGES="/"
set -f; PAGES_JSON=$(printf '%s\n' $PAGES | jq -R . | jq -s 'map(select(length>0)) | unique'); set +f

# ---------- credential: khóa API hoặc OIDC (GitHub)
CRED="${HK_API_KEY:-}"
if [ -z "$CRED" ]; then
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || die "không có api-key và không lấy được token OIDC (cần permissions: id-token: write)"
  OIDC=$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
          "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${HK_AUDIENCE:-hiraku}" | jq -r .value)
  [ -n "$OIDC" ] && [ "$OIDC" != null ] || die "lấy token OIDC thất bại"
  echo "::add-mask::$OIDC"
  RESP=$(jq -nc --arg t "$OIDC" --arg p "$HK_PROJECT" '{oidc_token:$t, project:$p}' |
         curl -sS -w '\n%{http_code}' -H 'Content-Type: application/json' --data-binary @- "$API/token")
  code=${RESP##*$'\n'}; RESP=${RESP%$'\n'*}
  [ "$code" = 200 ] || die "đổi token thất bại ($code): $(echo "$RESP" | jq -r '.detail // .' 2>/dev/null)"
  CRED=$(echo "$RESP" | jq -r .token)
fi
echo "::add-mask::$CRED"

post() {   # $1 path, $2 body → in "<body>\n<code>"
  local ts sig
  ts=$(date +%s)
  sig=$(hk_sign "$CRED" "$ts" "$2")
  printf '%s' "$2" | curl -sS -w '\n%{http_code}' -X POST "$API$1" \
    -H "Authorization: Bearer $CRED" -H 'Content-Type: application/json' \
    -H "X-Hiraku-Timestamp: $ts" -H "X-Hiraku-Signature: $sig" --data-binary @-
}
get() { curl -fsS -H "Authorization: Bearer $CRED" "$API$1"; }

# ---------- tạo lượt quét
AI=false; [ "${HK_AI:-false}" = "true" ] && AI=true
BODY=$(jq -nc --arg u "$HK_PREVIEW_URL" --argjson p "$PAGES_JSON" --arg s "$SHA" --arg g "$GATE" --argjson ai "$AI" \
        --arg r "${GITHUB_REF:-${CI_COMMIT_REF_NAME:-}}" --arg pr "${HK_PR_NUMBER:-}" \
        '{preview_url:$u, pages:$p, commit_sha:$s, gate:$g, ai:$ai} + (if $r != "" then {ref:$r} else {} end)
         + (if $pr != "" then {pr_number:($pr|tonumber)} else {} end)')
RESP=$(post /scans "$BODY")
code=${RESP##*$'\n'}; RESP=${RESP%$'\n'*}
case "$code" in 200|202) ;; *) die "tạo lượt quét thất bại ($code): $(echo "$RESP" | jq -r '.detail // .' 2>/dev/null)";; esac
SCAN=$(echo "$RESP" | jq -r .scan_id)
echo "HIRAKU: lượt quét $SCAN — $(echo "$PAGES_JSON" | jq length) trang, chế độ $GATE$( [ "$AI" = true ] && echo ', AI góp ý' )"

# ---------- chờ kết quả
start=$(date +%s)
while :; do
  ST=$(get "/scans/$SCAN")
  status=$(echo "$ST" | jq -r .status)
  [ "$status" = DONE ] || [ "$status" = ERROR ] && break
  [ $(( $(date +%s) - start )) -gt "$TIMEOUT" ] && die "quá thời gian chờ ($status)"
  sleep 10
done
[ "$status" = ERROR ] && die "$(echo "$ST" | jq -r '.error') Trang lỗi: $(echo "$ST" | jq -c '.error_pages // []')"

REPORT=$(get "/scans/$SCAN/report")
get "/scans/$SCAN/report?format=sarif" > "$SARIF"
if [ -n "${HK_SITE_DIR:-}" ]; then   # trỏ Code scanning tới đúng tệp trong repo: "/" → <site-dir>/index.html
  jq --arg d "${HK_SITE_DIR%/}/" '(.runs[].results[].locations[].physicalLocation.artifactLocation.uri) |= ($d + (if endswith("/") then . + "index.html" else . end))' \
    "$SARIF" > "$SARIF.tmp" && mv "$SARIF.tmp" "$SARIF"
fi
GATE_RES=$(echo "$REPORT" | jq -r .gate)
PORTAL=$(echo "$REPORT" | jq -r .portal_url)

# ---------- tóm tắt
SUMMARY=$(echo "$REPORT" | jq -r '
  "## HIRAKU · JIS X 8341-3 — \(.gate)\n",
  "| Không đạt (máy ghi) | Máy gợi ý | AI nghi không đạt | Cần chuyên gia | Mới so với mốc | Trang lỗi |",
  "|---|---|---|---|---|---|",
  "| \(.summary.auto_fail) | \(.summary.warn) | \(.summary.ai_suspect // 0) | \(.summary.needs_expert) | \(.summary.new_vs_baseline) | \(.summary.pages_error) |\n",
  (if (.ai // {}).requested then "AI góp ý: \(.ai.status)\(if .ai.cost_jpy != null then " · ¥\(.ai.cost_jpy) / ¥\(.ai.budget_jpy)" else "" end) — chỉ ghi chú, không chặn merge.\n" else empty end),
  (.findings | map(select(.result != "NEEDS_EXPERT")) | .[:30][] |
    "- **\(.result)** \(.criterion) `\(.page)` \(if .selector then "`" + .selector + "`" else "" end)\(if .new then " · mới" else "" end)"),
  "\nMục cần chuyên gia: xem trên cổng HIRAKU — \(.portal_url)",
  "\n_AI không tự chặn merge. Chỉ 3 tiêu chí máy ghi (1.4.2, 1.4.3, 4.1.1) chặn ở chế độ standard._"')
echo "$SUMMARY"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$SUMMARY" >> "$GITHUB_STEP_SUMMARY"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "gate=$GATE_RES"; echo "scan_id=$SCAN"; echo "portal_url=$PORTAL"; } >> "$GITHUB_OUTPUT"
fi

# ---------- mốc nhánh chính
if [ "${HK_BASELINE:-false}" = "true" ]; then
  RESP=$(post /baselines "$(jq -nc --arg s "$SCAN" '{scan_id:$s}')")
  [ "${RESP##*$'\n'}" = 200 ] && echo "HIRAKU: đã đặt lượt quét này làm mốc." || echo "::warning::HIRAKU: không đặt được mốc"
fi

[ "$GATE_RES" = FAIL ] && { echo "::error::HIRAKU: không đạt — $PORTAL"; exit 1; }
exit 0
