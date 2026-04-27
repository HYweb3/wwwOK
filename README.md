# wwwOK - sing-box 代理管理系统

基于 sing-box 1.13.11 的多用户代理管理面板，支持 Shadowsocks、VMess、Trojan、VLESS 四种协议。

## 特性

- 🌐 支持 Ubuntu、Debian、CentOS、阿里云等主流 Linux 系统
- 👥 多用户管理，独立订阅链接（Base64 自动编码）
- 📊 流量控制和到期时间限制
- ⚡ sing-box 高性能内核（1.13.11）
- 🔗 一键复制节点链接
- 📋 二维码生成
- 🔐 四种协议：SS (2022-blake3-aes-256-gcm)、VMess、 Trojan、VLESS

## 快速安装（一键）

```bash
curl -sL https://raw.githubusercontent.com/HYweb3/wwwOK/main/install.sh | bash
```

## 一键更新（如已安装）

```bash
curl -sL https://raw.githubusercontent.com/HYweb3/wwwOK/main/install.sh | bash -s -- 1
```

安装完成后访问：`http://你的服务器IP:8888`

## 管理命令

```bash
wwwok
```

显示菜单：1=安装 2=查看 3=卸载 4=服务管理 5=改密码 0=退出

## 手动安装依赖

```bash
# Ubuntu/Debian
apt update && apt install -y curl wget unzip qrencode

# CentOS
yum update && yum install -y curl wget unzip qrcode-devel
```

## 项目结构

```
wwwOK/
├── install.sh              # 一键安装/管理脚本（v2.0）
├── README.md
└── scripts/
    ├── wwwOK_api.py        # API 服务（Python 3.6+）
    └── gen_singbox_config.py  # sing-box 配置生成
```

## 协议说明

| 协议 | 加密/认证 | 备注 |
|------|-----------|------|
| Shadowsocks | 2022-blake3-aes-256-gcm | 现代 SS 协议 |
| VMess | auto / none | UUID 认证 |
| Trojan | 密码认证 | 伪装 HTTPS |
| VLESS | UUID 认证 | 轻量无加密 |

## API 管理

- 面板地址：`http://服务器IP:8888`
- 订阅格式：`http://服务器IP:8888/subscribe/{auth_id}`
- 改密码：`POST /api/admin/password`（Basic Auth，JSON: `{"new_password":"..."}`）

## License

MIT
