#!/usr/bin/env bash
#===========================================================
# wwwOK 一键管理脚本 v2.0
# 支持: Debian/Ubuntu/CentOS/Alibaba Cloud
# 用法: bash install.sh        # 交互式菜单
#       bash install.sh 1      # 直接安装
#       bash install.sh 2      # 查看信息
#       bash install.sh 3      # 卸载
#       bash install.sh 4      # 服务管理
#       bash install.sh 5      # 修改管理密码
#===========================================================
set -e

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'
CYAN='\033[36m'; WHITE='\033[37m'; NC='\033[0m'; BOLD='\033[1m'

INSTALL_BASE="/opt/wwwOK"
DB_DIR="$INSTALL_BASE/db"
SCRIPTS_DIR="$INSTALL_BASE/scripts"
CONFIG_DIR="$INSTALL_BASE/config"
WEB_DIR="$INSTALL_BASE/web"
BIN_DIR="$INSTALL_BASE/bin"
LOG_DIR="/var/log/wwwOK"
CONFIG_DIR_ACTUAL="/opt/wwwOK/config"
SS_PORT=9000; VMESS_PORT=9001; TROJAN_PORT=9002; VLESS_PORT=9003
SB_VERSION="1.13.11"

# 从配置文件读取 API 端口（安装时写死，之后从配置文件读）
read_api_port() {
    local port_file="$CONFIG_DIR_ACTUAL/port.txt"
    if [ -f "$port_file" ]; then
        cat "$port_file"
    else
        echo "8888"
    fi
}

find_available_port() {
    local start=$1; local max_attempts=${2:-10}
    local port=$start
    for i in $(seq 0 $((max_attempts - 1))); do
        local p=$((start + i))
        if ! ss -tuln 2>/dev/null | grep -q ":${p} " && \
           ! netstat -tuln 2>/dev/null | grep -q ":${p} "; then
            echo "$p"; return 0
        fi
        echo -e "  ${YELLOW}端口 ${p} 已被占用，尝试下一个...${NC}" >&2
    done
    echo ""; return 1
}

detect_os() {
    if [ -f /etc/os-release ]; then . /etc/os-release; fi
    CPU_ARCH=$(uname -m)
    case "$CPU_ARCH" in
        x86_64) SB_ARCH="amd64" ;;
        aarch64|arm64) SB_ARCH="arm64" ;;
        armv7l) SB_ARCH="armv7" ;;
        *) echo -e "${RED}不支持的CPU架构: $CPU_ARCH${NC}"; exit 1 ;;
    esac
    echo -e "${CYAN}检测到系统: ${WHITE}$NAME ${VERSION_ID} | ${CYAN}架构: ${WHITE}${SB_ARCH}${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 运行此脚本${NC}"; exit 1; fi
}

is_installed() {
    [ -f "$SCRIPTS_DIR/wwwOK_api.py" ] && [ -f "$BIN_DIR/sing-box" ]
}

print_divider() { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

print_banner() {
    print_divider
    echo -e "  ${BOLD}${CYAN}wwwOK${NC} ${WHITE}Proxy Panel v2.0${NC}"
    echo -e "  ${WHITE}sing-box ${SB_VERSION} + Python API${NC}"
    print_divider
}

print_status() {
    local status=$1; local msg=$2
    case "$status" in
        OK)   echo -e "  ${GREEN}[✓]${NC} $msg" ;;
        FAIL) echo -e "  ${RED}[✗]${NC} $msg" ;;
        WARN) echo -e "  ${YELLOW}[!]${NC} $msg" ;;
        INFO) echo -e "  ${CYAN}[i]${NC} $msg" ;;
        *)    echo -e "  $msg" ;;
    esac
}

pause() { echo ""; read -p "  按回车键继续... "; }

