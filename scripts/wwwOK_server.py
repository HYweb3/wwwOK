#!/usr/bin/env python3
"""
wwwOK - 用户管理系统
SQLite 数据库 + API 服务
"""

import sqlite3
import uuid
import string
import secrets
import hashlib
import json
import time
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import ssl
import os

# 配置
DB_PATH = "/opt/wwwOK/db/users.db"
CONFIG_PATH = "/opt/wwwOK/config"
PORT = 8080

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
    
    # 创建默认管理员
    c.execute("SELECT * FROM admins WHERE username='admin'")
    if not c.fetchone():
        hashed = hashlib.sha256("admin123".encode()).hexdigest()
        c.execute("INSERT INTO admins (username, password, created_time) VALUES (?, ?, ?)",
                 ("admin", hashed, datetime.now().isoformat()))
    
    # 节点表
    c.execute('''CREATE TABLE IF NOT EXISTS nodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER DEFAULT 8080,
        enable INTEGER DEFAULT 1,
        created_time TEXT
    )''')
    
    conn.commit()
    conn.close()

def generate_password(length=32):
    """生成随机密码"""
    chars = string.ascii_letters + string.digits
    return ''.join(secrets.choice(chars) for _ in range(length))

def generate_uuid():
    """生成 UUID"""
    return str(uuid.uuid4())

def generate_auth_id():
    """生成订阅认证ID"""
    return secrets.token_urlsafe(16)

def create_user(username, expire_days=30, flow_limit_gb=100):
    """创建用户"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    
    try:
        password = generate_password()
        user_uuid = generate_uuid()
        auth_id = generate_auth_id()
        expire_time = (datetime.now() + timedelta(days=expire_days)).isoformat()
        flow_limit = flow_limit_gb * 1024 * 1024 * 1024
        
        c.execute('''INSERT INTO users 
            (username, password, uuid, expire_time, flow_limit, created_time, auth_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)''',
            (username, password, user_uuid, expire_time, flow_limit, datetime.now().isoformat(), auth_id))
        
        conn.commit()
        user_id = c.lastrowid
        
        # 生成节点配置
        nodes = get_nodes()
        configs = generate_all_links(user_id, user_uuid, password, nodes)
        
        return {
            'id': user_id,
            'username': username,
            'password': password,
            'uuid': user_uuid,
            'auth_id': auth_id,
            'expire_time': expire_time,
            'flow_limit_gb': flow_limit_gb,
            'configs': configs
        }
    finally:
        conn.close()

def get_user(user_id):
    """获取用户信息"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT * FROM users WHERE id=?", (user_id,))
    user = c.fetchone()
    conn.close()
    if user:
        return {
            'id': user[0], 'username': user[1], 'password': user[2], 'uuid': user[3],
            'enable': user[4], 'flow_limit': user[5], 'flow_used': user[6],
            'expire_time': user[7], 'created_time': user[8], 'last_login': user[9], 'auth_id': user[10]
        }
    return None

def get_user_by_auth(auth_id):
    """通过订阅ID获取用户"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT * FROM users WHERE auth_id=?", (auth_id,))
    user = c.fetchone()
    conn.close()
    if user:
        return {
            'id': user[0], 'username': user[1], 'password': user[2], 'uuid': user[3],
            'enable': user[4], 'flow_limit': user[5], 'flow_used': user[6],
            'expire_time': user[7], 'created_time': user[8], 'last_login': user[9], 'auth_id': user[10]
        }
    return None

def list_users():
    """列出所有用户"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT id, username, enable, flow_limit, flow_used, expire_time, created_time FROM users ORDER BY id")
    users = c.fetchall()
    conn.close()
    return [{'id': u[0], 'username': u[1], 'enable': u[2], 'flow_limit': u[3], 
             'flow_used': u[4], 'expire_time': u[5], 'created_time': u[6]} for u in users]

def update_user(user_id, **kwargs):
    """更新用户信息"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    for key, value in kwargs.items():
        if key in ['username', 'enable', 'flow_limit', 'expire_time']:
            c.execute(f"UPDATE users SET {key}=? WHERE id=?", (value, user_id))
    conn.commit()
    conn.close()

def delete_user(user_id):
    """删除用户"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("DELETE FROM users WHERE id=?", (user_id,))
    conn.commit()
    conn.close()

def add_node(name, host, port=8080):
    """添加节点"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("INSERT INTO nodes (name, host, port, created_time) VALUES (?, ?, ?, ?)",
             (name, host, port, datetime.now().isoformat()))
    conn.commit()
    node_id = c.lastrowid
    conn.close()
    return node_id

def get_nodes():
    """获取所有节点"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT id, name, host, port, enable FROM nodes WHERE enable=1")
    nodes = c.fetchall()
    conn.close()
    return [{'id': n[0], 'name': n[1], 'host': n[2], 'port': n[3], 'enable': n[4]} for n in nodes]

