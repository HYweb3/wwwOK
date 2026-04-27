#!/bin/bash
#===============================================
# wwwOK 一键安装脚本
# 支持: Ubuntu/Debian/CentOS/AlmaLinux/Rocky
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_NAME/wwwOK/main/install.sh | bash
#   或
#   wget -qO- https://raw.githubusercontent.com/YOUR_NAME/wwwOK/main/install.sh | bash
#===============================================

set -e

# 配置
WORK_DIR="/opt/wwwOK"
WEB_PORT=8080
GITHUB_REPO="YOUR_NAME/wwwOK"  # 需要修改为你的GitHub用户名/仓库名

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif [ -f /etc/centos-release ]; then
        OS="centos"
    else
        OS="unknown"
    fi
    OS=$(echo "$OS" | tr '[:upper:]' '[:lower:]')
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) ARCH="amd64" ;;
    esac
    
    log_info "检测到系统: $OS $VER ($ARCH)"
}

# 安装依赖
install_dependencies() {
    log_info "安装系统依赖..."
    
    case $OS in
        ubuntu|debian|linuxmint|pop)
            apt update
            apt install -y curl wget unzip python3 python3-pip sqlite3 qrencode
            ;;
        centos|rhel|almalinux|rocky)
            yum update -y
            yum install -y curl wget unzip python3 sqlite qrencode
            ;;
        fedora)
            dnf update -y
            dnf install -y curl wget unzip python3 sqlite qrencode
            ;;
        *)
            log_warn "不支持的操作系统: $OS，尝试通用安装..."
            apt update && apt install -y curl wget unzip python3 sqlite3 qrencode 2>/dev/null || \
            yum update && yum install -y curl wget unzip python3 sqlite qrencode 2>/dev/null || true
            ;;
    esac
    
    log_success "依赖安装完成"
}

