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
            "users": [{"uuid": u["uuid"]} for u in users]
        },
        {
            "tag": "trojan-in",
            "type": "trojan",
            "listen": "0.0.0.0",
            "listen_port": 9002,
            "users": [{"password": u["password"]} for u in users]
        },
        {
            "tag": "vless-in",
            "type": "vless",
            "listen": "0.0.0.0",
            "listen_port": 9003,
            "users": [{"uuid": u["uuid"]} for u in users]
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
            subprocess.run(['systemctl', 'kill', '-s'+sig, 'sing-box'],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            print(f"sing-box reloaded via systemctl -{sig}")
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
