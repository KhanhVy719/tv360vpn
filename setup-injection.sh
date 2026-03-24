#!/bin/bash
# ============================================================
# HTTP Injection Setup - Bypass DPI không cần Cloudflare
# Chạy trên VPS sau setup-server.sh
# Usage: sudo bash setup-injection.sh
# ============================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null)
SNI="livestream2.tv360.vn"
WS_PATH="/tv360stream"

# Đọc UUID từ config
UUID=$(jq -r '.inbounds[0].settings.clients[0].id' /usr/local/etc/v2ray/config.json 2>/dev/null)
if [ -z "$UUID" ] || [ "$UUID" = "null" ]; then
    echo "Chưa cài V2Ray. Chạy setup-server.sh trước!"
    exit 1
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  HTTP INJECTION BYPASS SETUP${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# 1. Cấu hình Nginx xử lý HTTP injection
echo -e "\n${CYAN}[1] Cấu hình Nginx cho HTTP Injection...${NC}"

cat > /etc/nginx/sites-available/tv360-injection <<'NGINXEOF'
# HTTP Injection handler
# Nhận request có Host: livestream2.tv360.vn rồi proxy tới V2Ray

server {
    listen 80;
    listen 8080;
    server_name _;

    # Xử lý cả request thường và WebSocket upgrade
    location / {
        # Nếu là WebSocket upgrade → proxy tới V2Ray
        if ($http_upgrade = "websocket") {
            # handled by @websocket below
        }

        # Request thường → trả 200 giả TV360
        add_header Content-Type text/html;
        return 200 '<html><title>TV360</title><body>TV360 Livestream</body></html>';
    }

    location WS_PATH_PLACEHOLDER {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:V2RAY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}

# HTTPS handler
server {
    listen 443 ssl http2;
    server_name _;

    ssl_certificate /etc/nginx/ssl/tv360.crt;
    ssl_certificate_key /etc/nginx/ssl/tv360.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location WS_PATH_PLACEHOLDER {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:V2RAY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        add_header Content-Type application/json;
        return 200 '{"status":"ok","service":"tv360"}';
    }
}
NGINXEOF

# Thay placeholder
V2RAY_PORT=$(jq -r '.inbounds[0].port' /usr/local/etc/v2ray/config.json)
sed -i "s|WS_PATH_PLACEHOLDER|${WS_PATH}|g" /etc/nginx/sites-available/tv360-injection
sed -i "s|V2RAY_PORT_PLACEHOLDER|${V2RAY_PORT}|g" /etc/nginx/sites-available/tv360-injection

# Enable
rm -f /etc/nginx/sites-enabled/tv360-tunnel 2>/dev/null
ln -sf /etc/nginx/sites-available/tv360-injection /etc/nginx/sites-enabled/tv360-injection
nginx -t && systemctl restart nginx

echo -e "${GREEN}[✓] Nginx đã cấu hình xử lý HTTP Injection${NC}"

# 2. Mở thêm ports
echo -e "\n${CYAN}[2] Mở ports...${NC}"
ufw allow 8080/tcp
ufw allow 8443/tcp
echo -e "${GREEN}[✓] Ports 80, 443, 8080, 8443 đã mở${NC}"

# 3. Tạo các VMess link với injection
echo -e "\n${CYAN}[3] Tạo VMess links...${NC}"

mkdir -p /root/npv-injection

# Các combo cần thử
CONFIGS=(
    "443:tls:Injection-TLS-443"
    "80::Injection-HTTP-80"
    "8080::Injection-HTTP-8080"
)

echo "" > /root/npv-injection/all-links.txt

for cfg in "${CONFIGS[@]}"; do
    IFS=':' read -r port tls name <<< "$cfg"

    VMESS_B64=$(echo -n "{\"v\":\"2\",\"ps\":\"${name}\",\"add\":\"${SERVER_IP}\",\"port\":\"${port}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${SNI}\",\"path\":\"${WS_PATH}\",\"tls\":\"${tls}\",\"sni\":\"${SNI}\"}" | base64 -w 0)

    echo -e "  ${GREEN}✓${NC} ${name} (port ${port})"
    echo "# ${name}" >> /root/npv-injection/all-links.txt
    echo "vmess://${VMESS_B64}" >> /root/npv-injection/all-links.txt
    echo "" >> /root/npv-injection/all-links.txt
done

# 4. Output
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  SETUP HOÀN TẤT!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}=== CẤU HÌNH NPV TUNNEL - HTTP INJECTION ===${NC}"
echo ""
echo -e "  ${YELLOW}Mở NPV Tunnel → V2Ray → Thêm mới:${NC}"
echo ""
echo -e "  Address    : ${GREEN}${SERVER_IP}${NC}"
echo -e "  Port       : ${GREEN}80${NC} (hoặc 8080, 443)"
echo -e "  UUID       : ${GREEN}${UUID}${NC}"
echo -e "  Network    : ${GREEN}ws${NC}"
echo -e "  WS Path    : ${GREEN}${WS_PATH}${NC}"
echo -e "  WS Host    : ${GREEN}${SNI}${NC}"
echo -e "  TLS        : ${GREEN}none${NC} (port 80/8080) hoặc ${GREEN}tls${NC} (port 443)"
echo -e "  SNI        : ${GREEN}${SNI}${NC}"
echo ""
echo -e "  ${YELLOW}Phần QUAN TRỌNG - Custom Payload:${NC}"
echo -e "  ${GREEN}GET / HTTP/1.1[crlf]Host: ${SNI}[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]${NC}"
echo ""
echo -e "  Links: ${CYAN}/root/npv-injection/all-links.txt${NC}"
echo ""
cat /root/npv-injection/all-links.txt
echo ""
echo -e "${YELLOW}Thử lần lượt: port 80 → 8080 → 443${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