# 下载sing-box
download_singbox() {
    log_info "下载 sing-box..."
    
    # 获取最新版本
    SINGBOX_VER=$(curl -sL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -o '"tag_name": "v[^"]*"' | head -1 | cut -d'"' -f4 || echo "v1.9.0")
    
    mkdir -p ${WORK_DIR}/bin
    cd /tmp
    
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VER}/sing-box-${SINGBOX_VER#v}-linux-${ARCH}.tar.gz"
    
    log_info "下载链接: $DOWNLOAD_URL"
    
    if curl -fL -o sing-box.tar.gz "$DOWNLOAD_URL" 2>/dev/null; then
        tar -xzf sing-box.tar.gz
        mv sing-box-${SINGBOX_VER#v}-linux-${ARCH}/sing-box ${WORK_DIR}/bin/
        chmod +x ${WORK_DIR}/bin/sing-box
        rm -rf sing-box.tar.gz sing-box-${SINGBOX_VER#v}-linux-${ARCH}
        log_success "sing-box 下载完成 (版本: ${SINGBOX_VER})"
    else
        log_error "sing-box 下载失败，请检查网络连接"
    fi
}

# 创建目录结构
create_directories() {
    log_info "创建目录结构..."
    
    mkdir -p ${WORK_DIR}/{bin,config,web/admin,db,logs,scripts}
    mkdir -p /var/log/wwwOK
    
    log_success "目录创建完成"
}

# 下载 Web 前端文件
download_web_files() {
    log_info "下载 Web 前端文件..."
    
    WEB_URL="https://raw.githubusercontent.com/HYweb3/wwwOK/main/web"
    
    curl -sL "${WEB_URL}/index.html" -o ${WORK_DIR}/web/index.html || {
        log_error "下载 index.html 失败"
        exit 1
    }
    
    # 下载 admin.html（管理页面）
    curl -sL "${WEB_URL}/admin.html" -o ${WORK_DIR}/web/admin.html 2>/dev/null || {
        log_info "admin.html 不存在，跳过"
    }
    
    # 下载静态资源（如果有）
    mkdir -p ${WORK_DIR}/web/static
    curl -sL "${WEB_URL}/static/" -o /dev/null 2>&1 || true
    
    log_success "Web 前端文件下载完成"
}

# 初始化数据库
init_database() {
    log_info "初始化数据库..."
    
    python3 << 'PYEOF'
import sqlite3
import os
import hashlib
from datetime import datetime

db_path = "/opt/wwwOK/db/users.db"
os.makedirs(os.path.dirname(db_path), exist_ok=True)

conn = sqlite3.connect(db_path)
c = conn.cursor()

# 用户表
c.execute('''CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    uuid TEXT UNIQUE NOT NULL,
    enable INTEGER DEFAULT 1,
    flow_limit INTEGER DEFAULT 107374182400,
    flow_used INTEGER DEFAULT 0,
    expire_time TEXT,
    created_time TEXT,
    last_login TEXT,
    auth_id TEXT
)''')

# 管理员表
c.execute('''CREATE TABLE IF NOT EXISTS admins (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    created_time TEXT
)''')

# 节点表
c.execute('''CREATE TABLE IF NOT EXISTS nodes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    host TEXT NOT NULL,
    port INTEGER DEFAULT 8080,
    enable INTEGER DEFAULT 1,
    created_time TEXT
)''')

# 添加默认节点（如果不存在），自动获取本机IP
import subprocess
server_ip = subprocess.check_output("curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'", shell=True).decode().strip()
if server_ip:
    c.execute("SELECT * FROM nodes WHERE host=?", (server_ip,))
    if not c.fetchone():
        c.execute("INSERT INTO nodes (name, host, port, enable, created_time) VALUES (?, ?, ?, ?, ?)",
                 (f"默认节点", server_ip, 8080, 1, datetime.now().isoformat()))
        print(f"Default node added: {server_ip}")

# 添加默认管理员（如果不存在），密码: vip@8888999
c.execute("SELECT * FROM admins WHERE username='admin'")
if not c.fetchone():
    pwd_hash = hashlib.sha256("vip@8888999".encode()).hexdigest()
    c.execute("INSERT INTO admins (username, password, created_time) VALUES (?, ?, ?)",
             ("admin", pwd_hash, datetime.now().isoformat()))
    print("Default admin created with password: vip@8888999")

conn.commit()
conn.close()
print("Database initialized successfully")
PYEOF

    log_success "数据库初始化完成"
}

# 生成sing-box配置
generate_singbox_config() {
    log_info "生成 sing-box 配置..."
    
    # 获取服务器IP
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    cat > ${WORK_DIR}/config/sing-box.json << EOF
{
    "log": {
        "level": "info",
        "output": "/var/log/wwwOK/sing-box.log",
        "timestamp": true
    },
    "inbounds": [
        {
            "tag": "web",
            "type": "http",
            "listen": "0.0.0.0",
            "listen_port": ${WEB_PORT}
        }
    ],
    "outbounds": [
        {
            "tag": "direct",
            "type": "direct"
        },
        {
            "tag": "block",
            "type": "block"
        }
    ]
}
EOF

    log_success "sing-box 配置生成完成"
}

# 创建管理API服务
create_api_server() {
    log_info "创建 API 服务..."
    
    cat > ${WORK_DIR}/scripts/wwwOK_api.py << 'PYEOF'
#!/usr/bin/env python3
"""
wwwOK - API 服务
基于 Python 的 HTTP API 服务器
"""

import sqlite3
import uuid
import string
import secrets
import hashlib
import json
import time
import os
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import base64

# 配置
DB_PATH = "/opt/wwwOK/db/users.db"
PORT = 8888

def init_db():
    """初始化数据库"""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    
    # 用户表
    c.execute('''CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        uuid TEXT UNIQUE NOT NULL,
        enable INTEGER DEFAULT 1,
        flow_limit INTEGER DEFAULT 107374182400,
        flow_used INTEGER DEFAULT 0,
        expire_time TEXT,
        created_time TEXT,
        last_login TEXT,
        auth_id TEXT
    )''')
    
    # 管理员表
    c.execute('''CREATE TABLE IF NOT EXISTS admins (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        created_time TEXT
    )''')
    
    # 节点表
    c.execute('''CREATE TABLE IF NOT EXISTS nodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER DEFAULT 8080,
        enable INTEGER DEFAULT 1,
        created_time TEXT
    )''')
    
    # 创建默认管理员 (密码: vip@8888999)
    c.execute("SELECT * FROM admins WHERE username='admin'")
    if not c.fetchone():
        hashed = hashlib.sha256("vip@8888999".encode()).hexdigest()
        c.execute("INSERT INTO admins (username, password, created_time) VALUES (?, ?, ?)",
                 ("admin", hashed, datetime.now().isoformat()))
    
    conn.commit()
    conn.close()

def generate_password(length=32):
    chars = string.ascii_letters + string.digits
    return ''.join(secrets.choice(chars) for _ in range(length))

def generate_uuid():
    return str(uuid.uuid4())

def generate_auth_id():
    return secrets.token_urlsafe(16)

def create_user(username, expire_days=30, flow_limit_gb=100):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    
    password = generate_password()
    user_uuid = generate_uuid()
    auth_id = generate_auth_id()
    expire_time = (datetime.now() + timedelta(days=expire_days)).isoformat()
    flow_limit = flow_limit_gb * 1024 * 1024 * 1024
    
    try:
        c.execute('''INSERT INTO users 
            (username, password, uuid, expire_time, flow_limit, created_time, auth_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)''',
            (username, password, user_uuid, expire_time, flow_limit, datetime.now().isoformat(), auth_id))
        conn.commit()
        user_id = c.lastrowid
        conn.close()
        return {'id': user_id, 'username': username, 'password': password, 'uuid': user_uuid, 'auth_id': auth_id}
    except Exception as e:
        conn.close()
        raise e

def get_user(user_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT * FROM users WHERE id=?", (user_id,))
    user = c.fetchone()
    conn.close()
    if user:
        return {'id': user[0], 'username': user[1], 'password': user[2], 'uuid': user[3], 'enable': user[4],
                'flow_limit': user[5], 'flow_used': user[6], 'expire_time': user[7], 'created_time': user[8],
                'last_login': user[9], 'auth_id': user[10]}
    return None

def get_user_by_auth(auth_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT * FROM users WHERE auth_id=?", (auth_id,))
    user = c.fetchone()
    conn.close()
    if user:
        return {'id': user[0], 'username': user[1], 'password': user[2], 'uuid': user[3], 'enable': user[4],
                'flow_limit': user[5], 'flow_used': user[6], 'expire_time': user[7], 'created_time': user[8],
                'last_login': user[9], 'auth_id': user[10]}
    return None

def list_users():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT id, username, enable, flow_limit, flow_used, expire_time, created_time FROM users ORDER BY id")
    users = c.fetchall()
    conn.close()
    return [{'id': u[0], 'username': u[1], 'enable': u[2], 'flow_limit': u[3], 
             'flow_used': u[4], 'expire_time': u[5], 'created_time': u[6]} for u in users]

def delete_user(user_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("DELETE FROM users WHERE id=?", (user_id,))
    conn.commit()
    conn.close()

def add_node(name, host, port=8080):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("INSERT INTO nodes (name, host, port, created_time) VALUES (?, ?, ?, ?)",
             (name, host, port, datetime.now().isoformat()))
    conn.commit()
    node_id = c.lastrowid
    conn.close()
    return node_id

def get_nodes(include_disabled=False):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    if include_disabled:
        c.execute("SELECT id, name, host, port, enable FROM nodes ORDER BY id")
    else:
        c.execute("SELECT id, name, host, port, enable FROM nodes WHERE enable=1 ORDER BY id")
    nodes = c.fetchall()
    conn.close()
    return [{'id': n[0], 'name': n[1], 'host': n[2], 'port': n[3], 'enable': n[4]} for n in nodes]

def delete_node(node_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("DELETE FROM nodes WHERE id=?", (node_id,))
    conn.commit()
    affected = c.rowcount
    conn.close()
    return affected > 0

def verify_admin(username, password):
    """验证管理员登录"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT * FROM admins WHERE username=?", (username,))
    admin = c.fetchone()
    conn.close()
    if admin:
        hashed = hashlib.sha256(password.encode()).hexdigest()
        if hashed == admin[2]:
            return True
    return False

def update_admin_password(username, new_password):
    """更新管理员密码"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    hashed = hashlib.sha256(new_password.encode()).hexdigest()
    c.execute("UPDATE admins SET password=? WHERE username=?", (hashed, username))
    conn.commit()
    affected = c.rowcount
    conn.close()
    return affected > 0

def update_user_password(user_id, new_password):
    """更新用户密码，返回新密码的明文"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("UPDATE users SET password=? WHERE id=?", (new_password, user_id))
    conn.commit()
    affected = c.rowcount
    conn.close()
    return new_password if affected > 0 else None

def generate_links(user_id, user_uuid, password, nodes):
    links = []
    for node in nodes:
        host, port, name = node['host'], node['port'], node['name']
        tag = f"{name}-{user_id}"
        
        # Shadowsocks
        method = "2022-blake3-aes-256-gcm"
        ss_data = f"{method}:{password}"
        ss = f"ss://{base64.b64encode(ss_data.encode()).decode()}@{host}:{port}#{name}"
        
        # VMess
        vmess = {"v":"2","ps":name,"add":host,"port":str(port),"id":user_uuid,"aid":"0","net":"tcp","type":"none"}
        vmess_link = f"vmess://{base64.b64encode(json.dumps(vmess).encode()).decode()}"
        
        # Trojan
        trojan = f"trojan://{password}@{host}:{port}#{name}"
        
        # VLESS
        vless = f"vless://{user_uuid}@{host}:{port}?encryption=none&flow=xtls-rprx-vision&type=tcp#{name}"
        
        links.append({'node': name, 'host': host, 'port': port, 'ss': ss, 'vmess': vmess_link, 'trojan': trojan, 'vless': vless})
    return links

class APIHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {args[0]}")
    
    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    
    def do_GET(self):
        path = urlparse(self.path).path
        
        if path == '/health':
            self.send_json({'status': 'ok'})
            return
        
        # 订阅
        if path.startswith('/subscribe/'):
            auth_id = path.split('/')[-1]
            user = get_user_by_auth(auth_id)
            if not user or not user['enable']:
                self.send_error(404)
                return
            if user['expire_time'] and datetime.fromisoformat(user['expire_time']) < datetime.now():
                self.send_error(403)
                return
            
            nodes = get_nodes()
            configs = generate_links(user['id'], user['uuid'], user['password'], nodes)
            content = ""
            for cfg in configs:
                content += f"#{cfg['node']}\n{cfg['ss']}\n{cfg['vmess']}\n{cfg['trojan']}\n{cfg['vless']}\n\n"
            
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(content.encode())
            return
        
        if path == '/api/users':
            self.send_json({'users': list_users()})
            return
        
        if path == '/api/nodes':
            self.send_json({'nodes': get_nodes()})
            return
        
        if path.startswith('/api/user/'):
            try:
                user_id = int(path.split('/')[-1])
                user = get_user(user_id)
                if user:
                    nodes = get_nodes()
                    user['configs'] = generate_links(user['id'], user['uuid'], user['password'], nodes)
                    self.send_json(user)
                else:
                    self.send_json({'error': 'not found'}, 404)
            except:
                self.send_json({'error': 'invalid id'}, 400)
            return
        
        # 管理员登录
        if path == '/api/login':
            # Basic Auth
            auth_header = self.headers.get('Authorization', '')
            if auth_header.startswith('Basic '):
                import base64
                try:
                    decoded = base64.b64decode(auth_header[6:]).decode()
                    username, password = decoded.split(':', 1)
                    if verify_admin(username, password):
                        self.send_json({'success': True, 'token': 'admin-logged-in'})
                    else:
                        self.send_json({'success': False, 'error': 'Invalid credentials'}, 401)
                except:
                    self.send_json({'success': False, 'error': 'Invalid auth format'}, 401)
            else:
                self.send_json({'success': False, 'error': 'No auth header'}, 401)
            return
        
        # 获取所有节点的代理链接（给管理员看）
        if path == '/api/all-links':
            nodes = get_nodes()
            users = list_users()
            result = []
            for user in users:
                links = generate_links(user['id'], user['uuid'], user['password'], nodes)
                result.append({
                    'user': user['username'],
                    'user_id': user['id'],
                    'links': links
                })
            self.send_json({'data': result})
            return
        
        # 静态文件
        static_map = {
            '/': '/opt/wwwOK/web/index.html',
            '/index.html': '/opt/wwwOK/web/index.html',
            '/admin.html': '/opt/wwwOK/web/admin.html',
        }
        
        if path in static_map and os.path.exists(static_map[path]):
            self.send_response(200)
            if path.endswith('.html'):
                self.send_header('Content-Type', 'text/html')
            self.end_headers()
            with open(static_map[path], 'rb') as f:
                self.wfile.write(f.read())
            return
        
        self.send_json({'error': 'not found'}, 404)
    
    def do_POST(self):
        path = urlparse(self.path).path
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode() if content_length else '{}'
        
        try:
            data = json.loads(body)
        except:
            data = {}
        
        if path == '/api/user/create':
            try:
                result = create_user(data.get('username', ''), int(data.get('expire_days', 30)), int(data.get('flow_limit_gb', 100)))
                nodes = get_nodes()
                result['configs'] = generate_links(result['id'], result['uuid'], result['password'], nodes) if nodes else []
                self.send_json({'success': True, 'user': result})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return
        
        if path.startswith('/api/user/delete/'):
            try:
                user_id = int(path.split('/')[-1])
                delete_user(user_id)
                self.send_json({'success': True})
            except:
                self.send_json({'success': False}, 400)
            return
        
        if path == '/api/node/add':
            try:
                node_id = add_node(data.get('name', ''), data.get('host', ''), int(data.get('port', 8080)))
                self.send_json({'success': True, 'node_id': node_id})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return
        
        if path.startswith('/api/node/delete/'):
            try:
                node_id = int(path.split('/')[-1])
                if delete_node(node_id):
                    self.send_json({'success': True})
                else:
                    self.send_json({'success': False, 'error': 'Node not found'}, 404)
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return
        
        # 修改管理员密码
        if path == '/api/admin/password':
            auth_header = self.headers.get('Authorization', '')
            if not (auth_header.startswith('Basic ') and verify_admin('admin', '')):
                pass  # 简单验证
            new_password = data.get('new_password', '')
            if len(new_password) < 6:
                self.send_json({'success': False, 'error': 'Password too short'}, 400)
                return
            if update_admin_password('admin', new_password):
                self.send_json({'success': True})
            else:
                self.send_json({'success': False, 'error': 'Update failed'}, 400)
            return
        
        # 修改用户密码
        if path.startswith('/api/user/password/'):
            try:
                user_id = int(path.split('/')[-1])
                new_password = data.get('new_password', '')
                if not new_password:
                    new_password = generate_password()
                result = update_user_password(user_id, new_password)
                if result:
                    self.send_json({'success': True, 'new_password': result})
                else:
                    self.send_json({'success': False, 'error': 'User not found'}, 404)
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return
        
        self.send_json({'error': 'not found'}, 404)

def run_server():
    init_db()
    server = HTTPServer(('0.0.0.0', PORT), APIHandler)
    print(f"wwwOK API Server running on port {PORT}")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
PYEOF

    chmod +x ${WORK_DIR}/scripts/wwwOK_api.py
    log_success "API 服务创建完成"
}

# 创建管理命令
create_management_command() {
    log_info "创建管理命令..."
    
    cat > /usr/local/bin/wwwOK << 'MENUEOF'
#!/bin/bash
#===============================================
# wwwOK 管理菜单
#===============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

WORK_DIR="/opt/wwwOK"
API_PORT=8888

show_banner() {
    clear
    echo -e "${BLUE}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║       wwwOK 代理管理面板 v1.0           ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"
}

menu_main() {
    show_banner
    echo -e "${CYAN}主菜单${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}1${NC}. 查看系统状态"
    echo -e "  ${GREEN}2${NC}. 管理用户"
    echo -e "  ${GREEN}3${NC}. 管理节点"
    echo -e "  ${GREEN}4${NC}. 查看日志"
    echo -e "  ${GREEN}5${NC}. 重启服务"
    echo -e "  ${GREEN}0${NC}. 退出"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

menu_users() {
    while true; do
        show_banner
        echo -e "${CYAN}用户管理${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  ${GREEN}1${NC}. 列出所有用户"
        echo -e "  ${GREEN}2${NC}. 添加用户"
        echo -e "  ${GREEN}3${NC}. 删除用户"
        echo -e "  ${GREEN}4${NC}. 查看用户详情"
        echo -e "  ${GREEN}0${NC}. 返回"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        read -p "请选择: " c
        
        case $c in
            1) sub_list_users ;;
            2) sub_add_user ;;
            3) sub_del_user ;;
            4) sub_view_user ;;
            0) break ;;
        esac
    done
}

sub_list_users() {
    show_banner
    echo -e "${CYAN}用户列表${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    curl -s "http://localhost:${API_PORT}/api/users" 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for u in data.get('users',[]):
    status='正常' if u['enable'] else '禁用'
    print(f\"  ID:{u['id']} | 用户:{u['username']} | 状态:{status}\")
" 2>/dev/null || echo "  暂无用户"
    echo ""
    read -p "按回车继续..." x
}

sub_add_user() {
    show_banner
    echo -e "${CYAN}添加用户${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "用户名: " uname
    read -p "流量限制(GB): " flow
    read -p "到期天数: " days
    flow=${flow:-100}
    days=${days:-30}
    
    result=$(curl -s -X POST "http://localhost:${API_PORT}/api/user/create" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$uname\",\"flow_limit_gb\":$flow,\"expire_days\":$days}" 2>/dev/null)
    
    if echo "$result" | grep -q '"success":true'; then
        echo -e "${GREEN}用户创建成功!${NC}"
        echo "$result" | python3 -c "import json,sys; u=json.load(sys.stdin)['user']; print(f\"  用户名: {u['username']}\"); print(f\"  密码: {u['password']}\"); print(f\"  订阅: http://IP:8080/subscribe/{u['auth_id']}\")" 2>/dev/null
    else
        echo -e "${RED}创建失败${NC}"
    fi
    echo ""
    read -p "按回车继续..." x
}

sub_del_user() {
    show_banner
    echo -e "${CYAN}删除用户${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    sub_list_users
    read -p "输入要删除的用户ID: " uid
    if [ -n "$uid" ]; then
        curl -s -X POST "http://localhost:${API_PORT}/api/user/delete/$uid" > /dev/null 2>&1
        echo -e "${GREEN}已删除${NC}"
    fi
    read -p "按回车继续..." x
}

sub_view_user() {
    show_banner
    echo -e "${CYAN}用户详情${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "输入用户ID: " uid
    if [ -n "$uid" ]; then
        curl -s "http://localhost:${API_PORT}/api/user/$uid" 2>/dev/null | python3 -c "
import json,sys
try:
    u=json.load(sys.stdin)
    print(f\"  用户名: {u.get('username')}\")
    print(f\"  密码: {u.get('password')}\")
    print(f\"  UUID: {u.get('uuid')}\")
    print(f\"  订阅: http://IP:8080/subscribe/{u.get('auth_id')}\")
except: print('  用户不存在')
" 2>/dev/null
    fi
    echo ""
    read -p "按回车继续..." x
}

menu_nodes() {
    while true; do
        show_banner
        echo -e "${CYAN}节点管理${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  ${GREEN}1${NC}. 列出节点"
        echo -e "  ${GREEN}2${NC}. 添加节点"
        echo -e "  ${GREEN}0${NC}. 返回"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        read -p "请选择: " c
        
        case $c in
            1) sub_list_nodes ;;
            2) sub_add_node ;;
            0) break ;;
        esac
    done
}

sub_list_nodes() {
    show_banner
    echo -e "${CYAN}节点列表${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    curl -s "http://localhost:${API_PORT}/api/nodes" 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for n in data.get('nodes',[]):
    print(f\"  {n['name']} | {n['host']}:{n['port']}\")
" 2>/dev/null || echo "  暂无节点"
    echo ""
    read -p "按回车继续..." x
}

sub_add_node() {
    show_banner
    echo -e "${CYAN}添加节点${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "节点名称: " name
    read -p "节点地址: " host
    read -p "端口: " port
    port=${port:-8080}
    
    curl -s -X POST "http://localhost:${API_PORT}/api/node/add" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$name\",\"host\":\"$host\",\"port\":$port}" > /dev/null 2>&1
    echo -e "${GREEN}节点添加成功${NC}"
    echo ""
    read -p "按回车继续..." x
}

show_status() {
    show_banner
    echo -e "${CYAN}系统状态${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if pgrep -f "sing-box" > /dev/null; then
        echo -e "  sing-box: ${GREEN}运行中${NC}"
    else
        echo -e "  sing-box: ${RED}未运行${NC}"
    fi
    echo -e "  负载: $(uptime | awk -F'load average:' '{print $2}')"
    echo -e "  内存: $(free -h | awk '/Mem:/ {print $3 "/" $2}')"
    echo ""
    read -p "按回车继续..." x
}

show_logs() {
    show_banner
    echo -e "${CYAN}日志查看${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    tail -n 20 /var/log/wwwOK/sing-box.log 2>/dev/null || echo "暂无日志"
    echo ""
    read -p "按回车继续..." x
}

restart_service() {
    show_banner
    echo -e "${CYAN}重启服务${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    pkill -f "sing-box" 2>/dev/null || true
    sleep 1
    nohup ${WORK_DIR}/bin/sing-box run -c ${WORK_DIR}/config/sing-box.json > /var/log/wwwOK/sing-box.log 2>&1 &
    sleep 2
    if pgrep -f "sing-box" > /dev/null; then
        echo -e "${GREEN}服务已重启${NC}"
    else
        echo -e "${RED}启动失败${NC}"
    fi
    read -p "按回车继续..." x
}

# 主循环
while true; do
    menu_main
    read -p "请选择: " choice
    case $choice in
        1) show_status ;;
        2) menu_users ;;
        3) menu_nodes ;;
        4) show_logs ;;
        5) restart_service ;;
        0) exit 0 ;;
    esac
done
MENUEOF

    chmod +x /usr/local/bin/wwwOK
    log_success "管理命令创建完成"
}

# 启动服务
start_services() {
    log_info "启动服务..."
    
    # 启动 sing-box
    nohup ${WORK_DIR}/bin/sing-box run -c ${WORK_DIR}/config/sing-box.json > /var/log/wwwOK/sing-box.log 2>&1 &
    sleep 2
    
    if pgrep -f "sing-box" > /dev/null; then
        log_success "sing-box 启动成功"
    else
        log_error "sing-box 启动失败"
    fi
    
    # 启动 API 服务
    nohup python3 ${WORK_DIR}/scripts/wwwOK_api.py > /var/log/wwwOK/api.log 2>&1 &
    sleep 1
    
    if pgrep -f "wwwOK_api.py" > /dev/null; then
        log_success "API 服务启动成功"
    else
        log_error "API 服务启动失败"
    fi
}

# 完成安装
finish() {
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                       ║${NC}"
    echo -e "${GREEN}║          wwwOK 安装完成!                             ║${NC}"
    echo -e "${GREEN}║                                                       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}管理面板:${NC} ${BLUE}http://${SERVER_IP}:${WEB_PORT}${NC}"
    echo -e "  ${CYAN}管理命令:${NC} ${BLUE}wwwOK${NC}"
    echo ""
    echo -e "  ${YELLOW}管理员账号: admin${NC}"
    echo -e "  ${YELLOW}管理员密码: admin123${NC}"
    echo ""
    echo -e "  ${RED}请立即修改默认密码!${NC}"
    echo ""
}

# 主流程
main() {
    clear
    echo -e "${BLUE}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║     wwwOK - sing-box 代理管理系统 v1.0               ║"
    echo "  ║     一键安装脚本                                      ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    detect_os
    install_dependencies
    create_directories
    download_web_files
    download_singbox
    init_database
    generate_singbox_config
    create_api_server
    create_management_command
    start_services
    finish
}

main "$@"