install_dependencies() {
    echo -e "\n${CYAN}>>> 安装系统依赖...${NC}"
    if command -v python3 &>/dev/null; then PYTHON_CMD="python3"
    elif command -v python3.11 &>/dev/null; then PYTHON_CMD="python3.11"
    elif command -v python3.10 &>/dev/null; then PYTHON_CMD="python3.10"
    elif command -v python3.9 &>/dev/null; then PYTHON_CMD="python3.9"
    elif command -v python3.8 &>/dev/null; then PYTHON_CMD="python3.8"
    elif command -v python &>/dev/null; then PYTHON_CMD="python"
    else echo -e "${RED}未找到 Python 3.6+，请先安装${NC}"; exit 1; fi
    echo -e "${GREEN}  使用 Python: ${PYTHON_CMD}${NC}"

    if ! $PYTHON_CMD -c "import dateutil" 2>/dev/null; then
        echo -e "${CYAN}  安装 python3-dateutil...${NC}"
        pip3 install python-dateutil -q 2>/dev/null || pip install python-dateutil -q 2>/dev/null || \
        apt install -y python3-dateutil -qq 2>/dev/null || yum install -y python3-dateutil 2>/dev/null || true
    fi
    for pkg in sshpass curl jq; do
        if ! command -v $pkg &>/dev/null; then
            echo -e "${CYAN}  安装 $pkg...${NC}"
            apt install -y $pkg -qq 2>/dev/null || yum install -y $pkg 2>/dev/null || dnf install -y $pkg 2>/dev/null || true
        fi
    done
    echo -e "${GREEN}  依赖安装完成${NC}"
}

download_singbox() {
    echo -e "\n${CYAN}>>> 下载 sing-box v${SB_VERSION}...${NC}"
    mkdir -p "$BIN_DIR"
    cd /tmp
    SB_FILE="sing-box-${SB_VERSION}-linux-${SB_ARCH}.tar.gz"
    SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${SB_FILE}"
    echo -e "  ${WHITE}${SB_URL}${NC}"
    if curl -L --progress-bar -o "$SB_FILE" "$SB_URL"; then
        echo -e "  ${GREEN}下载完成，解压安装...${NC}"
        tar -xzf "$SB_FILE"
        if [ -f "sing-box-${SB_VERSION}-linux-${SB_ARCH}/sing-box" ]; then
            systemctl stop sing-box 2>/dev/null || true
            cp "sing-box-${SB_VERSION}-linux-${SB_ARCH}/sing-box" "$BIN_DIR/sing-box"
            chmod +x "$BIN_DIR/sing-box"
            echo -e "  ${GREEN}已安装到 ${BIN_DIR}/sing-box${NC}"
        else
            echo -e "${RED}解压失败${NC}"; exit 1
        fi
        rm -rf "sing-box-${SB_VERSION}-linux-${SB_ARCH}" "$SB_FILE"
    else
        echo -e "${RED}sing-box 下载失败，请检查网络${NC}"; exit 1
    fi
}

create_dirs() {
    mkdir -p "$DB_DIR" "$SCRIPTS_DIR" "$CONFIG_DIR" "$WEB_DIR" "$LOG_DIR"
    chmod -R 755 "$INSTALL_BASE" 2>/dev/null || true
    chmod -R 777 "$LOG_DIR" 2>/dev/null || true
}

install_python_scripts() {
    echo -e "\n${CYAN}>>> 安装 Python 管理脚本...${NC}"

    # 从 GitHub 下载脚本，避免 heredoc 转义问题
    curl -fsSL "https://raw.githubusercontent.com/HYweb3/wwwOK/main/scripts/gen_singbox_config.py" \
        -o "${SCRIPTS_DIR}/gen_singbox_config.py"
    echo -e "  ${GREEN}gen_singbox_config.py 下载完成${NC}"

    curl -fsSL "https://raw.githubusercontent.com/HYweb3/wwwOK/main/scripts/wwwOK_api.py" \
        -o "${SCRIPTS_DIR}/wwwOK_api.py"
    echo -e "  ${GREEN}wwwOK_api.py 下载完成${NC}"

    chmod +x "${SCRIPTS_DIR}/gen_singbox_config.py"
    chmod +x "${SCRIPTS_DIR}/wwwOK_api.py"
    echo -e "  ${GREEN}Python 脚本已安装${NC}"
}

