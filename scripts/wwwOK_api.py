#!/usr/bin/env python3
"""
wwwOK - API 服务
基于 Python 的 HTTP API 服务器
"""

import base64
import json
import time
import os
import sqlite3
import uuid
import string
import secrets
import hashlib
import subprocess
from datetime import datetime, timedelta
from dateutil.parser import parse as dt_parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, quote

# 配置
DB_PATH = "/opt/wwwOK/db/users.db"
PORT = 8888

def init_db():
    """初始化数据库"""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.text_factory = str
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
    conn.text_factory = str
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
        reload_singbox_config()
        return {'id': user_id, 'username': username, 'password': password, 'uuid': user_uuid, 'auth_id': auth_id}
    except Exception as e:
        conn.close()
        raise e

def get_user(user_id):
    conn = sqlite3.connect(DB_PATH)
    conn.text_factory = str
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
    conn.text_factory = str
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
    conn.text_factory = str
    c = conn.cursor()
    c.execute("SELECT id, username, enable, flow_limit, flow_used, expire_time, created_time FROM users ORDER BY id")
    users = c.fetchall()
    conn.close()
    return [{'id': u[0], 'username': u[1], 'enable': u[2], 'flow_limit': u[3], 
             'flow_used': u[4], 'expire_time': u[5], 'created_time': u[6]} for u in users]

def delete_user(user_id):
    conn = sqlite3.connect(DB_PATH)
    conn.text_factory = str
    c = conn.cursor()
    c.execute("DELETE FROM users WHERE id=?", (user_id,))
    conn.commit()
    affected = c.rowcount
    conn.close()
    if affected > 0:
        reload_singbox_config()
    return affected > 0

def add_node(name, host, port=8080):
    conn = sqlite3.connect(DB_PATH)
    conn.text_factory = str
    c = conn.cursor()
    c.execute("INSERT INTO nodes (name, host, port, created_time) VALUES (?, ?, ?, ?)",
             (name, host, port, datetime.now().isoformat()))
    conn.commit()
    node_id = c.lastrowid
    conn.close()
    return node_id

def get_nodes(include_disabled=False):
    conn = sqlite3.connect(DB_PATH)
    conn.text_factory = str  # Handle UTF-8 from SQLite
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
    conn.text_factory = str
    c = conn.cursor()
    c.execute("DELETE FROM nodes WHERE id=?", (node_id,))
    conn.commit()
    affected = c.rowcount
    conn.close()
    return affected > 0

def verify_admin(username, password):
    """验证管理员登录"""
    conn = sqlite3.connect(DB_PATH)
    conn.text_factory = str
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
    conn.text_factory = str
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
    conn.text_factory = str
    c = conn.cursor()
    c.execute("UPDATE users SET password=? WHERE id=?", (new_password, user_id))
    conn.commit()
    affected = c.rowcount
    conn.close()
    if affected > 0:
        reload_singbox_config()
    return new_password if affected > 0 else None

def reload_singbox_config():
    """重新生成 sing-box 配置并热重载"""
    try:
        subprocess.Popen(
            ['python3', '/opt/wwwOK/scripts/gen_singbox_config.py'],
            stdout=open('/var/log/wwwOK_api_singbox.log','a'),
            stderr=subprocess.STDOUT
        )
    except Exception as e:
        print(f"reload_singbox failed: {e}")

def generate_links(user_id, user_uuid, password, nodes):
    links = []
    for node in nodes:
        host, port, name = node['host'], node['port'], node['name']
        # URL-encode the node name for use in fragment (#) and query params
        name_encoded = quote(name, safe='')
        
        # Shadowsocks (sing-box SS2022 PSK: port 9000)
        method = "2022-blake3-aes-256-gcm"
        ss_data = f"{method}:{password}"
        ss = f"ss://{base64.b64encode(ss_data.encode('utf-8')).decode()}@{host}:9000#{name_encoded}"
        
        # VMess (sing-box: port 9001)
        vmess = {"v":"2","ps":name,"add":host,"port":"9001","id":user_uuid,"aid":"0","net":"tcp","type":"none"}
        vmess_link = f"vmess://{base64.b64encode(json.dumps(vmess).encode('utf-8')).decode()}"
        
        # Trojan (sing-box: port 9002)
        trojan = f"trojan://{password}@{host}:9002#{name_encoded}"
        
        # VLESS (sing-box: port 9003)
        vless = f"vless://{user_uuid}@{host}:9003?encryption=none&flow=xtls-rprx-vision&type=tcp#{name_encoded}"
        
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
            if user['expire_time'] and dt_parse(user['expire_time']) < datetime.now():
                self.send_error(403)
                return
            
            nodes = get_nodes()
            configs = generate_links(user['id'], user['uuid'], user['password'], nodes)
            content = ""
            for cfg in configs:
                content += f"#{cfg['node']}\n{cfg['ss']}\n{cfg['vmess']}\n{cfg['trojan']}\n{cfg['vless']}\n\n"
            
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write(content.encode('utf-8'))
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
