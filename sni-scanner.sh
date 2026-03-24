#!/bin/bash
# ============================================================
# SNI Scanner - Tự dò SNI free data cho NPV Tunnel
# Quét danh sách domain để tìm SNI hoạt động trên mạng 4G/5G
#
# Chạy trên ĐIỆN THOẠI (Termux) hoặc máy đang dùng 4G/5G:
#   bash sni-scanner.sh
#
# Chạy trên VPS (test kết nối từ xa):
#   bash sni-scanner.sh --vps
# ============================================================

set -o pipefail

# ======================== CONFIG =============================
VPS_IP="${1:-THAY_IP_VPS}"       # IP VPS của bạn
VPS_PORT=443                      # Port V2Ray trên VPS
TIMEOUT=5                         # Timeout mỗi test (giây)
THREADS=10                        # Số luồng song song
RESULT_FILE="sni-results-$(date +%Y%m%d-%H%M%S).txt"
# =============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ======================== SNI LIST ===========================
# Danh sách SNI phổ biến cho Viettel/Mobi/Vina
SNI_LIST=(
    # === TV360 (Viettel) ===
    "tv360.vn"
    "livestream.tv360.vn"
    "livestream2.tv360.vn"
    "livestream3.tv360.vn"
    "api.tv360.vn"
    "cdn.tv360.vn"
    "static.tv360.vn"
    "stream.tv360.vn"
    "m.tv360.vn"
    "app.tv360.vn"

    # === Viettel ===
    "viettel.vn"
    "vietteltelecom.vn"
    "viettelpost.vn"
    "my.viettel.vn"
    "mocha.vn"
    "data.viettel.vn"
    "id.viettel.vn"

    # === Mocha / Viettel Media ===
    "mocha.com.vn"
    "cdn.mocha.com.vn"
    "api.mocha.com.vn"

    # === VNPT / VinaPhone ===
    "vnpt.vn"
    "vinaphone.vn"
    "my.vinaphone.vn"

    # === MobiFone ===
    "mobifone.vn"
    "my.mobifone.vn"
    "cliptv.vn"

    # === Phổ biến khác ===
    "zalo.vn"
    "zalo.me"
    "chat.zalo.me"
    "cdn.zalo.me"
    "tiktok.com"
    "www.tiktok.com"
    "m.tiktok.com"
    "facebook.com"
    "m.facebook.com"
    "youtube.com"
    "m.youtube.com"
    "google.com"
    "play.google.com"
    "speedtest.vn"
    "speedtest.net"
    "fast.com"

    # === CDN phổ biến ===
    "cloudflare.com"
    "cdn.cloudflare.com"
    "akamai.net"
    "cloudfront.net"
    "fastly.net"
    "fbcdn.net"
    "googlevideo.com"
)

# ======================== FUNCTIONS ==========================

check_deps() {
    local missing=()
    for cmd in curl openssl timeout; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Thiếu: ${missing[*]}${NC}"
        echo "Cài đặt: apt install -y curl openssl coreutils"
        exit 1
    fi
}

# Test 1: DNS resolve
test_dns() {
    local sni="$1"
    local result=$(timeout ${TIMEOUT} nslookup "$sni" 2>/dev/null | grep -c "Address")
    [ "$result" -gt 1 ] && return 0 || return 1
}

# Test 2: TLS handshake với SNI
test_tls_handshake() {
    local sni="$1"
    local host="$2"
    local port="$3"
    timeout ${TIMEOUT} openssl s_client -connect "${host}:${port}" \
        -servername "${sni}" \
        -brief 2>/dev/null </dev/null | grep -qi "connected\|established"
    return $?
}

# Test 3: HTTP CONNECT qua SNI (carrier test)
test_http_connect() {
    local sni="$1"
    local result=$(timeout ${TIMEOUT} curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout ${TIMEOUT} \
        -H "Host: ${sni}" \
        "http://${sni}/" 2>/dev/null)
    [ "$result" != "000" ] && return 0 || return 1
}

# Test 4: WebSocket qua SNI tới VPS
test_ws_to_vps() {
    local sni="$1"
    if [ "$VPS_IP" = "THAY_IP_VPS" ]; then
        return 2  # Skip
    fi
    timeout ${TIMEOUT} curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout ${TIMEOUT} \
        -H "Host: ${sni}" \
        -H "Upgrade: websocket" \
        -H "Connection: Upgrade" \
        "http://${VPS_IP}:${VPS_PORT}/tv360stream" 2>/dev/null | grep -q "101\|200\|400"
    return $?
}