install_web() {
    echo -e "\n${CYAN}>>> 安装 Web 前端...${NC}"

    curl -fsSL "https://raw.githubusercontent.com/HYweb3/wwwOK/main/web/admin.html" \
        -o "$WEB_DIR/admin.html"
    curl -fsSL "https://raw.githubusercontent.com/HYweb3/wwwOK/main/web/user.html" \
        -o "$WEB_DIR/user.html"
    curl -fsSL "https://raw.githubusercontent.com/HYweb3/wwwOK/main/web/qrcode.min.js" \
        -o "$WEB_DIR/qrcode.min.js"
    curl -fsSL "https://raw.githubusercontent.com/HYweb3/wwwOK/main/web/index.html" \
        -o "$WEB_DIR/index.html"

    echo -e "  ${GREEN}Web 前端已安装 (admin.html / user.html / index.html / qrcode.min.js)${NC}"
}

install_singbox_service() {
    echo -e "\n${CYAN}>>> 配置 sing-box 服务...${NC}"

    if systemctl list-unit-files sing-box.service 2>/dev/null | grep -q sing-box; then
        echo -e "${YELLOW}  检测到已有 sing-box.service，停止并替换...${NC}"
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
    fi

    cat > /etc/systemd/system/sing-box.service << 'SVCEOF'
[Unit]
Description=sing-box proxy service
After=network.target

[Service]
Type=simple
ExecStart=/opt/wwwOK/bin/sing-box run -c /opt/wwwOK/config/sing-box.json
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    $PYTHON_CMD ${SCRIPTS_DIR}/gen_singbox_config.py

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
    sleep 2

    if systemctl is-active --quiet sing-box; then
        echo -e "  ${GREEN}sing-box 服务启动成功${NC}"
    else
        echo -e "  ${RED}sing-box 启动失败，请检查 journalctl -u sing-box${NC}"
    fi
}

install_api_service() {
    local API_PORT=$1
    echo -e "\n${CYAN}>>> 配置 wwwOK API 服务 (端口 ${API_PORT})...${NC}"

    # 保存端口配置
    mkdir -p "$CONFIG_DIR_ACTUAL"
    echo "$API_PORT" > "$CONFIG_DIR_ACTUAL/port.txt"

    cat > /etc/systemd/system/wwwok-api.service << SVCEOF
[Unit]
Description=wwwOK API service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/wwwOK/scripts/wwwOK_api.py $API_PORT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
WorkingDirectory=/opt/wwwOK/scripts

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable wwwok-api
    systemctl restart wwwok-api
    sleep 1

    if systemctl is-active --quiet wwwok-api; then
        echo -e "  ${GREEN}wwwOK API 服务启动成功 (端口 ${API_PORT})${NC}"
    else
        echo -e "  ${RED}wwwOK API 启动失败，请检查 journalctl -u wwwok-api${NC}"
    fi
}

setup_firewall() {
    local API_PORT=${1:-8888}
    echo -e "\n${CYAN}>>> 配置防火墙...${NC}"
    for port in $API_PORT $SS_PORT $VMESS_PORT $TROJAN_PORT $VLESS_PORT; do
        if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
            firewall-cmd --permanent --add-port=${port}/tcp 2>/dev/null || true
        fi
        if command -v ufw &>/dev/null && systemctl is-active ufw &>/dev/null; then
            ufw allow ${port}/tcp 2>/dev/null || true
        fi
        if command -v iptables &>/dev/null; then
            iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
        fi
    done
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --reload 2>/dev/null || true
    fi
    echo -e "  ${GREEN}防火墙配置完成${NC}"
}

