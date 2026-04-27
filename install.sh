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
API_PORT=8888
SS_PORT=9000; VMESS_PORT=9001; TROJAN_PORT=9002; VLESS_PORT=9003
SB_VERSION="1.13.11"

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

    cat > ${SCRIPTS_DIR}/gen_singbox_config.py << 'PYEOF'
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

PSK_FILE = "/opt/wwwOK/db/ss_psk.txt"

def gen_ss2022_psk():
    return base64.b64encode(os.urandom(32)).decode()

def get_stable_psk():
    try:
        if os.path.exists(PSK_FILE):
            with open(PSK_FILE, 'r') as f:
                return f.read().strip()
    except: pass
    psk = gen_ss2022_psk()
    try:
        with open(PSK_FILE, 'w') as f:
            f.write(psk)
    except: pass
    return psk

def generate_config():
    users = get_all_users()
    nodes = get_all_nodes()
    ss_global_psk = get_stable_psk()

    inbounds = [
        {"tag": "ss-in", "type": "shadowsocks", "listen": "0.0.0.0", "listen_port": 9000,
         "method": "2022-blake3-aes-256-gcm", "password": ss_global_psk},
        {"tag": "vmess-in", "type": "vmess", "listen": "0.0.0.0", "listen_port": 9001,
         "users": [{"uuid": u["uuid"]} for u in users]},
        {"tag": "trojan-in", "type": "trojan", "listen": "0.0.0.0", "listen_port": 9002,
         "users": [{"password": u["password"]} for u in users]},
        {"tag": "vless-in", "type": "vless", "listen": "0.0.0.0", "listen_port": 9003,
         "users": [{"uuid": u["uuid"]} for u in users]}
    ]

    config = {"log": {"level": "info", "output": "/var/log/wwwOK/sing-box.log", "timestamp": True},
              "inbounds": inbounds,
              "outbounds": [{"tag": "direct", "type": "direct"}, {"tag": "block", "type": "block"}]}

    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=4)
    print("Generated: {} users, {} nodes".format(len(users), len(nodes)))

    for sig in ['HUP', 'TERM']:
        try:
            subprocess.run(['systemctl', 'kill', '-s'+sig, 'sing-box'],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            print("sing-box reloaded via systemctl -{}".format(sig))
            return
        except: pass
    try:
        subprocess.run(['killall', '-HUP', 'sing-box'],
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        print("sing-box reloaded via killall")
    except:
        print("Warning: could not reload sing-box, restart manually if needed")

if __name__ == '__main__':
    generate_config()
PYEOF

    cat > ${SCRIPTS_DIR}/wwwOK_api.py << 'PYEOF'
#!/usr/bin/env python3
"""wwwOK API 服务 (Python 3.6兼容版) v2.0
基于 GitHub HYweb3/wwwOK main 分支
修复: uuid not id, no email in vmess/vless users, stable PSK, base64 subscribe
"""
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
    c.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, uuid TEXT UNIQUE NOT NULL, enable INTEGER DEFAULT 1, flow_limit INTEGER DEFAULT 107374182400, flow_used INTEGER DEFAULT 0, expire_time TEXT, created_time TEXT, last_login TEXT, auth_id TEXT)")
    c.execute("CREATE TABLE IF NOT EXISTS admins (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, created_time TEXT)")
    c.execute("CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, host TEXT NOT NULL, port INTEGER DEFAULT 8080, enable INTEGER DEFAULT 1, created_time TEXT)")
    try:
        c.execute("ALTER TABLE nodes ADD COLUMN ss_password TEXT DEFAULT ''")
        conn.commit()
    except: pass
    c.execute("SELECT * FROM admins WHERE username='admin'")
    if not c.fetchone():
        hashed = hashlib.sha256("vip@8888999".encode('utf-8')).hexdigest()
        c.execute("INSERT INTO admins (username, password, created_time) VALUES (?, ?, ?)", ("admin", hashed, datetime.now().isoformat()))
    conn.commit()
    conn.close()

def generate_password(length=32):
    return ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(length))
def generate_uuid(): return str(uuid.uuid4())
def generate_auth_id(): return secrets.token_urlsafe(16)

