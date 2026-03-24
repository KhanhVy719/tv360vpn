#!/bin/bash
# ============================================================
# NPV Tunnel - Tạo config theo Device ID
# Mỗi thiết bị có UUID riêng, server quản lý theo device
# Usage: sudo bash gen-device.sh <device_name>
# ============================================================

CONFIG="/usr/local/etc/v2ray/config.json"
DEVICES_DIR="/root/npv-devices"
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "UNKNOWN")
SNI_HOST="livestream2.tv360.vn"
WS_PATH="/tv360stream"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

mkdir -p "$DEVICES_DIR"

# ==================== FUNCTIONS ==============================

gen_device() {
    local DEVICE_NAME="$1"
    local DEVICE_UUID=$(cat /proc/sys/kernel/random/uuid)

    if [ -z "$DEVICE_NAME" ]; then
        echo -e "${RED}Cần tên thiết bị: bash $0 add <tên>${NC}"
        return 1
    fi

    # Kiểm tra trùng tên
    if [ -f "$DEVICES_DIR/${DEVICE_NAME}.json" ]; then
        echo -e "${RED}Device '${DEVICE_NAME}' đã tồn tại!${NC}"
        return 1
    fi

    # 1. Thêm UUID vào V2Ray server config
    if command -v jq &>/dev/null && [ -f "$CONFIG" ]; then
        local tmp=$(mktemp)
        jq ".inbounds[0].settings.clients += [{\"id\": \"${DEVICE_UUID}\", \"alterId\": 0, \"email\": \"${DEVICE_NAME}@device\"}]" "$CONFIG" > "$tmp"
        mv "$tmp" "$CONFIG"
        systemctl restart v2ray 2>/dev/null
    fi

    # 2. Tạo NPV V2Ray config (.json) cho device
    cat > "$DEVICES_DIR/${DEVICE_NAME}.json" <<EOF
{
    "remarks": "TV360-${DEVICE_NAME}",
    "server": "${SERVER_IP}",
    "server_port": 443,
    "protocol": "vmess",
    "vmess": {
        "id": "${DEVICE_UUID}",
        "alterId": 0,
        "security": "auto"
    },
    "stream": {
        "network": "ws",
        "wsSettings": {
            "path": "${WS_PATH}",
            "headers": {
                "Host": "${SNI_HOST}"
            }
        },
        "security": "tls",
        "tlsSettings": {
            "serverName": "${SNI_HOST}",
            "allowInsecure": true
        }
    }
}
EOF

    # 3. Tạo file .npv4 cho import trực tiếp vào NPV Tunnel
    cat > "$DEVICES_DIR/${DEVICE_NAME}.npv4" <<EOF
{
    "NapsternetV": {
        "configType": "v2ray",
        "locked": false,
        "remarks": "TV360-${DEVICE_NAME}",
        "deviceId": "${DEVICE_NAME}",
        "v2rayConfig": {
            "outbounds": [
                {
                    "protocol": "vmess",
                    "settings": {
                        "vnext": [
                            {
                                "address": "${SERVER_IP}",
                                "port": 443,
                                "users": [
                                    {
                                        "id": "${DEVICE_UUID}",
                                        "alterId": 0,
                                        "security": "auto"
                                    }
                                ]
                            }
                        ]
                    },
                    "streamSettings": {
                        "network": "ws",
                        "security": "tls",
                        "wsSettings": {
                            "path": "${WS_PATH}",
                            "headers": {
                                "Host": "${SNI_HOST}"
                            }
                        },
                        "tlsSettings": {
                            "serverName": "${SNI_HOST}",
                            "allowInsecure": true
                        }
                    }
                }
            ]
        }
    }
}
EOF

    # 4. Tạo VMess link
    local VMESS_B64=$(echo -n "{\"v\":\"2\",\"ps\":\"TV360-${DEVICE_NAME}\",\"add\":\"${SERVER_IP}\",\"port\":\"443\",\"id\":\"${DEVICE_UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${SNI_HOST}\",\"path\":\"${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${SNI_HOST}\"}" | base64 -w 0)

    # 5. Lưu thông tin device
    cat > "$DEVICES_DIR/${DEVICE_NAME}.txt" <<EOF
================================================
DEVICE: ${DEVICE_NAME}
Created: $(date)
================================================

UUID     : ${DEVICE_UUID}
Server   : ${SERVER_IP}:443
SNI      : ${SNI_HOST}
WS Path  : ${WS_PATH}

VMess Link:
vmess://${VMESS_B64}

Files:
  Config JSON : ${DEVICES_DIR}/${DEVICE_NAME}.json
  NPV4 File   : ${DEVICES_DIR}/${DEVICE_NAME}.npv4

Import vào NPV Tunnel:
  - Cách 1: Copy VMess link → NPV Tunnel → Import
  - Cách 2: Copy file .npv4 vào điện thoại → NPV Tunnel → Import file
================================================
EOF

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Device '${DEVICE_NAME}' đã tạo thành công!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  UUID       : ${CYAN}${DEVICE_UUID}${NC}"
    echo -e "  NPV4 file  : ${CYAN}${DEVICES_DIR}/${DEVICE_NAME}.npv4${NC}"
    echo ""
    echo -e "  ${YELLOW}VMess Link:${NC}"
    echo -e "  ${GREEN}vmess://${VMESS_B64}${NC}"
    echo ""
}