do_install() {
    print_banner
    echo -e "  ${CYAN}开始全新安装...${NC}\n"
    detect_os
    install_dependencies
    create_dirs
    download_singbox
    install_python_scripts
    install_web

    # 下载 install.sh 到 /opt/wwwOK/ 并创建 wwwok 命令
    curl -fsSL "https://raw.githubusercontent.com/HYweb3/wwwOK/main/install.sh" \
        -o /opt/wwwOK/install.sh
    chmod +x /opt/wwwOK/install.sh
    ln -sf /opt/wwwOK/install.sh /usr/local/bin/wwwok
    echo -e "  ${GREEN}wwwok 命令已创建: /usr/local/bin/wwwok${NC}"

    install_singbox_service

    # 查找可用端口 8888~8897
    echo -e "\n${CYAN}>>> 查找可用 API 端口...${NC}"
    API_PORT=$(find_available_port 8888 10)
    if [ -z "$API_PORT" ]; then
        echo -e "  ${RED}无法找到可用端口 (8888-8897)${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}使用端口: ${API_PORT}${NC}"

    install_api_service $API_PORT
    setup_firewall $API_PORT

    # 等待 API 服务就绪
    echo -e "\n${CYAN}>>> 等待 API 服务就绪...${NC}"
    for i in $(seq 1 10); do
        if curl -s --max-time 2 "http://127.0.0.1:${API_PORT}/health" 2>/dev/null | grep -q 'status.*ok'; then
            echo -e "  ${GREEN}API 服务已就绪${NC}"
            break
        fi
        sleep 1
    done

    # 创建默认节点和默认用户
    echo -e "\n${CYAN}>>> 创建默认节点和用户...${NC}"
    INIT_RESP=$(curl -s --max-time 15 -X POST "http://127.0.0.1:${API_PORT}/api/init-defaults" \
        -H "Authorization: Basic YWRtaW46dmlwQDg4ODg5OTk=" \
        -H "Content-Type: application/json" 2>/dev/null)

    if echo "$INIT_RESP" | grep -q '"success" *: *true'; then
        # 提取返回数据
        USER_NAME=$(echo "$INIT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('user',{}); print(u.get('username','wwwok') if u else 'wwwok')" 2>/dev/null)
        USER_PASS=$(echo "$INIT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('user',{}); print(u.get('password','@user8888999') if u else '@user8888999')" 2>/dev/null)
        AUTH_ID=$(echo "$INIT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('user',{}); print(u.get('auth_id','') if u else '')" 2>/dev/null)
        SERVER_IP=$(echo "$INIT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('server_ip',''))" 2>/dev/null)
        API_PORT=$(cat /opt/wwwOK/config/port.txt 2>/dev/null || echo "8888")
        [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)
        [ -z "$SERVER_IP" ] && SERVER_IP="<服务器IP>"
        echo -e "  ${GREEN}默认节点 wwwok 已创建${NC}"
        echo -e "  ${GREEN}默认用户 wwwok 已创建${NC}"
        if [ -n "$AUTH_ID" ] && [ -n "$SERVER_IP" ]; then
            echo -e "  ${CYAN}订阅地址: ${NC}http://${SERVER_IP}:${API_PORT}/subscribe/${AUTH_ID}"
        fi
    else
        SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
        [ -z "$SERVER_IP" ] && SERVER_IP="<服务器IP>"
        echo -e "  ${YELLOW}默认用户创建失败，请手动检查: $INIT_RESP${NC}"
    fi

    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    [ -z "$SERVER_IP" ] && SERVER_IP="<服务器IP>"

    print_divider
    echo -e "  ${GREEN}${BOLD}安装完成！${NC}"
    print_divider
    echo -e "  ${WHITE}管理面板: ${CYAN}http://${SERVER_IP}:${API_PORT}/admin.html${NC}"
    echo -e "  ${WHITE}用户订阅: ${CYAN}http://${SERVER_IP}:${API_PORT}/user.html${NC}"
    echo -e "  ${WHITE}代理端口:  ${CYAN}SS=${SS_PORT} | VMess=${VMESS_PORT} | Trojan=${TROJAN_PORT} | VLESS=${VLESS_PORT}${NC}"
    echo ""
    echo -e "  ${WHITE}默认用户:  ${CYAN}wwwok / @user8888999${NC}"
    echo -e "  ${WHITE}管理员:    ${CYAN}admin / vip@8888999${NC}"
    echo ""
    echo -e "  ${YELLOW}请尽快修改管理密码！${NC}"
    echo ""
    systemctl status sing-box --no-pager 2>&1 | grep -E "Active:|MainPID" | head -2
    echo ""
    systemctl status wwwok-api --no-pager 2>&1 | grep -E "Active:|MainPID" | head -2
}

