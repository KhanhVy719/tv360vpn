#!/bin/bash
# ============================================================
# NPV Tunnel + TV360 Free Data - VPS Server Setup
# Dùng cho: 4G/5G Viettel free data qua SNI livestream2.tv360.vn
# OS: Ubuntu 20.04 / 22.04 / 24.04
# Usage: sudo bash setup-server.sh
# ============================================================

set -e

# ======================== CONFIG ============================
V2RAY_PORT=443          # Port chính (443 để bypass DPI)
V2RAY_WS_PORT=10086     # Port V2Ray internal (WebSocket)
SSH_WS_PORT=8080        # Port SSH WebSocket (stunnel/websocket)
WS_PATH="/tv360stream"  # WebSocket path (giả dạng stream path)
UUID=""                 # Để trống = tự sinh
SNI_HOST="livestream2.tv360.vn"   # SNI host cho free data
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
print_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
print_err() { echo -e "${RED}[✗]${NC} $1"; }

header() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Check root
if [ "$EUID" -ne 0 ]; then
    print_err "Chạy với quyền root: sudo bash $0"
    exit 1
fi

header "NPV TUNNEL + TV360 FREE DATA SETUP"

# Get server IP
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null || echo "UNKNOWN")
print_info "Server IP: $SERVER_IP"

# Generate UUID
if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
fi
print_info "UUID: $UUID"

# ======================== INSTALL ============================
header "1. CÀI ĐẶT PACKAGES"

apt update -y
apt install -y curl wget unzip nginx socat ufw jq openssl stunnel4 python3

# Install V2Ray
print_info "Cài đặt V2Ray..."
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
print_ok "V2Ray đã cài đặt"

# ======================== V2RAY CONFIG =======================
header "2. CẤU HÌNH V2RAY"

mkdir -p /var/log/v2ray
cat > /usr/local/etc/v2ray/config.json <<EOF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/v2ray/access.log",
        "error": "/var/log/v2ray/error.log"
    },
    "inbounds": [
        {
            "port": ${V2RAY_WS_PORT},
            "listen": "127.0.0.1",
            "protocol": "vmess",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "alterId": 0
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "${WS_PATH}",
                    "headers": {
                        "Host": "${SNI_HOST}"
                    }
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4"
            },
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "settings": {},
            "tag": "blocked"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "blocked"
            }
        ]
    }
}
EOF

print_ok "V2Ray config đã tạo"

# ======================== SELF-SIGNED SSL ====================
header "3. TẠO SSL CERTIFICATE"

# Tạo self-signed cert giả dạng TV360
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/tv360.key \
    -out /etc/nginx/ssl/tv360.crt \
    -subj "/C=VN/ST=Hanoi/L=Hanoi/O=TV360/CN=${SNI_HOST}" \
    2>/dev/null

print_ok "SSL certificate đã tạo (CN=${SNI_HOST})"

# ======================== NGINX CONFIG =======================
header "4. CẤU HÌNH NGINX"

cat > /etc/nginx/sites-available/tv360-tunnel <<'NGINXEOF'
# NPV Tunnel - TV360 SNI Tunneling
# Port 443 với SSL giả dạng TV360

