#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Dynamic generate sing-box multi-protocol config"""
import sqlite3, os, json, base64, subprocess, hashlib
from datetime import datetime

DB_PATH = "/opt/wwwOK/db/users.db"
CONFIG_PATH = "/opt/wwwOK/config/sing-box.json"

def get_db_conn():
    db_dir = os.path.dirname(DB_PATH)
    if db_dir and not os.path.exists(db_dir):
        try:
            os.makedirs(db_dir)
        except OSError:
            pass
    conn = sqlite3.connect(DB_PATH)
    conn.text_factory = str
    return conn

def init_db():
    """Initialize DB tables: users/admins/nodes"""
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, uuid TEXT UNIQUE NOT NULL, enable INTEGER DEFAULT 1, flow_limit INTEGER DEFAULT 107374182400, flow_used INTEGER DEFAULT 0, expire_time TEXT, created_time TEXT, last_login TEXT, auth_id TEXT)")
    c.execute("CREATE TABLE IF NOT EXISTS admins (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, created_time TEXT)")
    c.execute("CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, host TEXT NOT NULL, port INTEGER DEFAULT 8080, enable INTEGER DEFAULT 1, created_time TEXT)")
    try:
        c.execute("ALTER TABLE nodes ADD COLUMN ss_password TEXT DEFAULT ''")
        conn.commit()
    except:
        pass
    c.execute("SELECT * FROM admins WHERE username='admin'")
    if not c.fetchone():
        hashed = hashlib.sha256("vip@8888999".encode('utf-8')).hexdigest()
        c.execute("INSERT INTO admins (username, password, created_time) VALUES (?, ?, ?)", ("admin", hashed, datetime.now().isoformat()))
    conn.commit()
    conn.close()

def get_all_users():
    init_db()
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("SELECT id, username, password, uuid, enable, auth_id FROM users WHERE enable=1")
    users = c.fetchall()
    conn.close()
    result = []
    for u in users:
        result.append({'id': u[0], 'username': u[1], 'password': u[2], 'uuid': u[3], 'enable': u[4], 'auth_id': u[5]})
    return result

def get_all_nodes():
    conn = get_db_conn()
    c = conn.cursor()
    c.execute("SELECT id, name, host, port, enable FROM nodes WHERE enable=1")
    nodes = c.fetchall()
    conn.close()
    result = []
    for n in nodes:
        result.append({'id': n[0], 'name': n[1], 'host': n[2], 'port': n[3], 'enable': n[4]})
    return result

PSK_FILE = "/opt/wwwOK/db/ss_psk.txt"

def gen_ss2022_psk():
    return base64.b64encode(os.urandom(32)).decode()

def get_stable_psk():
    """Read stable PSK, create if not exists"""
    try:
        if os.path.exists(PSK_FILE):
            with open(PSK_FILE, 'r') as f:
                return f.read().strip()
    except:
        pass
    psk = gen_ss2022_psk()
    try:
        with open(PSK_FILE, 'w') as f:
            f.write(psk)
    except:
        pass
    return psk

def _run_cmd(cmd):
    """Run command, no timeout param for Python 2.7 compat"""
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        proc.wait()
        return proc.returncode == 0
    except:
        return False

def generate_config():
    users = get_all_users()
    nodes = get_all_nodes()
    ss_global_psk = get_stable_psk()

    # Build users arrays (Python 2.7 compatible, no f-string)
    vmess_users = []
    for u in users:
        vmess_users.append({"uuid": u["uuid"]})

    trojan_users = []
    for u in users:
        trojan_users.append({"password": u["password"]})

    vless_users = []
    for u in users:
        vless_users.append({"uuid": u["uuid"]})

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
            "users": vmess_users
        },
        {
            "tag": "trojan-in",
            "type": "trojan",
            "listen": "0.0.0.0",
            "listen_port": 9002,
            "users": trojan_users
        },
        {
            "tag": "vless-in",
            "type": "vless",
            "listen": "0.0.0.0",
            "listen_port": 9003,
            "users": vless_users
        }
    ]

    config = {
        "log": {"level": "info", "output": "/var/log/wwwOK/sing-box.log", "timestamp": True},
        "inbounds": inbounds,
        "outbounds": [{"tag": "direct", "type": "direct"}, {"tag": "block", "type": "block"}]
    }

    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=4)
    print("Generated: %d users, %d nodes" % (len(users), len(nodes)))

    # Try reload via systemctl
    for sig in ['HUP', 'TERM']:
        if _run_cmd(['systemctl', 'kill', '-s'+sig, 'sing-box']):
            print("sing-box reloaded via systemctl -%s" % sig)
            return

    # Fallback: killall
    if _run_cmd(['killall', '-HUP', 'sing-box']):
        print("sing-box reloaded via killall")
        return
    print("Warning: could not reload sing-box, restart manually if needed")

if __name__ == '__main__':
    generate_config()