do_view() {
    print_banner
    if ! is_installed; then
        echo -e "  ${RED}wwwOK 未安装，请先执行安装${NC}"
        return
    fi

    API_PORT=$(read_api_port)
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    [ -z "$SERVER_IP" ] && SERVER_IP="<服务器IP>"

    USER_COUNT=$($PYTHON_CMD -c 'import sqlite3; c=sqlite3.connect("/opt/wwwOK/db/users.db").cursor(); c.execute("SELECT COUNT(*) FROM users"); print(c.fetchone()[0])' 2>/dev/null || echo '?')
    NODE_INFO=$($PYTHON_CMD -c 'import sqlite3; c=sqlite3.connect("/opt/wwwOK/db/users.db").cursor(); c.execute("SELECT name,host,port FROM nodes LIMIT 1"); r=c.fetchone(); print(r[0]+" ("+r[1]+":"+str(r[2])+")" if r else "未配置")' 2>/dev/null || echo '未配置')
    SB_STATUS=$(systemctl is-active sing-box 2>/dev/null)
    API_STATUS=$(systemctl is-active wwwok-api 2>/dev/null)

    echo -e "  ${GREEN}✅ wwwOK 已安装${NC}\n"
    echo -e "  ${BOLD}【访问信息】${NC}"
    echo -e "  管理面板:  ${CYAN}http://${SERVER_IP}:${API_PORT}/admin.html${NC}"
    echo -e "  用户订阅:  ${CYAN}http://${SERVER_IP}:${API_PORT}/user.html${NC}"
    echo ""
    echo -e "  ${BOLD}【服务端口】${NC}"
    echo -e "  API端口:   ${CYAN}${API_PORT}${NC}"
    echo -e "  SS:        ${CYAN}${SS_PORT}${NC} | VMess: ${CYAN}${VMESS_PORT}${NC} | Trojan: ${CYAN}${TROJAN_PORT}${NC} | VLESS: ${CYAN}${VLESS_PORT}${NC}"
    echo ""
    echo -e "  ${BOLD}【账户信息】${NC}"
    echo -e "  管理员:    ${CYAN}admin${NC}"
    echo -e "  管理密码:  ${CYAN}vip@8888999${NC}"
    echo -e "  用户总数:  ${CYAN}${USER_COUNT}${NC}"
    echo -e "  节点:      ${CYAN}${NODE_INFO}${NC}"
    echo ""
    echo -e "  ${BOLD}【服务状态】${NC}"
    [ "$SB_STATUS" = "active" ] && print_status OK "sing-box 代理运行中" || print_status FAIL "sing-box 未运行 ($SB_STATUS)"
    [ "$API_STATUS" = "active" ] && print_status OK "wwwOK API 运行中" || print_status FAIL "wwwOK API 未运行 ($API_STATUS)"
    echo ""
    echo -e "  ${BOLD}【配置文件】${NC}"
    echo -e "  安装目录:  ${CYAN}${INSTALL_BASE}${NC}"
    echo -e "  SS PSK:    ${CYAN}$(cat ${DB_DIR}/ss_psk.txt 2>/dev/null || echo '未找到')${NC}"
}