server {
    listen 443 ssl http2;
    server_name _;

    # SSL cert giả dạng livestream2.tv360.vn
    ssl_certificate /etc/nginx/ssl/tv360.crt;
    ssl_certificate_key /etc/nginx/ssl/tv360.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # V2Ray WebSocket tunnel
    location WS_PATH_PLACEHOLDER {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:V2RAY_WS_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Long-lived connection cho VPN tunnel
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Trang mặc định (giả dạng trang bình thường)
    location / {
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }
}

# Port 80 - redirect và backup tunnel
server {
    listen 80;
    server_name _;

    # V2Ray WebSocket tunnel (backup không TLS)
    location WS_PATH_PLACEHOLDER {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:V2RAY_WS_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
NGINXEOF

# Replace placeholders
sed -i "s|WS_PATH_PLACEHOLDER|${WS_PATH}|g" /etc/nginx/sites-available/tv360-tunnel
sed -i "s|V2RAY_WS_PORT_PLACEHOLDER|${V2RAY_WS_PORT}|g" /etc/nginx/sites-available/tv360-tunnel

# Enable site
ln -sf /etc/nginx/sites-available/tv360-tunnel /etc/nginx/sites-enabled/tv360-tunnel
rm -f /etc/nginx/sites-enabled/default

nginx -t
print_ok "Nginx đã cấu hình (port 80 + 443 SSL)"

# ======================== SSH WEBSOCKET ======================
header "5. CẤU HÌNH SSH WEBSOCKET"

# Install python websocket proxy cho SSH tunneling
cat > /usr/local/bin/ssh-ws-proxy.py <<'PYEOF'
#!/usr/bin/env python3
"""SSH WebSocket Proxy - cho NPV Tunnel SSH mode"""
import socket
import threading
import sys
import hashlib
import base64
import struct

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
SSH_HOST = "127.0.0.1"
SSH_PORT = 22

def handle_client(client_socket):
    try:
        # Đọc HTTP CONNECT request
        data = client_socket.recv(4096).decode('utf-8', errors='ignore')

        if 'CONNECT' in data or 'HTTP' in data:
            # Trả lời HTTP 200 cho CONNECT method
            response = "HTTP/1.1 200 Connection Established\r\n\r\n"
            client_socket.send(response.encode())

            # Kết nối tới SSH server
            ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            ssh_socket.connect((SSH_HOST, SSH_PORT))

            # Relay traffic 2 chiều
            def forward(src, dst):
                try:
                    while True:
                        data = src.recv(8192)
                        if not data:
                            break
                        dst.sendall(data)
                except:
                    pass
                finally:
                    src.close()
                    dst.close()

            t1 = threading.Thread(target=forward, args=(client_socket, ssh_socket))
            t2 = threading.Thread(target=forward, args=(ssh_socket, client_socket))
            t1.daemon = True
            t2.daemon = True
            t1.start()
            t2.start()
            t1.join()
        else:
            client_socket.close()
    except Exception as e:
        try:
            client_socket.close()
        except:
            pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", LISTEN_PORT))
    server.listen(100)
    print(f"[SSH-WS] Listening on port {LISTEN_PORT}")

    while True:
        client, addr = server.accept()
        t = threading.Thread(target=handle_client, args=(client,))
        t.daemon = True
        t.start()

if __name__ == "__main__":
    main()
PYEOF

chmod +x /usr/local/bin/ssh-ws-proxy.py

# Create systemd service cho SSH WS Proxy
cat > /etc/systemd/system/ssh-ws-proxy.service <<EOF
[Unit]
Description=SSH WebSocket Proxy for NPV Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-ws-proxy.py ${SSH_WS_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

print_ok "SSH WebSocket Proxy đã cấu hình trên port ${SSH_WS_PORT}"

# ======================== FIREWALL ===========================
header "6. FIREWALL"

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow ${SSH_WS_PORT}/tcp
ufw --force enable

print_ok "Firewall đã mở ports: 22, 80, 443, ${SSH_WS_PORT}"

# ======================== START ALL ==========================
header "7. KHỞI ĐỘNG SERVICES"

systemctl daemon-reload

# V2Ray
systemctl enable v2ray
systemctl restart v2ray
sleep 1
if systemctl is-active --quiet v2ray; then
    print_ok "V2Ray ✓"
else
    print_err "V2Ray ✗ - kiểm tra: journalctl -u v2ray -n 20"
fi

# Nginx
systemctl enable nginx
systemctl restart nginx
sleep 1
if systemctl is-active --quiet nginx; then
    print_ok "Nginx ✓"
else
    print_err "Nginx ✗ - kiểm tra: journalctl -u nginx -n 20"
fi

# SSH WS Proxy
systemctl enable ssh-ws-proxy
systemctl restart ssh-ws-proxy
sleep 1
if systemctl is-active --quiet ssh-ws-proxy; then
    print_ok "SSH-WS-Proxy ✓"
else
    print_err "SSH-WS-Proxy ✗"
fi

# ======================== OUTPUT =============================
header "✅ CÀI ĐẶT HOÀN TẤT"

echo ""
echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│      THÔNG TIN KẾT NỐI NPV TUNNEL          │${NC}"
echo -e "${BOLD}${CYAN}├─────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│${NC} Server IP    : ${GREEN}${SERVER_IP}${NC}"
echo -e "${CYAN}│${NC}"
echo -e "${CYAN}│${NC} ${BOLD}── CÁCH 1: V2Ray (Khuyến nghị) ──${NC}"
echo -e "${CYAN}│${NC} Protocol     : ${GREEN}VMess${NC}"
echo -e "${CYAN}│${NC} Port         : ${GREEN}443${NC}"
echo -e "${CYAN}│${NC} UUID         : ${GREEN}${UUID}${NC}"
echo -e "${CYAN}│${NC} Network      : ${GREEN}WebSocket (ws)${NC}"
echo -e "${CYAN}│${NC} WS Path      : ${GREEN}${WS_PATH}${NC}"
echo -e "${CYAN}│${NC} TLS          : ${GREEN}tls${NC}"
echo -e "${CYAN}│${NC} SNI          : ${GREEN}${SNI_HOST}${NC}"
echo -e "${CYAN}│${NC} AlterId      : ${GREEN}0${NC}"
echo -e "${CYAN}│${NC}"
echo -e "${CYAN}│${NC} ${BOLD}── CÁCH 2: SSH Tunnel ──${NC}"
echo -e "${CYAN}│${NC} SSH Host     : ${GREEN}${SERVER_IP}${NC}"
echo -e "${CYAN}│${NC} SSH Port     : ${GREEN}22${NC}"
echo -e "${CYAN}│${NC} WS Port      : ${GREEN}${SSH_WS_PORT}${NC}"
echo -e "${CYAN}│${NC} SNI/Proxy    : ${GREEN}${SNI_HOST}${NC}"
echo -e "${CYAN}│${NC} Username     : ${GREEN}root (hoặc user SSH)${NC}"
echo -e "${CYAN}│${NC}"
echo -e "${CYAN}│${NC} ${BOLD}── CÁCH 3: V2Ray không TLS (backup) ──${NC}"
echo -e "${CYAN}│${NC} Port         : ${GREEN}80${NC}"
echo -e "${CYAN}│${NC} TLS          : ${GREEN}none${NC}"
echo -e "${CYAN}│${NC} Còn lại      : ${GREEN}giống Cách 1${NC}"
echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────┘${NC}"

# Generate VMess link
VMESS_JSON=$(echo -n "{\"v\":\"2\",\"ps\":\"TV360-FreeData\",\"add\":\"${SERVER_IP}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${SNI_HOST}\",\"path\":\"${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${SNI_HOST}\"}" | base64 -w 0)

echo ""
echo -e "${BOLD}${CYAN}=== VMESS IMPORT LINK (copy vào NPV Tunnel) ===${NC}"
echo -e "${GREEN}vmess://${VMESS_JSON}${NC}"
echo ""

# Save info
cat > /root/npv-tv360-info.txt <<INFOEOF
================================================
NPV TUNNEL + TV360 FREE DATA
Setup date: $(date)
================================================

Server IP    : ${SERVER_IP}

=== V2RAY (Cách 1 - Khuyến nghị) ===
Protocol     : VMess
Port         : 443
UUID         : ${UUID}
Network      : WebSocket (ws)
WS Path      : ${WS_PATH}
TLS          : tls
SNI          : ${SNI_HOST}
AlterId      : 0

VMess Link   : vmess://${VMESS_JSON}

=== SSH TUNNEL (Cách 2) ===
SSH Host     : ${SERVER_IP}
SSH Port     : 22
WS Port      : ${SSH_WS_PORT}
SNI/Proxy    : ${SNI_HOST}

=== CẤU HÌNH NPV TUNNEL APP ===
1. Mở NPV Tunnel
2. Thêm config mới > chọn V2Ray
3. Paste VMess link ở trên HOẶC nhập thủ công
4. Quan trọng: SNI phải là ${SNI_HOST}
5. Bật kết nối trên mạng 4G/5G Viettel

=== QUẢN LÝ ===
Restart all  : systemctl restart v2ray nginx ssh-ws-proxy
V2Ray logs   : journalctl -u v2ray -f
Nginx logs   : tail -f /var/log/nginx/error.log
Status       : systemctl status v2ray nginx ssh-ws-proxy
================================================
INFOEOF

echo -e "${YELLOW}Thông tin đã lưu: /root/npv-tv360-info.txt${NC}"
echo ""
print_ok "Sẵn sàng sử dụng!"