def generate_all_links(user_id, user_uuid, password, nodes):
    """为用户生成所有协议的链接"""
    import base64
    import urllib.parse
    
    links = []
    
    for node in nodes:
        host = node['host']
        port = node['port']
        name = f"{node['name']}-{user_id}"
        
        # Shadowsocks
        ss_method = "2022-blake3-aes-256-gcm"
        ss_data = f"{ss_method}:{password}"
        ss_encoded = base64.b64encode(ss_data.encode()).decode()
        ss_link = f"ss://{ss_encoded}@{host}:{port}#{urllib.parse.quote(name)}"
        
        # VMess
        vmess_config = {
            "v": "2",
            "ps": name,
            "add": host,
            "port": str(port),
            "id": user_uuid,
            "aid": "0",
            "net": "tcp",
            "type": "none"
        }
        vmess_encoded = base64.b64encode(json.dumps(vmess_config).encode()).decode()
        vmess_link = f"vmess://{vmess_encoded}"
        
        # Trojan
        trojan_link = f"trojan://{password}@{host}:{port}#{urllib.parse.quote(name)}"
        
        # VLESS
        vless_link = f"vless://{user_uuid}@{host}:{port}?encryption=none&flow=xtls-rprx-vision&type=tcp#{urllib.parse.quote(name)}"
        
        links.append({
            'node': node['name'],
            'host': host,
            'port': port,
            'ss': ss_link,
            'vmess': vmess_link,
            'trojan': trojan_link,
            'vless': vless_link
        })
    
    return links

class APIHandler(BaseHTTPRequestHandler):
    """API 请求处理"""
    
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
        
        # 健康检查
        if path == '/health':
            self.send_json({'status': 'ok', 'time': datetime.now().isoformat()})
            return
        
        # 订阅接口 /subscribe/{auth_id}
        if path.startswith('/subscribe/'):
            auth_id = path.split('/')[-1]
            user = get_user_by_auth(auth_id)
            if not user:
                self.send_json({'error': 'User not found'}, 404)
                return
            
            if not user['enable']:
                self.send_json({'error': 'User disabled'}, 403)
                return
            
            if user['expire_time'] and datetime.fromisoformat(user['expire_time']) < datetime.now():
                self.send_json({'error': 'User expired'}, 403)
                return
            
            # 生成订阅内容
            nodes = get_nodes()
            configs = generate_all_links(user['id'], user['uuid'], user['password'], nodes)
            
            # 拼接订阅内容
            content = ""
            for cfg in configs:
                content += f"#{cfg['node']}\n"
                content += f"ss://{cfg['ss'].split('ss://')[1]}\n"
                content += f"{cfg['vmess']}\n"
                content += f"{cfg['trojan']}\n"
                content += f"{cfg['vless']}\n\n"
            
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Subscription-Userinfo', f"upload=0; download={user['flow_used']}; total={user['flow_limit']}; expire={int(time.mktime(time.strptime(user['expire_time'], '%Y-%m-%dT%H:%M:%S.%f')))}")
            self.end_headers()
            self.wfile.write(content.encode())
            return
        
        # API: 获取所有用户
        if path == '/api/users':
            users = list_users()
            self.send_json({'users': users})
            return
        
        # API: 获取单个用户
        if path.startswith('/api/user/'):
            user_id = int(path.split('/')[-1])
            user = get_user(user_id)
            if user:
                nodes = get_nodes()
                user['configs'] = generate_all_links(user['id'], user['uuid'], user['password'], nodes)
                self.send_json(user)
            else:
                self.send_json({'error': 'User not found'}, 404)
            return
        
        # API: 获取节点列表
        if path == '/api/nodes':
            self.send_json({'nodes': get_nodes()})
            return
        
        # 静态文件
        if path == '/' or path == '/index.html':
            self.path = '/opt/wwwOK/web/index.html'
        
        # 管理员登录页面
        if path == '/admin/login.html':
            self.path = '/opt/wwwOK/web/admin/login.html'
        
    def do_POST(self):
        path = urlparse(self.path).path
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode() if content_length else '{}'
        
        try:
            data = json.loads(body) if body else {}
        except:
            data = {}
        
        # 创建用户
        if path == '/api/user/create':
            try:
                username = data.get('username')
                expire_days = int(data.get('expire_days', 30))
                flow_limit_gb = int(data.get('flow_limit_gb', 100))
                
                result = create_user(username, expire_days, flow_limit_gb)
                self.send_json({'success': True, 'user': result})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return
        
        # 更新用户
        if path.startswith('/api/user/update/'):
            user_id = int(path.split('/')[-1])
            try:
                update_user(user_id, **data)
                self.send_json({'success': True})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return
        
        # 删除用户
        if path.startswith('/api/user/delete/'):
            user_id = int(path.split('/')[-1])
            delete_user(user_id)
            self.send_json({'success': True})
            return
        
        # 添加节点
        if path == '/api/node/add':
            try:
                node_id = add_node(data.get('name'), data.get('host'), int(data.get('port', 8080)))
                self.send_json({'success': True, 'node_id': node_id})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return
        
        # 管理员登录
        if path == '/api/admin/login':
            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()
            c.execute("SELECT * FROM admins WHERE username=?", (data.get('username'),))
            admin = c.fetchone()
            conn.close()
            
            if admin and admin[2] == hashlib.sha256(data.get('password', '').encode()).hexdigest():
                self.send_json({'success': True, 'token': 'admin_token_' + admin[1]})
            else:
                self.send_json({'success': False, 'error': 'Invalid credentials'}, 401)
            return
        
        self.send_json({'error': 'Not found'}, 404)
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

def run_server():
    """启动 API 服务器"""
    init_db()
    
    server = HTTPServer(('0.0.0.0', PORT), APIHandler)
    print(f"API Server running on port {PORT}")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