do_uninstall() {
    print_banner
    echo -e "  ${RED}${BOLD}⚠️  警告：即将完全卸载 wwwOK${NC}\n"
    echo -e "  这将删除："
    echo -e "    - ${INSTALL_BASE} 整个目录"
    echo -e "    - /etc/systemd/system/sing-box.service"
    echo -e "    - /etc/systemd/system/wwwok-api.service"
    echo -e "    - 所有配置和数据\n"
    read -p "  确认卸载? 请输入 'YES' 以继续: " confirm
    [ "$confirm" != "YES" ] && echo -e "  ${YELLOW}已取消卸载${NC}" && return

    echo -e "\n${RED}>>> 开始卸载...${NC}"
    systemctl stop sing-box 2>/dev/null || true
    systemctl stop wwwok-api 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    systemctl disable wwwok-api 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    rm -f /etc/systemd/system/wwwok-api.service
    systemctl daemon-reload
    rm -rf "$INSTALL_BASE"
    echo -e "  ${GREEN}卸载完成${NC}"
}

do_service_menu() {
    while true; do
        print_divider
        echo -e "  ${BOLD}${CYAN}服务管理${NC}"
        print_divider
        echo -e "  ${WHITE}1. 查看服务状态${NC}"
        echo -e "  ${WHITE}2. 重启 sing-box${NC}"
        echo -e "  ${WHITE}3. 重启 wwwOK API${NC}"
        echo -e "  ${WHITE}4. 重启全部服务${NC}"
        echo -e "  ${WHITE}5. 停止 sing-box${NC}"
        echo -e "  ${WHITE}6. 停止 wwwOK API${NC}"
        echo -e "  ${WHITE}7. 重新生成配置${NC}"
        echo -e "  ${WHITE}8. 查看日志 (sing-box)${NC}"
        echo -e "  ${WHITE}9. 查看日志 (API)${NC}"
        echo -e "  ${WHITE}0. 返回主菜单${NC}"
        print_divider
        read -p "  请输入选项 [0-9]: " choice

        case $choice in
            1)
                echo ""
                echo -e "  ${CYAN}--- sing-box ---${NC}"
                systemctl status sing-box --no-pager 2>&1 | grep -E "Active:|MainPID" | head -5
                echo ""
                echo -e "  ${CYAN}--- wwwOK API ---${NC}"
                systemctl status wwwok-api --no-pager 2>&1 | grep -E "Active:|MainPID" | head -5
                echo ""
                echo -e "  ${CYAN}--- 端口监听 ---${NC}"
                ss -tlnp 2>/dev/null | grep -E '900[0-3]|8888' || netstat -tlnp 2>/dev/null | grep -E '900[0-3]|8888'
                ;;
            2)
                echo -e "\n${CYAN}重启 sing-box...${NC}"
                $PYTHON_CMD ${SCRIPTS_DIR}/gen_singbox_config.py
                systemctl restart sing-box && sleep 1
                systemctl is-active --quiet sing-box && print_status OK "sing-box 重启成功" || print_status FAIL "sing-box 重启失败"
                ;;
            3)
                echo -e "\n${CYAN}重启 wwwOK API...${NC}"
                systemctl restart wwwok-api && sleep 1
                systemctl is-active --quiet wwwok-api && print_status OK "wwwOK API 重启成功" || print_status FAIL "wwwOK API 重启失败"
                ;;
            4)
                echo -e "\n${CYAN}重启全部服务...${NC}"
                $PYTHON_CMD ${SCRIPTS_DIR}/gen_singbox_config.py
                systemctl restart sing-box wwwok-api
                sleep 2
                SB_PID=$(systemctl show sing-box -p MainPID --value 2>/dev/null)
                API_PID=$(systemctl show wwwok-api -p MainPID --value 2>/dev/null)
                echo -e "  sing-box PID: $SB_PID"
                echo -e "  wwwOK API PID: $API_PID"
                ;;
            5)
                echo -e "\n${YELLOW}停止 sing-box...${NC}"
                systemctl stop sing-box
                print_status INFO "sing-box 已停止"
                ;;
            6)
                echo -e "\n${YELLOW}停止 wwwOK API...${NC}"
                systemctl stop wwwok-api
                print_status INFO "wwwOK API 已停止"
                ;;
            7)
                echo -e "\n${CYAN}重新生成 sing-box 配置...${NC}"
                $PYTHON_CMD ${SCRIPTS_DIR}/gen_singbox_config.py
                sleep 1
                systemctl restart sing-box && sleep 1
                systemctl is-active --quiet sing-box && print_status OK "配置已更新" || print_status FAIL "更新失败"
                ;;
            8)
                echo -e "\n${CYAN}--- sing-box 日志 (最近 30 行) ---${NC}"
                journalctl -u sing-box --no-pager -n 30 2>/dev/null
                ;;
            9)
                echo -e "\n${CYAN}--- wwwOK API 日志 (最近 30 行) ---${NC}"
                journalctl -u wwwok-api --no-pager -n 30 2>/dev/null
                ;;
            0) break ;;
            *) print_status WARN "无效选项，请输入 0-9" ;;
        esac
        if [ "$choice" != "0" ]; then echo ""; read -p "  按回车键继续..."; fi
    done
}

