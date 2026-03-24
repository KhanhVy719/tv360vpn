#!/bin/bash
# ============================================================
# Tạo nhiều backup config với SNI khác nhau
# Chạy trên VPS sau khi setup-server.sh
# Usage: sudo bash gen-backups.sh
# ============================================================

SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "79.108.225.33")
WS_PATH="/tv360stream"
BACKUP_DIR="/root/npv-backups"
mkdir -p "$BACKUP_DIR"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Đọc UUID từ V2Ray config
if [ -f /usr/local/etc/v2ray/config.json ]; then
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' /usr/local/etc/v2ray/config.json)
else
    UUID="${1:-850c5d90-11b2-4b73-85bd-23e890458354}"
fi

# Danh sách SNI backup (từ kết quả scan, HTTP✓)
BACKUP_SNIS=(
    "livestream2.tv360.vn"
    "live.tv360.vn"
    "live-cdn1.tv360.vn"
    "live-ali2.tv360.vn"
    "live-ali4.tv360.vn"
    "live-zlr1.tv360.vn"
    "live-sdrm.tv360.vn"
    "videoakm1.tv360.vn"
    "videoakm.tv360.vn"
    "videoakam1.tv360.vn"
    "m.tv360.vn"
    "tv360.vn"
    "api.tv360.vn"
    "ws.tv360.vn"
    "cdn.tv360.vn"
    "mobifoneakm1.tv360.vn"
)

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  TẠO BACKUP CONFIGS - ${#BACKUP_SNIS[@]} SNI${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

ALL_LINKS=""
COUNT=0

for SNI in "${BACKUP_SNIS[@]}"; do
    COUNT=$((COUNT + 1))
    LABEL=$(echo "$SNI" | sed 's/\.tv360\.vn//' | sed 's/\./-/g')

    # Tạo VMess link
    VMESS_B64=$(echo -n "{\"v\":\"2\",\"ps\":\"TV360-${LABEL}\",\"add\":\"${SERVER_IP}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${SNI}\",\"path\":\"${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${SNI}\"}" | base64 -w 0)
    VMESS_LINK="vmess://${VMESS_B64}"

    # Tạo file .npv4
    cat > "${BACKUP_DIR}/${COUNT}-${LABEL}.npv4" <<EOF
{
    "NapsternetV": {
        "configType": "v2ray",
        "locked": false,
        "remarks": "TV360-${LABEL}",
        "v2rayConfig": {
            "outbounds": [{
                "protocol": "vmess",
                "settings": {
                    "vnext": [{
                        "address": "${SERVER_IP}",
                        "port": 443,
                        "users": [{"id": "${UUID}", "alterId": 0, "security": "auto"}]
                    }]
                },
                "streamSettings": {
                    "network": "ws",
                    "security": "tls",
                    "wsSettings": {"path": "${WS_PATH}", "headers": {"Host": "${SNI}"}},
                    "tlsSettings": {"serverName": "${SNI}", "allowInsecure": true}
                }
            }]
        }
    }
}
EOF

    # Tạo VMess link không TLS (port 80 backup)
    VMESS_B64_NO_TLS=$(echo -n "{\"v\":\"2\",\"ps\":\"TV360-${LABEL}-noTLS\",\"add\":\"${SERVER_IP}\",\"port\":\"80\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${SNI}\",\"path\":\"${WS_PATH}\",\"tls\":\"\"}" | base64 -w 0)

    ALL_LINKS+="# ${COUNT}. ${SNI} (TLS)\n${VMESS_LINK}\n\n"
    ALL_LINKS+="# ${COUNT}b. ${SNI} (no TLS)\nvmess://${VMESS_B64_NO_TLS}\n\n"

    echo -e "  ${GREEN}✓${NC} ${COUNT}. ${SNI}"
done

# Lưu tất cả VMess links vào 1 file
echo -e "$ALL_LINKS" > "${BACKUP_DIR}/all-vmess-links.txt"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Đã tạo ${COUNT} backup configs!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Files: ${CYAN}${BACKUP_DIR}/${NC}"
echo -e "  Links: ${CYAN}${BACKUP_DIR}/all-vmess-links.txt${NC}"
echo ""
echo -e "  ${CYAN}Cách dùng:${NC}"
echo -e "  1. Copy file .npv4 vào điện thoại → NPV Tunnel → Import"
echo -e "  2. Hoặc copy VMess link từ all-vmess-links.txt"
echo -e "  3. Nếu SNI #1 không kết nối → thử #2, #3, ..."
echo ""
