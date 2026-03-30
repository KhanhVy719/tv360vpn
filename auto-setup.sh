#!/bin/bash
# ============================================================
# NPV Tunnel - Auto Setup (V2Ray + SSH + HTTP Injection)
# Chạy 1 lần trên VPS, tự tạo link import vào NPV Tunnel
# Usage: sudo bash auto-setup.sh
# ============================================================

set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SNI="livestream2.tv360.vn"
WS_PATH="/tv360stream"
SSH_WS_PORT=8080
INFO_FILE="/root/npv-info.txt"
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null)

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  NPV TUNNEL AUTO SETUP${NC}"
echo -e "${CYAN}  IP: ${SERVER_IP}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ======================== 1. CÀI PACKAGES ========================
echo -e "\n${CYAN}[1/6] Cài packages...${NC}"
apt update -y
apt install -y curl jq nginx openssl uuid-runtime python3

# ======================== 2. CÀI V2RAY ========================
echo -e "\n${CYAN}[2/6] Cài V2Ray...${NC}"
if ! command -v v2ray &>/dev/null; then
    bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
fi

# Tạo UUID
UUID=$(uuidgen)

# Config V2Ray
cat > /usr/local/etc/v2ray/config.json << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "port": 10086,
            "listen": "127.0.0.1",
            "protocol": "vmess",
            "settings": {
                "clients": [{"id": "${UUID}", "alterId": 0}]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "${WS_PATH}",
                    "headers": {"Host": "${SNI}"}
                }
            }
        }
    ],
    "outbounds": [
        {"protocol": "freedom"},
        {"protocol": "blackhole", "tag": "blocked"}
    ]
}
EOF

systemctl enable v2ray
systemctl restart v2ray
echo -e "${GREEN}[✓] V2Ray OK${NC}"

# ======================== 3. SSL CERT ========================
echo -e "\n${CYAN}[3/6] Tạo SSL cert...${NC}"
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/tv360.key \
    -out /etc/nginx/ssl/tv360.crt \
    -subj "/CN=${SNI}" 2>/dev/null
echo -e "${GREEN}[✓] SSL OK${NC}"

# ======================== 4. NGINX ========================
echo -e "\n${CYAN}[4/6] Cấu hình Nginx...${NC}"

# Xóa config cũ
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-enabled/tv360-*

cat > /etc/nginx/sites-available/npv-tunnel << 'NGINXEOF'
# Port 80 - HTTP (cho HTTP Injection)
server {
    listen 80;
    server_name _;

    location WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10086;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        add_header Content-Type text/html;
        return 200 '<html><title>TV360</title><body>OK</body></html>';
    }
}