do_change_password() {
    print_divider
    echo -e "  ${BOLD}${CYAN}修改管理密码${NC}"
    print_divider
    if ! is_installed; then print_status FAIL "wwwOK 未安装"; return; fi
    read -p "  请输入新密码 (至少6位): " newpass
    if [ -z "$newpass" ] || [ ${#newpass} -lt 6 ]; then
        print_status FAIL "密码长度至少6位"; return
    fi

    API_PORT=$(read_api_port)

    # 用 API 修改密码，避免 bash 引号和 set -e 冲突
    RESPONSE=$(curl -s        -X POST "http://127.0.0.1:${API_PORT}/api/admin/password" \
        -H "Authorization: Basic YWRtaW46dmlwQDg4ODg5OTk=" \
        -H "Content-Type: application/json" \
        -d "{\"new_password\":\"$newpass\"}" 2>/dev/null)

    if echo "$RESPONSE" | grep -q 'success.*true\|"code".*0'; then
        print_status OK "管理密码已修改为: $newpass"
    else
        print_status FAIL "修改失败: $RESPONSE"
    fi
}

show_menu() {
    print_banner
    if is_installed; then
        echo -e "  ${GREEN}✅ wwwOK 已安装${NC}"
    else
        echo -e "  ${YELLOW}⚠️  wwwOK 未安装${NC}"
    fi
    echo ""
    echo -e "  ${WHITE}1.${NC} ${GREEN}安装 wwwOK${NC}    $(is_installed && echo "${GREEN}[已安装]" || echo "${YELLOW}[全新安装]${NC}")"
    echo -e "  ${WHITE}2.${NC} 查看信息       显示面板地址、端口、管理密码"
    echo -e "  ${WHITE}3.${NC} ${RED}卸载 wwwOK${NC}    删除所有数据和服务"
    echo -e "  ${WHITE}4.${NC} 服务管理        控制 sing-box 和 API 服务"
    echo -e "  ${WHITE}5.${NC} 修改密码        更改管理员登录密码"
    echo -e "  ${WHITE}0.${NC} 退出脚本"
    echo ""
}

main() {
    check_root

    case "$1" in
        1) do_install; exit 0 ;;
        2) do_view; exit 0 ;;
        3) do_uninstall; exit 0 ;;
        4) do_service_menu; exit 0 ;;
        5) do_change_password; exit 0 ;;
    esac

    while true; do
        clear || true
        show_menu
        read -p "  请输入选项 [0-5]: " choice
        clear || true
        case $choice in
            1) do_install; pause ;;
            2) do_view; pause ;;
            3) do_uninstall; pause ;;
            4) do_service_menu ;;
            5) do_change_password; pause ;;
            0) echo -e "\n${CYAN}再见！${NC}\n"; exit 0 ;;
            *) echo -e "\n${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

main "$@"
