#!/bin/bash
#===============================================
# wwwOK 一键安装脚本 (完整版)
# 支持: Ubuntu/Debian/CentOS/AlmaLinux/Rocky
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/HYweb3/wwwOK/main/install.sh | bash
#===============================================

set -e

# TERM 问题修复（非交互式环境）
if [ -z "$TERM" ]; then export TERM=dumb; fi
clear() { command clear 2>/dev/null || true; }

WORK_DIR="/opt/wwwOK"
WEB_PORT=8888
API_PORT=8888

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

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

install_dependencies() {
    log_info "安装系统依赖..."
    case $OS in
        ubuntu|debian|linuxmint|pop)
            apt update
            apt install -y curl wget unzip python3 python3-pip sqlite3 qrencode expect
            ;;
        centos|rhel|almalinux|rocky)
            yum update -y
            yum install -y curl wget unzip python3 sqlite qrencode expect
            ;;
        fedora)
            dnf update -y
            dnf install -y curl wget unzip python3 sqlite qrencode expect
            ;;
        *)
            apt update && apt install -y curl wget unzip python3 sqlite3 qrencode expect 2>/dev/null || \
            yum update && yum install -y curl wget unzip python3 sqlite qrencode expect 2>/dev/null || true
            ;;
    esac
    pip3 install python-dateutil --quiet 2>/dev/null || pip3 install python-dateutil
    log_success "依赖安装完成"
}

