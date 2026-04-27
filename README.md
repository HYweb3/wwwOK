# wwwOK - sing-box 代理管理系统

基于 sing-box 的多用户代理管理面板，支持 Shadowsocks、VMess、Trojan、VLESS 协议。

## 特性

- 🌐 支持 Ubuntu、CentOS、Debian 等主流 Linux 系统
- 👥 多用户管理，独立订阅链接
- 📊 流量控制和到期时间限制
- 📱 响应式 Web 管理面板
- 🔗 一键复制节点链接
- 📋 二维码生成
- ⚡ sing-box 高性能内核

## 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/HYweb3/wwwOK/main/install.sh | bash
```

或者：

```bash
wget -qO- https://raw.githubusercontent.com/HYweb3/wwwOK/main/install.sh | bash
```

安装完成后访问：`http://你的服务器IP:8080`

## 管理命令

```bash
wwwOK
```

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
├── install.sh          # 一键安装脚本
├── manage.sh           # 管理菜单
├── config/
│   └── sing-box.json   # sing-box 配置
├── web/
│   ├── index.html       # 管理面板
│   └── api.php         # API 接口
├── db/
│   └── users.db        # 用户数据库
└── scripts/
    ├── singbox.sh      # sing-box 安装
    └── user.sh         # 用户管理
```

## 协议说明

| 协议 | 特点 | 兼容性 |
|------|------|--------|
| Shadowsocks | 经典协议，速度快 | 广泛 |
| VMess | V2Ray 核心，更安全 | 良好 |
| Trojan | 伪装 HTTPS，防封锁 | 良好 |
| VLESS | 轻量级，更高效 | 一般 |

## License

MIT
