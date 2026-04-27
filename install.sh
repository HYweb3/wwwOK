
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

PSK_FILE = "/opt/wwwOK/db/ss_psk.txt"

def gen_ss2022_psk():
    return base64.b64encode(os.urandom(32)).decode()

def get_stable_psk():
    """读取稳定的 PSK，不存在则创建"""
    try:
        if os.path.exists(PSK_FILE):
            with open(PSK_FILE, 'r') as f:
                return f.read().strip()
    except: pass
    # 不存在则创建
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
            subprocess.run(['systemctl', 'kill', f'-s{sig}', 'sing-box'],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            print(f"sing-box reloaded via systemctl -s{sig}")
            return
        except:
            pass
    try:
        subprocess.run(['killall', '-HUP', 'sing-box'],
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        print("sing-box reloaded via killall")
    except:
        print("Warning: could not reload sing-box, restart manually if needed")

if __name__ == '__main__':
    generate_config()

PYEOF
    cat > ${WORK_DIR}/scripts/wwwOK_api.py << 'PYEOF'
#!/usr/bin/env python3
"""wwwOK API 服务 (Python 3.6兼容+修复版)
基于 GitHub HYweb3/wwwOK main 分支，修复以下问题：
1. /api/login POST 支持（前端表单提交）
2. reload_singbox_config 信号重载（不用 systemctl restart）
3. 移除重复的 /api/user/delete/ 路由
4. 适配服务器现有 DB（nodes 表无 ss_password 字段）
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
    # 确保 nodes 表有 ss_password 字段（部分安装版本没有）
    try:
        c.execute("ALTER TABLE nodes ADD COLUMN ss_password TEXT DEFAULT ''")
        conn.commit()
    except:
        pass  # 字段已存在
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
    """通过信号重载 sing-box 配置，比 systemctl restart 更稳定"""
    try:
        r = subprocess.run(['python3', f'{SCRIPTS_DIR}/gen_singbox_config.py'],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        print(f"gen_config: {r.stdout.strip()}")
    except Exception as e:
        print(f"gen_config failed: {e}")
    # 先尝试 systemctl kill 信号重载
    for sig in ['HUP', 'TERM']:
        try:
            subprocess.run(['systemctl', 'kill', f'-s{sig}', 'sing-box'],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            print(f"sent {sig} to sing-box")
            return
        except: pass
    # 备用：killall
    try:
        subprocess.run(['killall', '-HUP', 'sing-box'],
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        print("sent HUP via killall")
    except: pass

def create_user(username, expire_days=365, flow_limit_gb=1000):
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

def add_node(name, host, port=8080, ss_password=None):
    conn = get_db_conn(); c = conn.cursor()
    # 检查 ss_password 字段是否存在
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
    conn.commit(); node_id = c.lastrowid; conn.close()
    reload_singbox_config()
    return node_id

def get_nodes(include_disabled=False):
    conn = get_db_conn(); c = conn.cursor()
    has_ss_password = True
    try:
        if include_disabled:
            c.execute("SELECT id, name, host, port, enable, ss_password FROM nodes ORDER BY id")
        else:
            c.execute("SELECT id, name, host, port, enable, ss_password FROM nodes WHERE enable=1 ORDER BY id")
        nodes = c.fetchall(); conn.close()
    except:
        # ss_password 字段不存在，回退到旧查询
        if include_disabled:
            c.execute("SELECT id, name, host, port, enable FROM nodes ORDER BY id")
        else:
            c.execute("SELECT id, name, host, port, enable FROM nodes WHERE enable=1 ORDER BY id")
        nodes = c.fetchall(); conn.close()
        return [{'id': n[0], 'name': n[1], 'host': n[2], 'port': n[3], 'enable': n[4], 'ss_password': ''} for n in nodes]
    return [{'id': n[0], 'name': n[1], 'host': n[2], 'port': n[3], 'enable': n[4], 'ss_password': n[5] if n[5] else ''} for n in nodes]

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

def verify_user(username, password):
    conn = get_db_conn(); c = conn.cursor()
    c.execute("SELECT * FROM users WHERE username=?", (username,)); user = c.fetchone(); conn.close()
    if user and user[4] == 1:  # enable=1
        if password == user[2]: return {'id': user[0], 'username': user[1], 'uuid': user[3], 'auth_id': user[10]}
    return None

def update_user_password_by_user(username, old_password, new_password):
    conn = get_db_conn(); c = conn.cursor()
    c.execute("SELECT * FROM users WHERE username=?", (username,)); user = c.fetchone()
    if not user or user[2] != old_password:
        conn.close(); return False, '旧密码错误'
    c.execute("UPDATE users SET password=? WHERE username=?", (new_password, username))
    conn.commit(); conn.close()
    reload_singbox_config()
    return True, '修改成功'

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

def get_ss_psk():
    """从 sing-box.json 读取当前 SS PSK"""
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
        host, name = node['host'], quote(node['name'], safe='')
        method = "2022-blake3-aes-256-gcm"
        # SS 用 sing-box 实际 PSK（2022 需要全局 PSK，不是用户密码）
        ss_key = ss_psk or node.get('ss_password') or password
        ss_data = f"{method}:{ss_key}"
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
        if path == '/api/stats':
            import subprocess
            try:
                r = subprocess.run(['pgrep', '-f', 'sing-box'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
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
                        full_user['subscription_url'] = f"/subscribe/{full_user['auth_id']}"
                        del full_user['password']
                        self.send_json({'success': True, 'user': full_user})
                    else:
                        self.send_json({'success': False, 'error': 'Invalid credentials'}, 401)
                except: self.send_json({'success': False, 'error': 'Invalid auth format'}, 401)
            else: self.send_json({'success': False, 'error': 'No auth header'}, 401)
            return
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

        # ===== 修复1：POST /api/login（支持前端表单提交） =====
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

        if path == '/api/user/create':
            try:
                result = create_user(data.get('username', ''), int(data.get('expire_days', 365)), int(data.get('flow_limit_gb', 1000)))
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
            try:
                node_id = add_node(data.get('name', ''), data.get('host', ''), int(data.get('port', 8080)),
                                  data.get('ss_password'))
                self.send_json({'success': True, 'node_id': node_id})
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

        # ===== 修复2：移除重复路由，改为 /api/admin/reset-user-password =====
        if path == '/api/admin/reset-user-password':
            auth_header = self.headers.get('Authorization', '')
            if not auth_header.startswith('Basic '): self.send_json({'success': False, 'error': 'No auth'}, 401); return
            try:
                decoded = base64.b64decode(auth_header[6:]).decode('utf-8')
                admin_user, admin_pass = decoded.split(':', 1)
                if not verify_admin(admin_user, admin_pass):
                    self.send_json({'success': False, 'error': 'Admin auth failed'}, 401); return
                user_id = int(data.get('user_id', 0))
                new_password = data.get('new_password', '')
                if not new_password: new_password = generate_password()
                result = update_user_password(user_id, new_password)
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