def reload_singbox_config():
    try:
        r = subprocess.run(['python3', SCRIPTS_DIR + '/gen_singbox_config.py'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        if r.stdout: print(r.stdout.strip().decode())
    except Exception as e:
        print("gen_config failed: " + str(e))
    for sig in ['HUP', 'TERM']:
        try:
            subprocess.run(['systemctl', 'kill', '-s'+sig, 'sing-box'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            return
        except: pass
    try:
        subprocess.run(['killall', '-HUP', 'sing-box'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    except: pass

def create_user(username, expire_days=365, flow_limit_gb=1000):
    conn = get_db_conn()
    c = conn.cursor()
    password = generate_password()
    user_uuid = generate_uuid()
    auth_id = generate_auth_id()
    expire_time = (datetime.now() + timedelta(days=expire_days)).isoformat()
    flow_limit = flow_limit_gb * 1024 * 1024 * 1024
    try:
        c.execute("INSERT INTO users (username, password, uuid, expire_time, flow_limit, created_time, auth_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
                  (username, password, user_uuid, expire_time, flow_limit, datetime.now().isoformat(), auth_id))
        conn.commit()
        user_id = c.lastrowid
        conn.close()
        reload_singbox_config()
        return {'id': user_id, 'username': username, 'password': password, 'uuid': user_uuid, 'auth_id': auth_id}
    except Exception as e:
        conn.close()
        raise e

def get_user(user_id):
    conn = get_db_conn()
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
    conn = get_db_conn()
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
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("SELECT id, username, enable, flow_limit, flow_used, expire_time, created_time FROM users ORDER BY id")
    users = c.fetchall()
    conn.close()
    return [{'id': u[0], 'username': u[1], 'enable': u[2], 'flow_limit': u[3],
             'flow_used': u[4], 'expire_time': u[5], 'created_time': u[6]} for u in users]

def delete_user(user_id):
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("DELETE FROM users WHERE id=?", (user_id,))
    conn.commit()
    conn.close()
    reload_singbox_config()

def add_node(name, host, port=8080, ss_password=None):
    conn = get_db_conn()
    c = conn.cursor()
    has_ss_password = True
    try:
        c.execute("SELECT ss_password FROM nodes LIMIT 1")
    except:
        has_ss_password = False
    if has_ss_password and ss_password:
        c.execute("INSERT INTO nodes (name, host, port, ss_password, created_time) VALUES (?, ?, ?, ?, ?)",
                 (name, host, port, ss_password, datetime.now().isoformat()))
    else:
        c.execute("INSERT INTO nodes (name, host, port, created_time) VALUES (?, ?, ?, ?)",
                 (name, host, port, datetime.now().isoformat()))
    conn.commit()
    node_id = c.lastrowid
    conn.close()
    reload_singbox_config()
    return node_id

def get_nodes(include_disabled=False):
    conn = get_db_conn()
    c = conn.cursor()
    try:
        if include_disabled:
            c.execute("SELECT id, name, host, port, enable, ss_password FROM nodes ORDER BY id")
        else:
            c.execute("SELECT id, name, host, port, enable, ss_password FROM nodes WHERE enable=1 ORDER BY id")
        nodes = c.fetchall()
        conn.close()
    except:
        if include_disabled:
            c.execute("SELECT id, name, host, port, enable FROM nodes ORDER BY id")
        else:
            c.execute("SELECT id, name, host, port, enable FROM nodes WHERE enable=1 ORDER BY id")
        nodes = c.fetchall()
        conn.close()
        return [{'id': n[0], 'name': n[1], 'host': n[2], 'port': n[3], 'enable': n[4], 'ss_password': ''} for n in nodes]
    return [{'id': n[0], 'name': n[1], 'host': n[2], 'port': n[3], 'enable': n[4], 'ss_password': n[5] if n[5] else ''} for n in nodes]

def delete_node(node_id):
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("DELETE FROM nodes WHERE id=?", (node_id,))
    conn.commit()
    affected = c.rowcount
    conn.close()
    if affected > 0:
        reload_singbox_config()
    return affected > 0

def verify_admin(username, password):
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("SELECT * FROM admins WHERE username=?", (username,))
    admin = c.fetchone()
    conn.close()
    if admin:
        if hashlib.sha256(password.encode('utf-8')).hexdigest() == admin[2]:
            return True
    return False

def verify_user(username, password):
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("SELECT * FROM users WHERE username=?", (username,))
    user = c.fetchone()
    conn.close()
    if user and user[4] == 1:
        if password == user[2]:
            return {'id': user[0], 'username': user[1], 'uuid': user[3], 'auth_id': user[10]}
    return None

def update_user_password_by_user(username, old_password, new_password):
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("SELECT * FROM users WHERE username=?", (username,))
    user = c.fetchone()
    if not user or user[2] != old_password:
        conn.close()
        return False, '旧密码错误'
    c.execute("UPDATE users SET password=? WHERE username=?", (new_password, username))
    conn.commit()
    conn.close()
    reload_singbox_config()
    return True, '修改成功'

def update_admin_password(username, new_password):
    conn = get_db_conn()
    c = conn.cursor()
    hashed = hashlib.sha256(new_password.encode('utf-8')).hexdigest()
    c.execute("UPDATE admins SET password=? WHERE username=?", (hashed, username))
    conn.commit()
    affected = c.rowcount
    conn.close()
    return affected > 0

def update_user_password(user_id, new_password=None):
    if new_password is None:
        new_password = generate_password()
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("UPDATE users SET password=? WHERE id=?", (new_password, user_id))
    conn.commit()
    conn.close()
    reload_singbox_config()
    return new_password

def get_ss_psk():
    try:
        with open(CONFIG_PATH, 'r') as f:
            config = json.load(f)
        for inbound in config.get('inbounds', []):
            if inbound.get('tag') == 'ss-in':
                return inbound.get('password', '')
    except: pass
    return ''

def generate_links(user_id, user_uuid, password, nodes):
    links = []
    ss_psk = get_ss_psk()
    for node in nodes:
        host = node['host']
        name = quote(node['name'], safe='')
        method = "2022-blake3-aes-256-gcm"
        ss_key = ss_psk or node.get('ss_password') or password
        ss_data = method + ":" + ss_key
        ss = "ss://" + base64.b64encode(ss_data.encode('utf-8')).decode() + "@" + host + ":9000#" + name
        vmess = {"v": "2", "ps": node['name'], "add": host, "port": "9001", "id": user_uuid, "aid": "0", "net": "tcp", "type": "none"}
        vmess_link = "vmess://" + base64.b64encode(json.dumps(vmess).encode('utf-8')).decode()
        trojan = "trojan://" + password + "@" + host + ":9002#" + name
        vless = "vless://" + user_uuid + "@" + host + ":9003?encryption=none&flow=xtls-rprx-vision&type=tcp#" + name
        links.append({'node': node['name'], 'host': host, 'port': node['port'], 'ss': ss, 'vmess': vmess_link, 'trojan': trojan, 'vless': vless})
    return links

class APIHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print("[" + datetime.now().strftime('%H:%M:%S') + "] " + str(args[0]))

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
        if path == '/api/stats':
            try:
                import subprocess as _sub
                r = _sub.run(['pgrep', '-f', 'sing-box'], stdout=_sub.PIPE, stderr=_sub.PIPE, timeout=5)
                online_nodes = 1 if r.stdout.strip() else 0
            except:
                online_nodes = 0
            conn = get_db_conn(); c = conn.cursor()
            c.execute("SELECT COUNT(*) FROM users"); total_users = c.fetchone()[0]
            conn.close()
            self.send_json({'online_nodes': online_nodes, 'total_users': total_users}); return
        if path == '/api/user/info':
            auth_header = self.headers.get('Authorization', '')
            if auth_header.startswith('Basic '):
                try:
                    decoded = base64.b64decode(auth_header[6:]).decode('utf-8')
                    username, password = decoded.split(':', 1)
                    user = verify_user(username, password)
                    if user:
                        full_user = get_user(user['id'])
                        nodes = get_nodes()
                        full_user['configs'] = generate_links(full_user['id'], full_user['uuid'], full_user['password'], nodes)
                        full_user['subscription_url'] = "/subscribe/" + full_user['auth_id']
                        del full_user['password']
                        self.send_json({'success': True, 'user': full_user})
                    else:
                        self.send_json({'success': False, 'error': 'Invalid credentials'}, 401)
                except:
                    self.send_json({'success': False, 'error': 'Invalid auth format'}, 401)
            else:
                self.send_json({'success': False, 'error': 'No auth header'}, 401)
            return
        if path.startswith('/subscribe/'):
            auth_id = path.split('/')[-1]
            user = get_user_by_auth(auth_id)
            if not user or not user['enable']:
                self.send_error(404); return
            if user['expire_time']:
                try:
                    if dt_parse(user['expire_time']) < datetime.now():
                        self.send_error(403); return
                except: pass
            nodes = get_nodes()
            configs = generate_links(user['id'], user['uuid'], user['password'], nodes)
            content = "".join("#" + cfg['node'] + "\n" + cfg['ss'] + "\n" + cfg['vmess'] + "\n" + cfg['trojan'] + "\n" + cfg['vless'] + "\n\n" for cfg in configs)
            encoded = base64.b64encode(content.encode('utf-8')).decode('ascii')
            self.send_text(encoded); return
        if path == '/api/users': self.send_json({'users': list_users()}); return
        if path == '/api/nodes': self.send_json({'nodes': get_nodes()}); return
        if path.startswith('/api/user/') and path != '/api/user/create':
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
        if path == '/api/login':
            auth_header = self.headers.get('Authorization', '')
            if auth_header.startswith('Basic '):
                try:
                    decoded = base64.b64decode(auth_header[6:]).decode('utf-8')
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
        if path == '/api/all-links':
            nodes = get_nodes(); users = list_users(); result = []
            for user in users:
                u = get_user(user['id'])
                if u:
                    result.append({'user': user['username'], 'user_id': user['id'],
                                 'links': generate_links(u['id'], u['uuid'], u['password'], nodes)})
            self.send_json({'data': result}); return
        WEB_DIR = '/opt/wwwOK/web'
        if path == '/': path = '/user.html'
        safe_path = path.lstrip('/')
        file_path = os.path.join(WEB_DIR, safe_path)
        if os.path.isfile(file_path):
            self.send_response(200)
            if safe_path.endswith('.html'): self.send_header('Content-Type', 'text/html')
            elif safe_path.endswith('.js'): self.send_header('Content-Type', 'application/javascript')
            elif safe_path.endswith('.css'): self.send_header('Content-Type', 'text/css')
            self.end_headers()
            with open(file_path, 'rb') as f: self.wfile.write(f.read())
            return
        self.send_json({'error': 'not found'}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length else '{}'
        try: data = json.loads(body)
        except: data = {}

        if path == '/api/login':
            auth_header = self.headers.get('Authorization', '')
            if auth_header.startswith('Basic '):
                try:
                    decoded = base64.b64decode(auth_header[6:]).decode('utf-8')
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

        if path == '/api/user/create':
            try:
                result = create_user(data.get('username', ''), int(data.get('expire_days', 365)), int(data.get('flow_limit_gb', 1000)))
                nodes = get_nodes()
                result['configs'] = generate_links(result['id'], result['uuid'], result['password'], nodes) if nodes else []
                self.send_json({'success': True, 'user': result})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return

        if path.startswith('/api/user/delete/'):
            try: delete_user(int(path.split('/')[-1])); self.send_json({'success': True})
            except: self.send_json({'success': False}, 400)
            return

        if path == '/api/node/add':
            try:
                node_id = add_node(data.get('name', ''), data.get('host', ''), int(data.get('port', 8080)), data.get('ss_password'))
                self.send_json({'success': True, 'node_id': node_id})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return

        if path.startswith('/api/node/delete/'):
            try:
                node_id = int(path.split('/')[-1])
                if delete_node(node_id): self.send_json({'success': True})
                else: self.send_json({'success': False, 'error': 'Node not found'}, 404)
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return

        if path == '/api/admin/password':
            new_password = data.get('new_password', '')
            if len(new_password) < 6: self.send_json({'success': False, 'error': 'Password too short'}, 400); return
            if update_admin_password('admin', new_password): self.send_json({'success': True})
            else: self.send_json({'success': False, 'error': 'Update failed'}, 400)
            return

        if path == '/api/user/password':
            auth_header = self.headers.get('Authorization', '')
            if not auth_header.startswith('Basic '): self.send_json({'success': False, 'error': 'No auth'}, 401); return
            try:
                decoded = base64.b64decode(auth_header[6:]).decode('utf-8')
                username, old_password = decoded.split(':', 1)
                new_password = data.get('new_password', '')
                if len(new_password) < 6: self.send_json({'success': False, 'error': 'Password too short'}, 400); return
                ok, msg = update_user_password_by_user(username, old_password, new_password)
                self.send_json({'success': ok, 'error': msg if not ok else None})
            except: self.send_json({'success': False, 'error': 'Invalid request'}, 400)
            return

        if path == '/api/admin/reset-user-password':
            auth_header = self.headers.get('Authorization', '')
            if not auth_header.startswith('Basic '): self.send_json({'success': False, 'error': 'No auth'}, 401); return
            try:
                decoded = base64.b64decode(auth_header[6:]).decode('utf-8')
                admin_user, admin_pass = decoded.split(':', 1)
                if not verify_admin(admin_user, admin_pass): self.send_json({'success': False, 'error': 'Admin auth failed'}, 401); return
                user_id = int(data.get('user_id', 0))
                new_password = data.get('new_password', '') or generate_password()
                result = update_user_password(user_id, new_password)
                if result: self.send_json({'success': True, 'new_password': result})
                else: self.send_json({'success': False, 'error': 'User not found'}, 404)
            except Exception as e: self.send_json({'success': False, 'error': str(e)}, 400)
            return

        self.send_json({'error': 'not found'}, 404)

def run_server():
    init_db()
    server = HTTPServer(('0.0.0.0', PORT), APIHandler)
    print("wwwOK API running on port " + str(PORT))
    server.serve_forever()

if __name__ == "__main__":
    run_server()
PYEOF

    chmod +x ${SCRIPTS_DIR}/gen_singbox_config.py
    chmod +x ${SCRIPTS_DIR}/wwwOK_api.py
    echo -e "  ${GREEN}Python 脚本已安装${NC}"
}

install_web() {
    echo -e "\n${CYAN}>>> 安装 Web 前端...${NC}"

    cat > "$WEB_DIR/admin.html" << 'HTMLEOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>wwwOK 管理面板</title>
<style>
body{font-family:Arial,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;background:#f5f5f5}
h1{color:#333;border-bottom:2px solid #4CAF50;padding-bottom:10px}
.info-grid{display:grid;grid-template-columns:140px 1fr;gap:8px;margin:20px 0;background:#fff;padding:20px;border-radius:8px;box-shadow:0 2px 8px rgba(0,0,0,0.1)}
.label{font-weight:bold;color:#555}
.value{color:#222;font-family:monospace;word-break:break-all}
.btn{background:#4CAF50;color:#fff;padding:8px 16px;border:none;border-radius:4px;cursor:pointer;font-size:14px}
.btn:hover{background:#45a049}.btn-danger{background:#f44336}.btn-danger:hover{background:#da190b}
input,select{padding:8px 12px;border:1px solid #ddd;border-radius:4px;font-size:14px}
.status-ok{color:#4CAF50;font-weight:bold}.status-fail{color:#f44336;font-weight:bold}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.1)}
th,td{padding:10px 14px;text-align:left;border-bottom:1px solid #eee}
th{background:#4CAF50;color:#fff}tr:hover{background:#f9f9f9}
.card{background:#fff;padding:20px;border-radius:8px;margin:15px 0;box-shadow:0 2px 8px rgba(0,0,0,0.1)}
</style></head>
<body>
<h1>wwwOK 管理面板</h1>
<div class="card">
<div class="info-grid">
<div class="label">管理面板</div><div class="value"><a href="/admin.html">/admin.html</a></div>
<div class="label">API 端口</div><div class="value">8888</div>
<div class="label">代理端口</div><div class="value">SS=9000 | VMess=9001 | Trojan=9002 | VLESS=9003</div>
<div class="label">管理员</div><div class="value">admin</div>
<div class="label">默认密码</div><div class="value">vip@8888999 <span style="color:red">(建议修改)</span></div>
</div></div>
<h2>服务状态</h2>
<div class="card"><div id="services" style="font-size:14px">加载中...</div></div>
<h2>用户管理 <button class="btn" onclick="showCreate()" style="margin-left:15px">+ 新建用户</button></h2>
<div id="create-form" style="display:none" class="card">
<h3>新建用户</h3>
<label>用户名</label><input type="text" id="new-user" placeholder="username" style="width:200px">
<label>有效期(天)</label><input type="number" id="expire-days" value="365" style="width:100px">
<label>流量(GB)</label><input type="number" id="flow-limit" value="1000" style="width:100px">
<br><br>
<button class="btn" onclick="doCreate()">确认创建</button>
<button class="btn btn-danger" onclick="hideCreate()">取消</button>
</div>
<div class="card"><div id="users">加载中...</div></div>
<script>
const AUTH='Basic YWRtaW46dmlwQDg4ODg5OTk=';
async function api(path,method='GET',body=null){
  let r=await fetch(path,{method,headers:{'Authorization':AUTH,'Content-Type':'application/json'},body:body?JSON.stringify(body):null});
  return r.json();
}
async function loadInfo(){
  let r=await api('/api/nodes');
  let node=r.nodes&&r.nodes[0];
  let host=node?node.host+':'+node.port:'未配置节点';
  let sb=await api('/api/stats');
  let sbRun=sb.online_nodes?'<span class=status-ok>● 运行中</span>':'<span class=status-fail>○ 已停止</span>';
  document.getElementById('services').innerHTML='<div>sing-box 代理: '+sbRun+' | 用户总数: '+(sb.total_users||0)+'</div>';
}
async function loadUsers(){
  let r=await api('/api/users');
  if(!r.users||!r.users.length){document.getElementById('users').innerHTML='<p style="color:#888">暂无用户</p>';return;}
  let html='<table><tr><th>ID</th><th>用户名</th><th>状态</th><th>流量限制</th><th>到期时间</th><th>操作</th></tr>';
  for(let u of r.users){
    let flow=(u.flow_limit/1024/1024/1024).toFixed(1)+' GB';
    let expire=u.expire_time?u.expire_time.slice(0,10):'永久';
    let enbl=u.enable?'<span class=status-ok>启用</span>':'<span class=status-fail>禁用</span>';
    html+='<tr><td>'+u.id+'</td><td>'+u.username+'</td><td>'+enbl+'</td><td>'+flow+'</td><td>'+expire+'</td><td>'+
          '<button class="btn btn-danger" style="padding:4px 10px;font-size:12px" onclick="delUser('+u.id+')">删除</button></td></tr>';
  }
  document.getElementById('users').innerHTML=html;
}
async function delUser(id){
  if(!confirm('确认删除用户 ID '+id+'?'))return;
  await api('/api/user/delete/'+id,'POST');
  loadUsers();loadInfo();
}
function showCreate(){document.getElementById('create-form').style.display='block';}
function hideCreate(){document.getElementById('create-form').style.display='none';}
async function doCreate(){
  let u=document.getElementById('new-user').value;
  let d=document.getElementById('expire-days').value;
  let f=document.getElementById('flow-limit').value;
  if(!u){alert('请输入用户名');return;}
  let r=await api('/api/user/create','POST',{username:u,expire_days:parseInt(d),flow_limit_gb:parseInt(f)});
  if(r.success){
    alert('创建成功!\n用户名: '+r.user.username+'\n密码: '+r.user.password+'\n订阅: /subscribe/'+r.user.auth_id);
    hideCreate();loadUsers();loadInfo();
  }else{alert('错误: '+r.error);}
}
loadInfo();loadUsers();
</script></body></html>
HTMLEOF

    cat > "$WEB_DIR/user.html" << 'HTMLEOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>我的节点 - wwwOK</title>
<style>
body{font-family:Arial,sans-serif;max-width:700px;margin:40px auto;padding:0 20px;background:#f5f5f5}
h1{color:#333}
.box{background:#fff;padding:20px;border-radius:8px;margin:15px 0;box-shadow:0 2px 8px rgba(0,0,0,0.1)}
input{width:100%;padding:10px;border:1px solid #ddd;border-radius:4px;font-size:13px;box-sizing:border-box}
button{background:#4CAF50;color:#fff;padding:10px 20px;border:none;border-radius:4px;cursor:pointer}
button:hover{background:#45a049}
pre{background:#f0f0f0;padding:15px;border-radius:4px;overflow-x:auto;font-size:12px;max-height:400px;overflow-y:auto}
</style></head>
<body>
<h1>我的代理节点</h1>
<div class="box"><div id="info" style="color:#555">加载中...</div></div>
<div class="box">
<h2>订阅地址</h2>
<p>复制下方链接，粘贴到 V2RayN/Clash 等客户端的订阅管理中添加：</p>
<input type="text" id="sub-url" readonly onclick="this.select()">
<p style="font-size:12px;color:#888;margin-top:8px">提示：订阅地址终身不变，更新节点信息会自动同步</p>
</div>
<div class="box"><h2>直链预览</h2><pre id="links">加载中...</pre></div>
<script>
const AUTH='Basic YWRtaW46dmlwQDg4ODg5OTk=';
async function api(path){let r=await fetch(path,{headers:{'Authorization':AUTH}});return r.json();}
async function load(){
  let r=await api('/api/user/info');
  if(!r.success){document.getElementById('info').textContent='认证失败';return;}
  let u=r.user;
  document.getElementById('info').innerHTML='用户名: <b>'+u.username+'</b> | 到期: '+(u.expire_time?u.expire_time.slice(0,10):'永久');
  let loc=location.origin;
  document.getElementById('sub-url').value=loc+'/subscribe/'+u.auth_id;
  let links=u.configs&&u.configs.length?
    u.configs.map(c=>'节点: '+c.node+'\nSS: '+c.ss+'\nVMess: '+c.vmess+'\nTrojan: '+c.trojan+'\nVLESS: '+c.vless).join('\n\n'):
    '暂无可用节点，请联系管理员添加节点';
  document.getElementById('links').textContent=links;
}
load();
</script></body></html>
HTMLEOF

    echo -e "  ${GREEN}Web 前端已安装${NC}"
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
    echo -e "\n${CYAN}>>> 配置 wwwOK API 服务...${NC}"

    cat > /etc/systemd/system/wwwok-api.service << 'SVCEOF'
[Unit]
Description=wwwOK API service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/wwwOK/scripts/wwwOK_api.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
WorkingDirectory=/opt/wwwOK/scripts

[Install]
WantedBy=multi-user.target
SVCEOF

    $PYTHON_CMD ${SCRIPTS_DIR}/wwwOK_api.py &
    sleep 2
    kill %1 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable wwwok-api
    systemctl restart wwwok-api
    sleep 1

    if systemctl is-active --quiet wwwok-api; then
        echo -e "  ${GREEN}wwwOK API 服务启动成功${NC}"
    else
        echo -e "  ${RED}wwwOK API 启动失败，请检查 journalctl -u wwwok-api${NC}"
    fi
}

setup_firewall() {
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
    install_singbox_service
    install_api_service
    setup_firewall

    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    [ -z "$SERVER_IP" ] && SERVER_IP="<服务器IP>"

    print_divider
    echo -e "  ${GREEN}${BOLD}安装完成！${NC}"
    print_divider
    echo -e "  ${WHITE}管理面板: ${CYAN}http://${SERVER_IP}:${API_PORT}/admin.html${NC}"
    echo -e "  ${WHITE}用户订阅: ${CYAN}http://${SERVER_IP}:${API_PORT}/user.html${NC}"
    echo -e "  ${WHITE}代理端口:  ${CYAN}SS=${SS_PORT} | VMess=${VMESS_PORT} | Trojan=${TROJAN_PORT} | VLESS=${VLESS_PORT}${NC}"
    echo -e "  ${WHITE}管理员:    ${CYAN}admin${NC}"
    echo -e "  ${WHITE}管理密码:  ${CYAN}vip@8888999${NC}"
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
    HASH=$($PYTHON_CMD -c "import hashlib; print(hashlib.sha256('$newpass'.encode()).hexdigest())")
    $PYTHON_CMD - << PY
import sqlite3
try:
    conn = sqlite3.connect('/opt/wwwOK/db/users.db')
    c = conn.cursor()
    c.execute("UPDATE admins SET password=? WHERE username='admin'", ('$HASH',))
    conn.commit()
    print("密码已更新")
except Exception as e:
    print("错误: " + str(e))
PY
    print_status OK "管理密码已修改为: $newpass"
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
        clear
        show_menu
        read -p "  请输入选项 [0-5]: " choice
        clear
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