# Test 5: Đo data free (gửi request nhỏ, kiểm tra data usage không tăng)
test_zero_rating() {
    local sni="$1"
    # Gửi request nhỏ với SNI header, nếu status OK = có thể free
    local code=$(timeout ${TIMEOUT} curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout ${TIMEOUT} \
        --resolve "${sni}:443:${sni}" \
        "https://${sni}/" 2>/dev/null)
    [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ] && return 0 || return 1
}

scan_sni() {
    local sni="$1"
    local score=0
    local details=""

    # Test DNS
    if test_dns "$sni" 2>/dev/null; then
        score=$((score + 1))
        details+="DNS✓ "
    else
        details+="DNS✗ "
    fi

    # Test HTTP
    if test_http_connect "$sni" 2>/dev/null; then
        score=$((score + 1))
        details+="HTTP✓ "
    else
        details+="HTTP✗ "
    fi

    # Test TLS
    if test_tls_handshake "$sni" "$sni" 443 2>/dev/null; then
        score=$((score + 1))
        details+="TLS✓ "
    else
        details+="TLS✗ "
    fi

    # Test Zero-rating
    if test_zero_rating "$sni" 2>/dev/null; then
        score=$((score + 1))
        details+="ZR✓ "
    else
        details+="ZR✗ "
    fi

    # Test VPS connection
    if [ "$VPS_IP" != "THAY_IP_VPS" ]; then
        if test_ws_to_vps "$sni" 2>/dev/null; then
            score=$((score + 1))
            details+="VPS✓"
        else
            details+="VPS✗"
        fi
    fi

    # Output result
    local status_icon=""
    local color=""
    if [ $score -ge 4 ]; then
        status_icon="🟢"
        color="$GREEN"
    elif [ $score -ge 2 ]; then
        status_icon="🟡"
        color="$YELLOW"
    else
        status_icon="🔴"
        color="$RED"
    fi

    echo -e "  ${status_icon} ${color}${sni}${NC}  [${score}/5] ${details}"
    echo "${score} ${sni} ${details}" >> "$RESULT_FILE"
}

# ======================== MAIN ===============================

check_deps

echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${CYAN}  SNI SCANNER - Dò SNI Free Data cho NPV Tunnel${NC}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Tổng SNI    : ${GREEN}${#SNI_LIST[@]}${NC} domains"
echo -e "  Timeout     : ${TIMEOUT}s mỗi test"
if [ "$VPS_IP" != "THAY_IP_VPS" ]; then
    echo -e "  VPS IP      : ${GREEN}${VPS_IP}${NC}"
else
    echo -e "  VPS IP      : ${YELLOW}Chưa set (bỏ qua test VPS)${NC}"
fi
echo ""
echo -e "${CYAN}  Tests: DNS | HTTP | TLS | ZeroRating | VPS${NC}"
echo ""

> "$RESULT_FILE"

# Scan từng SNI
for sni in "${SNI_LIST[@]}"; do
    scan_sni "$sni" &

    # Giới hạn số luồng
    while [ $(jobs -r | wc -l) -ge $THREADS ]; do
        sleep 0.1
    done
done

# Đợi tất cả hoàn tất
wait

# ======================== SUMMARY ============================
echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${CYAN}  KẾT QUẢ - TOP SNI HOẠT ĐỘNG${NC}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Sort by score descending
echo -e "  ${GREEN}🟢 Hoạt động tốt (4-5 điểm):${NC}"
sort -rn "$RESULT_FILE" | while read score sni details; do
    if [ "$score" -ge 4 ]; then
        echo -e "     ★ ${GREEN}${sni}${NC}  [${score}/5]  ${details}"
    fi
done

echo ""
echo -e "  ${YELLOW}🟡 Có thể dùng (2-3 điểm):${NC}"
sort -rn "$RESULT_FILE" | while read score sni details; do
    if [ "$score" -ge 2 ] && [ "$score" -lt 4 ]; then
        echo -e "     ○ ${YELLOW}${sni}${NC}  [${score}/5]  ${details}"
    fi
done

echo ""
echo -e "${CYAN}Kết quả lưu tại: ${RESULT_FILE}${NC}"
echo ""
echo -e "${BOLD}Hướng dẫn:${NC}"
echo "  1. Chọn SNI có điểm cao nhất (🟢)"
echo "  2. Sửa SNI trong NPV Tunnel config"
echo "  3. Test thực tế: tắt WiFi, bật 4G, kết nối NPV Tunnel"
echo ""
