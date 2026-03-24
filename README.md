# TV360 VPN - NPV Tunnel Free Data 4G/5G

Cài đặt V2Ray + SSH Tunnel trên VPS để sử dụng NPV Tunnel với free data 4G/5G Viettel qua SNI `livestream2.tv360.vn`.

## Cách hoạt động

```
📱 Điện thoại (4G/5G)          🌐 Internet
   │                              ▲
   │ SNI: livestream2.tv360.vn    │
   │ (Carrier nghĩ = TV360)       │
   ▼                              │
🖥️ VPS Server ────────────────────┘
   V2Ray / SSH Tunnel
```

## Cài đặt nhanh

```bash
# 1. SSH vào VPS
ssh root@<IP_VPS>

# 2. Tải script
wget https://raw.githubusercontent.com/KhanhVy719/tv360vpn/main/setup-server.sh

# 3. Chạy cài đặt
chmod +x setup-server.sh
sudo bash setup-server.sh

# 4. Copy VMess link hiển thị → paste vào NPV Tunnel
```

## Cấu hình NPV Tunnel

### Cách 1: V2Ray (khuyến nghị)
| Field | Value |
|-------|-------|
| Protocol | VMess |
| Port | 443 |
| Network | WebSocket |
| WS Path | /tv360stream |
| TLS | tls |
| **SNI** | **livestream2.tv360.vn** |
| AllowInsecure | true |

> Hoặc import VMess link được hiển thị sau khi chạy script.

### Cách 2: SSH Tunnel
| Field | Value |
|-------|-------|
| Type | SSH + WebSocket |
| SSH Port | 22 |
| WS Port | 8080 |
| **SNI** | **livestream2.tv360.vn** |

## Files

| File | Mô tả |
|------|--------|
| `setup-server.sh` | Script cài đặt 1-click trên VPS |
| `npv-config-v2ray.json` | Config V2Ray cho NPV Tunnel |
| `npv-config-ssh.txt` | Config SSH cho NPV Tunnel |

## Yêu cầu

- VPS Ubuntu 20.04+ với IP public
- SIM Viettel 4G/5G
- App NPV Tunnel (Android/iOS)

## Lưu ý

- ⚠️ Chỉ dùng cho mục đích học tập
- SNI **phải** là `livestream2.tv360.vn`
- Bật `AllowInsecure` vì dùng self-signed cert
- Nếu không kết nối được, thử đổi port 443 → 80