# Port 443 - HTTPS + TLS
server {
    listen 443 ssl http2;
    server_name _;

    ssl_certificate /etc/nginx/ssl/tv360.crt;
    ssl_certificate_key /etc/nginx/ssl/tv360.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10086;
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
sed -i "s|WS_PATH|${WS_PATH}|g" /etc/nginx/sites-available/npv-tunnel

ln -sf /etc/nginx/sites-available/npv-tunnel /etc/nginx/sites-enabled/npv-tunnel
nginx -t && systemctl restart nginx
echo -e "${GREEN}[✓] Nginx OK${NC}"

# ======================== 5. SSH WS PROXY ========================
echo -e "\n${CYAN}[5/6] SSH WebSocket Proxy...${NC}"

cat > /usr/local/bin/ssh-ws-proxy.py << 'PYEOF'
import socket, threading, sys

def handle(client):
    try:
        data = client.recv(4096)
        if b"HTTP" in data:
            client.send(b"HTTP/1.1 200 OK\r\n\r\n")
        ssh = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh.connect(("127.0.0.1", 22))
        def forward(src, dst):
            try:
                while True:
                    d = src.recv(4096)
                    if not d: break
                    dst.send(d)
            except: pass
            finally:
                src.close()
                dst.close()
        threading.Thread(target=forward, args=(client, ssh), daemon=True).start()
        forward(ssh, client)
    except:
        client.close()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", port))
server.listen(50)
print(f"SSH-WS Proxy on port {port}")
while True:
    client, addr = server.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PYEOF

# Systemd service
cat > /etc/systemd/system/ssh-ws-proxy.service << EOF
[Unit]
Description=SSH WebSocket Proxy
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-ws-proxy.py ${SSH_WS_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ssh-ws-proxy
systemctl restart ssh-ws-proxy
echo -e "${GREEN}[✓] SSH-WS Proxy OK (port ${SSH_WS_PORT})${NC}"

# ======================== 6. FIREWALL ========================
echo -e "\n${CYAN}[6/6] Firewall...${NC}"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow ${SSH_WS_PORT}/tcp
echo "y" | ufw enable 2>/dev/null
echo -e "${GREEN}[✓] Firewall OK${NC}"

# ======================== TẠO LINKS ========================

# VMess links
VMESS_443=$(echo -n "{\"v\":\"2\",\"ps\":\"NPV-TLS-443\",\"add\":\"${SERVER_IP}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${SNI}\",\"path\":\"${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${SNI}\"}" | base64 -w 0)

VMESS_80=$(echo -n "{\"v\":\"2\",\"ps\":\"NPV-HTTP-80\",\"add\":\"${SERVER_IP}\",\"port\":\"80\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${SNI}\",\"path\":\"${WS_PATH}\",\"tls\":\"\"}" | base64 -w 0)

# Lưu info
cat > "$INFO_FILE" << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  NPV TUNNEL - THÔNG TIN KẾT NỐI
  Server: ${SERVER_IP}
  Created: $(date)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

=== CÁCH 1: V2Ray + TLS (port 443) ===
vmess://${VMESS_443}

=== CÁCH 2: V2Ray + HTTP Injection (port 80) ===
vmess://${VMESS_80}

=== CÁCH 3: SSH + HTTP Injection ===
SSH Host    : ${SERVER_IP}
SSH Port    : 22
WS Port     : ${SSH_WS_PORT}
SNI         : ${SNI}
Payload     : GET / HTTP/1.1[crlf]Host: ${SNI}[crlf][crlf]

=== CÁCH 4: SSH + CONNECT Injection ===
SSH Host    : ${SERVER_IP}
SSH Port    : 22
WS Port     : ${SSH_WS_PORT}
SNI         : ${SNI}
Payload     : CONNECT [host_port] HTTP/1.1[crlf]Host: ${SNI}[crlf][crlf]

=== THÔNG TIN CHI TIẾT ===
UUID        : ${UUID}
WS Path     : ${WS_PATH}
SNI         : ${SNI}
V2Ray Port  : 10086 (internal)
SSH-WS Port : ${SSH_WS_PORT}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# ======================== OUTPUT ========================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ CÀI ĐẶT HOÀN TẤT!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}=== CÁCH 1: V2Ray TLS 443 (copy VMess link) ===${NC}"
echo -e "vmess://${VMESS_443}"
echo ""
echo -e "${YELLOW}=== CÁCH 2: V2Ray HTTP 80 (copy VMess link) ===${NC}"
echo -e "vmess://${VMESS_80}"
echo ""
echo -e "${YELLOW}=== CÁCH 3: SSH + Injection ===${NC}"
echo -e "  Host    : ${GREEN}${SERVER_IP}${NC}"
echo -e "  Port    : ${GREEN}22${NC}"
echo -e "  WS Port : ${GREEN}${SSH_WS_PORT}${NC}"
echo -e "  Payload : ${GREEN}GET / HTTP/1.1[crlf]Host: ${SNI}[crlf][crlf]${NC}"
echo ""
echo -e "${CYAN}Hướng dẫn: Copy VMess link → NPV Tunnel → Import → Connect${NC}"
echo -e "${CYAN}Info lưu tại: ${INFO_FILE}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