list_devices() {
    echo -e "${CYAN}=== Danh sách Devices ===${NC}"
    echo ""

    local count=0
    for f in "$DEVICES_DIR"/*.txt; do
        [ -f "$f" ] || continue
        local name=$(basename "$f" .txt)
        local uuid=$(grep "UUID" "$f" | head -1 | awk -F': ' '{print $2}')
        local created=$(grep "Created" "$f" | awk -F': ' '{print $2}')
        echo -e "  ${GREEN}${name}${NC}"
        echo -e "    UUID    : ${uuid}"
        echo -e "    Created : ${created}"
        echo ""
        count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
        echo -e "  ${YELLOW}Chưa có device nào. Tạo: bash $0 add <tên>${NC}"
    else
        echo -e "  Tổng: ${GREEN}${count}${NC} device(s)"
    fi
}

remove_device() {
    local DEVICE_NAME="$1"
    if [ -z "$DEVICE_NAME" ]; then
        echo -e "${RED}Cần tên: bash $0 remove <tên>${NC}"
        return 1
    fi

    if [ ! -f "$DEVICES_DIR/${DEVICE_NAME}.txt" ]; then
        echo -e "${RED}Device '${DEVICE_NAME}' không tồn tại${NC}"
        return 1
    fi

    # Lấy UUID để xóa khỏi V2Ray
    local uuid=$(grep "UUID" "$DEVICES_DIR/${DEVICE_NAME}.txt" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')

    # Xóa khỏi V2Ray config
    if command -v jq &>/dev/null && [ -f "$CONFIG" ]; then
        local tmp=$(mktemp)
        jq "del(.inbounds[0].settings.clients[] | select(.id == \"${uuid}\"))" "$CONFIG" > "$tmp"
        mv "$tmp" "$CONFIG"
        systemctl restart v2ray 2>/dev/null
    fi

    # Xóa files
    rm -f "$DEVICES_DIR/${DEVICE_NAME}".*

    echo -e "${GREEN}Đã xóa device '${DEVICE_NAME}' (UUID: ${uuid})${NC}"
}

get_link() {
    local DEVICE_NAME="$1"
    if [ -f "$DEVICES_DIR/${DEVICE_NAME}.txt" ]; then
        grep -A1 "VMess Link:" "$DEVICES_DIR/${DEVICE_NAME}.txt" | tail -1
    else
        echo -e "${RED}Device '${DEVICE_NAME}' không tồn tại${NC}"
    fi
}

# ==================== MAIN ===================================
case "${1}" in
    add|new|create)
        gen_device "$2"
        ;;
    remove|delete|rm)
        remove_device "$2"
        ;;
    list|ls)
        list_devices
        ;;
    link|get)
        get_link "$2"
        ;;
    *)
        echo ""
        echo -e "${CYAN}NPV Tunnel - Device Manager${NC}"
        echo ""
        echo "Usage: sudo bash $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  add <name>     Tạo config mới cho device"
        echo "  remove <name>  Xóa device"
        echo "  list           Liệt kê devices"
        echo "  link <name>    Lấy VMess link của device"
        echo ""
        echo "Ví dụ:"
        echo "  sudo bash $0 add iphone14"
        echo "  sudo bash $0 add samsung-a54"
        echo "  sudo bash $0 list"
        echo "  sudo bash $0 link iphone14"
        echo "  sudo bash $0 remove iphone14"
        echo ""
        ;;
esac