download_singbox() {
    log_info "下载 sing-box v1.13.11..."
    SINGBOX_VER="v1.13.11"
    mkdir -p ${WORK_DIR}/bin
    cd /tmp
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VER}/sing-box-${SINGBOX_VER#v}-linux-${ARCH}.tar.gz"
    log_info "下载链接: $DOWNLOAD_URL"
    if curl -fL -o sing-box.tar.gz "$DOWNLOAD_URL" 2>/dev/null; then
        tar -xzf sing-box.tar.gz
        mv sing-box-${SINGBOX_VER#v}-linux-${ARCH}/sing-box ${WORK_DIR}/bin/
        chmod +x ${WORK_DIR}/bin/sing-box
        rm -rf sing-box.tar.gz sing-box-${SINGBOX_VER#v}-linux-${ARCH}
        log_success "sing-box v1.13.11 下载完成"
    else
        log_error "sing-box 下载失败，请检查网络连接"
    fi
}

create_directories() {
    log_info "创建目录结构..."
    mkdir -p ${WORK_DIR}/{bin,config,web/admin,db,logs,scripts}
    mkdir -p /var/log/wwwOK
    log_success "目录创建完成"
}

download_web_files() {
    log_info "下载 Web 前端文件..."
    WEB_URL="https://raw.githubusercontent.com/HYweb3/wwwOK/main/web"
    curl -sL "${WEB_URL}/index.html" -o ${WORK_DIR}/web/index.html || {
        log_error "下载 index.html 失败"
    }
    log_success "Web 前端文件下载完成"
}

init_database() {
    log_info "初始化数据库..."
    python3 << 'PYEOF'
import sqlite3, os, hashlib
from datetime import datetime

db_path = "/opt/wwwOK/db/users.db"
os.makedirs(os.path.dirname(db_path), exist_ok=True)

conn = sqlite3.connect(db_path)
conn.text_factory = str
c = conn.cursor()

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

c.execute('''CREATE TABLE IF NOT EXISTS admins (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    created_time TEXT
)''')

c.execute('''CREATE TABLE IF NOT EXISTS nodes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    host TEXT NOT NULL,
    port INTEGER DEFAULT 8080,
    enable INTEGER DEFAULT 1,
    created_time TEXT
)''')

# 添加默认管理员 (密码: vip@8888999)
c.execute("SELECT * FROM admins WHERE username='admin'")
if not c.fetchone():
    pwd_hash = hashlib.sha256("vip@8888999".encode('utf-8')).hexdigest()
    c.execute("INSERT INTO admins (username, password, created_time) VALUES (?, ?, ?)",
             ("admin", pwd_hash, datetime.now().isoformat()))
    print("Default admin created: admin / vip@8888999")

# 自动添加本服务器为默认节点
import urllib.request
try:
    public_ip = urllib.request.urlopen('https://api.ipify.org', timeout=5).read().decode()
except:
    try:
        public_ip = urllib.request.urlopen('https://icanhazip.com', timeout=5).read().decode().strip()
    except:
        public_ip = '127.0.0.1'

c.execute("SELECT * FROM nodes WHERE host=?", (public_ip,))
if not c.fetchone():
    c.execute("INSERT INTO nodes (name, host, port, enable, created_time) VALUES (?, ?, ?, ?, ?)",
             ("默认节点", public_ip, 8080, 1, datetime.now().isoformat()))
    print(f"Default node added: {public_ip}")

conn.commit()
conn.close()
print("Database initialized")
PYEOF
    log_success "数据库初始化完成"
}

generate_initial_singbox_config() {
    log_info "生成初始 sing-box 配置..."
    cat > ${WORK_DIR}/config/sing-box.json << 'EOF'
{
    "log": {"level": "info", "output": "/var/log/wwwOK/sing-box.log", "timestamp": true},
    "inbounds": [
        {"tag": "ss-in", "type": "shadowsocks", "listen": "0.0.0.0", "listen_port": 9000, "method": "2022-blake3-aes-256-gcm", "password": "REPLACE_WITH_DYNAMIC_PSK"}
    ],
    "outbounds": [
        {"tag": "direct", "type": "direct"},
        {"tag": "block", "type": "block"}
    ]
}
EOF
    log_success "初始配置生成完成"
}

create_singbox_config_generator() {
    log_info "创建 sing-box 配置生成器..."
    cat > ${WORK_DIR}/scripts/gen_singbox_config.py << 'PYEOF'
#!/usr/bin/env python3
"""动态生成 sing-box 多协议配置"""
import sqlite3, os, json, base64, subprocess

DB_PATH = "/opt/wwwOK/db/users.db"
CONFIG_PATH = "/opt/wwwOK/config/sing-box.json"

def get_db_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.text_factory = str
    return conn

def get_all_users():
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("SELECT id, username, password, uuid, enable, auth_id FROM users WHERE enable=1")
    users = c.fetchall()
    conn.close()
    return [{'id': u[0], 'username': u[1], 'password': u[2], 'uuid': u[3], 'enable': u[4], 'auth_id': u[5]} for u in users]

def get_all_nodes():
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("SELECT id, name, host, port, enable FROM nodes WHERE enable=1")
    nodes = c.fetchall()
    conn.close()
    return [{'id': n[0], 'name': n[1], 'host': n[2], 'port': n[3], 'enable': n[4]} for n in nodes]

def gen_ss2022_psk():
    return base64.b64encode(os.urandom(32)).decode()

def generate_config():
    users = get_all_users()
    nodes = get_all_nodes()
    ss_global_psk = gen_ss2022_psk()

    inbounds = [
        {
            "tag": "ss-in",
            "type": "shadowsocks",
            "listen": "0.0.0.0",
            "listen_port": 9000,
            "method": "2022-blake3-aes-256-gcm",
            "password": ss_global_psk
        },
        {
            "tag": "vmess-in",
            "type": "vmess",
            "listen": "0.0.0.0",
            "listen_port": 9001,
            "users": [{"id": u["uuid"], "email": u["username"]} for u in users]
        },
        {
            "tag": "trojan-in",
            "type": "trojan",
            "listen": "0.0.0.0",
            "listen_port": 9002,
            "users": [{"password": u["password"], "email": u["username"]} for u in users]
        },
        {
            "tag": "vless-in",
            "type": "vless",
            "listen": "0.0.0.0",
            "listen_port": 9003,
            "users": [{"id": u["uuid"], "email": u["username"]} for u in users]
        }
    ]

    config = {
        "log": {"level": "info", "output": "/var/log/wwwOK/sing-box.log", "timestamp": True},
        "inbounds": inbounds,
        "outbounds": [{"tag": "direct", "type": "direct"}, {"tag": "block", "type": "block"}]
    }

    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=4)
    print(f"Generated: {len(users)} users, {len(nodes)} nodes")

    for sig in ['HUP', 'TERM']:
        try:
            subprocess.run(['systemctl', 'kill', f'-s{sig}', 'sing-box'], capture_output=True, timeout=5)
            print(f"sing-box reloaded via systemctl -s{sig}")
            return
        except:
            pass
    try:
        subprocess.run(['killall', '-HUP', 'sing-box'], capture_output=True, timeout=5)
        print("sing-box reloaded via killall")
    except:
        print("Warning: could not reload sing-box, restart manually if needed")

if __name__ == '__main__':
    generate_config()
PYEOF
    chmod +x ${WORK_DIR}/scripts/gen_singbox_config.py
    log_success "配置生成器创建完成"
}

create_api_server() {
    log_info "创建 API 服务..."
    cat > ${WORK_DIR}/scripts/wwwOK_api.py << 'PYEOF'
#!/usr/bin/env python3
"""wwwOK API 服务 (Python 3.6兼容+修复版)"""
import sqlite3, uuid, string, secrets, hashlib, json, time, os, subprocess
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, quote
import base64

try:
    from dateutil.parser import parse as dt_parse
except ImportError:
    def dt_parse(s):
        return datetime.fromisoformat(s)

DB_PATH = "/opt/wwwOK/db/users.db"
CONFIG_PATH = "/opt/wwwOK/config/sing-box.json"
SCRIPTS_DIR = "/opt/wwwOK/scripts"
PORT = 8888

def get_db_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.text_factory = str
    return conn

def init_db():
    conn = get_db_conn()
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL, uuid TEXT UNIQUE NOT NULL, enable INTEGER DEFAULT 1,
        flow_limit INTEGER DEFAULT 107374182400, flow_used INTEGER DEFAULT 0,
        expire_time TEXT, created_time TEXT, last_login TEXT, auth_id TEXT)''')
    c.execute('''CREATE TABLE IF NOT EXISTS admins (
        id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL, created_time TEXT)''')
    c.execute('''CREATE TABLE IF NOT EXISTS nodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
        host TEXT NOT NULL, port INTEGER DEFAULT 8080, enable INTEGER DEFAULT 1, created_time TEXT)''')
    c.execute("SELECT * FROM admins WHERE username='admin'")
    if not c.fetchone():
        hashed = hashlib.sha256("vip@8888999".encode('utf-8')).hexdigest()
        c.execute("INSERT INTO admins (username, password, created_time) VALUES (?, ?, ?)",
                 ("admin", hashed, datetime.now().isoformat()))
    conn.commit()
    conn.close()

def generate_password(length=32):
    return ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(length))
def generate_uuid(): return str(uuid.uuid4())
def generate_auth_id(): return secrets.token_urlsafe(16)

def reload_singbox_config():
    try:
        r = subprocess.run(['python3', f'{SCRIPTS_DIR}/gen_singbox_config.py'],
                          capture_output=True, text=True, timeout=15)
        print(f"gen_config: {r.stdout.strip()}")
    except Exception as e:
        print(f"gen_config failed: {e}")
    for sig in ['HUP', 'TERM']:
        try:
            subprocess.run(['systemctl', 'kill', f'-s{sig}', 'sing-box'],
                          capture_output=True, timeout=5); return
        except: pass
    try:
        subprocess.run(['killall', '-HUP', 'sing-box'], capture_output=True, timeout=5)
    except: pass

def create_user(username, expire_days=30, flow_limit_gb=100):
    conn = get_db_conn(); c = conn.cursor()
    password = generate_password()
    user_uuid = generate_uuid()
    auth_id = generate_auth_id()
    expire_time = (datetime.now() + timedelta(days=expire_days)).isoformat()
    flow_limit = flow_limit_gb * 1024 * 1024 * 1024
    try:
        c.execute('''INSERT INTO users (username, password, uuid, expire_time, flow_limit, created_time, auth_id)
                     VALUES (?, ?, ?, ?, ?, ?, ?)''',
                  (username, password, user_uuid, expire_time, flow_limit, datetime.now().isoformat(), auth_id))
        conn.commit(); user_id = c.lastrowid; conn.close()
        reload_singbox_config()
        return {'id': user_id, 'username': username, 'password': password, 'uuid': user_uuid, 'auth_id': auth_id}
    except Exception as e:
        conn.close(); raise e

def get_user(user_id):
    conn = get_db_conn(); c = conn.cursor()
    c.execute("SELECT * FROM users WHERE id=?", (user_id,)); user = c.fetchone(); conn.close()
    if user:
        return {'id': user[0], 'username': user[1], 'password': user[2], 'uuid': user[3], 'enable': user[4],
                'flow_limit': user[5], 'flow_used': user[6], 'expire_time': user[7], 'created_time': user[8],
                'last_login': user[9], 'auth_id': user[10]}
    return None

def get_user_by_auth(auth_id):
    conn = get_db_conn(); c = conn.cursor()
    c.execute("SELECT * FROM users WHERE auth_id=?", (auth_id,)); user = c.fetchone(); conn.close()
    if user:
        return {'id': user[0], 'username': user[1], 'password': user[2], 'uuid': user[3], 'enable': user[4],
                'flow_limit': user[5], 'flow_used': user[6], 'expire_time': user[7], 'created_time': user[8],
                'last_login': user[9], 'auth_id': user[10]}
    return None

def list_users():
    conn = get_db_conn(); c = conn.cursor()
    c.execute("SELECT id, username, enable, flow_limit, flow_used, expire_time, created_time FROM users ORDER BY id")
    users = c.fetchall(); conn.close()
    return [{'id': u[0], 'username': u[1], 'enable': u[2], 'flow_limit': u[3],
             'flow_used': u[4], 'expire_time': u[5], 'created_time': u[6]} for u in users]

def delete_user(user_id):
    conn = get_db_conn(); c = conn.cursor()
    c.execute("DELETE FROM users WHERE id=?", (user_id,)); conn.commit(); conn.close()
    reload_singbox_config()

def add_node(name, host, port=8080):
    conn = get_db_conn(); c = conn.cursor()
    c.execute("INSERT INTO nodes (name, host, port, created_time) VALUES (?, ?, ?, ?)",
             (name, host, port, datetime.now().isoformat()))
    conn.commit(); node_id = c.lastrowid; conn.close()
    reload_singbox_config()
    return node_id

def get_nodes(include_disabled=False):
    conn = get_db_conn(); c = conn.cursor()
    if include_disabled:
        c.execute("SELECT id, name, host, port, enable FROM nodes ORDER BY id")
    else:
        c.execute("SELECT id, name, host, port, enable FROM nodes WHERE enable=1 ORDER BY id")
    nodes = c.fetchall(); conn.close()
    return [{'id': n[0], 'name': n[1], 'host': n[2], 'port': n[3], 'enable': n[4]} for n in nodes]

def delete_node(node_id):
    conn = get_db_conn(); c = conn.cursor()
    c.execute("DELETE FROM nodes WHERE id=?", (node_id,)); conn.commit()
    affected = c.rowcount; conn.close()
    if affected > 0: reload_singbox_config()
    return affected > 0

def verify_admin(username, password):
    conn = get_db_conn(); c = conn.cursor()
    c.execute("SELECT * FROM admins WHERE username=?", (username,)); admin = c.fetchone(); conn.close()
    if admin:
        if hashlib.sha256(password.encode('utf-8')).hexdigest() == admin[2]: return True
    return False

def update_admin_password(username, new_password):
    conn = get_db_conn(); c = conn.cursor()
    hashed = hashlib.sha256(new_password.encode('utf-8')).hexdigest()
    c.execute("UPDATE admins SET password=? WHERE username=?", (hashed, username))
    conn.commit(); affected = c.rowcount; conn.close()
    return affected > 0

def update_user_password(user_id, new_password=None):
    if new_password is None: new_password = generate_password()
    conn = get_db_conn(); c = conn.cursor()
    c.execute("UPDATE users SET password=? WHERE id=?", (new_password, user_id))
    conn.commit(); conn.close()
    reload_singbox_config()
    return new_password

def generate_links(user_id, user_uuid, password, nodes):
    links = []
    for node in nodes:
        host, name = node['host'], quote(node['name'], safe='')
        method = "2022-blake3-aes-256-gcm"
        ss_data = f"{method}:{password}"
        ss = f"ss://{base64.b64encode(ss_data.encode('utf-8')).decode()}@{host}:9000#{name}"
        vmess = {"v":"2","ps":node['name'],"add":host,"port":"9001","id":user_uuid,"aid":"0","net":"tcp","type":"none"}
        vmess_link = f"vmess://{base64.b64encode(json.dumps(vmess).encode('utf-8')).decode()}"
        trojan = f"trojan://{password}@{host}:9002#{name}"
        vless = f"vless://{user_uuid}@{host}:9003?encryption=none&flow=xtls-rprx-vision&type=tcp#{name}"
        links.append({'node': node['name'], 'host': host, 'port': node['port'], 'ss': ss, 'vmess': vmess_link, 'trojan': trojan, 'vless': vless})
    return links

class APIHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {args[0]}")
    def send_json(self, data, status=200):
        content = json.dumps(data, ensure_ascii=False)
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(content.encode('utf-8'))
    def send_text(self, content, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(content.encode('utf-8'))

    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/health':
            self.send_json({'status': 'ok'}); return
        if path.startswith('/subscribe/'):
            auth_id = path.split('/')[-1]; user = get_user_by_auth(auth_id)
            if not user or not user['enable']: self.send_error(404); return
            if user['expire_time']:
                try:
                    if dt_parse(user['expire_time']) < datetime.now(): self.send_error(403); return
                except: pass
            nodes = get_nodes(); configs = generate_links(user['id'], user['uuid'], user['password'], nodes)
            content = "".join(f"#{cfg['node']}\n{cfg['ss']}\n{cfg['vmess']}\n{cfg['trojan']}\n{cfg['vless']}\n\n" for cfg in configs)
            self.send_text(content); return
        if path == '/api/users': self.send_json({'users': list_users()}); return
        if path == '/api/nodes': self.send_json({'nodes': get_nodes()}); return
        if path.startswith('/api/user/') and path != '/api/user/create':
            try:
                user_id = int(path.split('/')[-1]); user = get_user(user_id)
                if user:
                    nodes = get_nodes(); user['configs'] = generate_links(user['id'], user['uuid'], user['password'], nodes)
                    self.send_json(user)
                else: self.send_json({'error': 'not found'}, 404)
            except: self.send_json({'error': 'invalid id'}, 400)
            return
        if path == '/api/login':
            auth_header = self.headers.get('Authorization', '')
            if auth_header.startswith('Basic '):
                try:
                    decoded = base64.b64decode(auth_header[6:]).decode('utf-8')
                    username, password = decoded.split(':', 1)
                    if verify_admin(username, password): self.send_json({'success': True, 'token': 'admin-logged-in'})
                    else: self.send_json({'success': False, 'error': 'Invalid credentials'}, 401)
                except: self.send_json({'success': False, 'error': 'Invalid auth format'}, 401)
            else: self.send_json({'success': False, 'error': 'No auth header'}, 401)
            return
        if path == '/api/all-links':
            nodes = get_nodes(); users = list_users(); result = []
            for user in users:
                u = get_user(user['id'])
                if u: result.append({'user': user['username'], 'user_id': user['id'],
                                     'links': generate_links(u['id'], u['uuid'], u['password'], nodes)})
            self.send_json({'data': result}); return
        static_map = {'/': '/opt/wwwOK/web/index.html', '/index.html': '/opt/wwwOK/web/index.html'}
        if path in static_map and os.path.exists(static_map[path]):
            self.send_response(200)
            if path.endswith('.html'): self.send_header('Content-Type', 'text/html')
            self.end_headers()
            with open(static_map[path], 'rb') as f: self.wfile.write(f.read())
            return
        self.send_json({'error': 'not found'}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length else '{}'
        try: data = json.loads(body)
        except: data = {}
        if path == '/api/user/create':
            try:
                result = create_user(data.get('username', ''), int(data.get('expire_days', 30)), int(data.get('flow_limit_gb', 100)))
                nodes = get_nodes()
                result['configs'] = generate_links(result['id'], result['uuid'], result['password'], nodes) if nodes else []
                self.send_json({'success': True, 'user': result})
            except Exception as e: self.send_json({'success': False, 'error': str(e)}, 400)
            return
        if path.startswith('/api/user/delete/'):
            try: delete_user(int(path.split('/')[-1])); self.send_json({'success': True})
            except: self.send_json({'success': False}, 400)
            return
        if path == '/api/node/add':
            try: node_id = add_node(data.get('name', ''), data.get('host', ''), int(data.get('port', 8080))); self.send_json({'success': True, 'node_id': node_id})
            except Exception as e: self.send_json({'success': False, 'error': str(e)}, 400)
            return
        if path.startswith('/api/node/delete/'):
            try:
                node_id = int(path.split('/')[-1])
                if delete_node(node_id): self.send_json({'success': True})
                else: self.send_json({'success': False, 'error': 'Node not found'}, 404)
            except Exception as e: self.send_json({'success': False, 'error': str(e)}, 400)
            return
        if path == '/api/admin/password':
            new_password = data.get('new_password', '')
            if len(new_password) < 6: self.send_json({'success': False, 'error': 'Password too short'}, 400); return
            if update_admin_password('admin', new_password): self.send_json({'success': True})
            else: self.send_json({'success': False, 'error': 'Update failed'}, 400)
            return
        if path.startswith('/api/user/password/'):
            try:
                user_id = int(path.split('/')[-1])
                new_password = data.get('new_password', '')
                result = update_user_password(user_id, new_password if new_password else None)
                if result: self.send_json({'success': True, 'new_password': result})
                else: self.send_json({'success': False, 'error': 'User not found'}, 404)
            except Exception as e: self.send_json({'success': False, 'error': str(e)}, 400)
            return
        self.send_json({'error': 'not found'}, 404)

def run_server():
    init_db()
    server = HTTPServer(('0.0.0.0', PORT), APIHandler)
    print(f"wwwOK API running on port {PORT}")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
PYEOF
    chmod +x ${WORK_DIR}/scripts/wwwOK_api.py
    log_success "API 服务创建完成"
}

create_systemd_services() {
    log_info "创建 systemd 服务..."
    
    cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box proxy service
After=network.target

[Service]
Type=simple
ExecStart=/opt/wwwOK/bin/sing-box run -c /opt/wwwOK/config/sing-box.json
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/wwwOK_api.service << 'EOF'
[Unit]
Description=wwwOK API service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /opt/wwwOK/scripts/wwwOK_api.py
Restart=always
RestartSec=5
User=root
Environment=PYTHONIOENCODING=utf-8

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "systemd 服务创建完成"
}

start_services() {
    log_info "启动服务..."
    
    # 先杀掉旧进程
    killall sing-box wwwOK_api.py 2>/dev/null || true
    sleep 2
    
    # 生成初始代理配置（用户+节点）
    log_info "生成代理配置..."
    python3 ${WORK_DIR}/scripts/gen_singbox_config.py
    
    # systemd 管理
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable sing-box wwwOK_api 2>/dev/null || true
    
    # 启动
    systemctl start sing-box 2>/dev/null || \
        nohup ${WORK_DIR}/bin/sing-box run -c ${WORK_DIR}/config/sing-box.json > /var/log/wwwOK/sing-box.log 2>&1 &
    sleep 2
    
    systemctl start wwwOK_api 2>/dev/null || \
        nohup python3 -u ${WORK_DIR}/scripts/wwwOK_api.py > /var/log/wwwOK/api.log 2>&1 &
    sleep 2
    
    # 验证
    if systemctl is-active --quiet sing-box 2>/dev/null || pgrep -f "sing-box" > /dev/null; then
        log_success "sing-box: running"
    else
        log_warn "sing-box: not running, check journalctl -u sing-box"
    fi
    
    if systemctl is-active --quiet wwwOK_api 2>/dev/null || pgrep -f "wwwOK_api.py" > /dev/null; then
        log_success "wwwOK_api: running"
    else
        log_warn "wwwOK_api: not running, check journalctl -u wwwOK_api"
    fi
}

finish() {
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          wwwOK 安装完成!                             ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}管理面板:${NC} ${BLUE}http://${SERVER_IP}:${WEB_PORT}${NC}"
    echo -e "  ${CYAN}API端口:${NC}  ${BLUE}${API_PORT}${NC}"
    echo ""
    echo -e "  ${CYAN}代理端口:${NC}"
    echo -e "    SS2022:    ${BLUE}9000${NC}"
    echo -e "    VMess:     ${BLUE}9001${NC}"
    echo -e "    Trojan:    ${BLUE}9002${NC}"
    echo -e "    VLESS:     ${BLUE}9003${NC}"
    echo ""
    echo -e "  ${YELLOW}管理员账号: admin${NC}"
    echo -e "  ${YELLOW}管理员密码: vip@8888999${NC}"
    echo ""
    echo -e "  ${CYAN}服务管理:${NC}"
    echo -e "    systemctl start|stop|restart sing-box"
    echo -e "    systemctl start|stop|restart wwwOK_api"
    echo ""
    echo -e "  ${RED}请立即修改默认密码!${NC}"
}

main() {
    clear
    echo -e "${BLUE}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║     wwwOK - sing-box 代理管理系统 v2.0              ║"
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
    generate_initial_singbox_config
    create_singbox_config_generator
    create_api_server
    create_systemd_services
    start_services
    finish
}

main "$@"
