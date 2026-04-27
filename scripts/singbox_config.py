#!/usr/bin/env python3
"""
sing-box 配置文件生成器
支持生成 Shadowsocks、VMess、Trojan、VLESS 协议配置
"""

import json
import uuid
import hashlib
import base64
import secrets
import string
from datetime import datetime, timedelta

def generate_password(length=32):
    """生成随机密码"""
    chars = string.ascii_letters + string.digits
    return ''.join(secrets.choice(chars) for _ in range(length))

def generate_uuid():
    """生成 UUID"""
    return str(uuid.uuid4())

def ss_encrypt(pwd, method="2022-blake3-aes-256-gcm"):
    """Shadowsocks 2022 加密方式"""
    return method

def vmess_link(info, port=443):
    """生成 VMess 链接"""
    vmess = {
        "v": "2",
        "ps": info['name'],
        "add": info['host'],
        "port": str(port),
        "id": info['uuid'],
        "aid": "0",
        "net": "tcp",
        "type": "none",
        "host": "",
        "path": "",
        "tls": ""
    }
    json_str = json.dumps(vmess, ensure_ascii=False)
    return "vmess://" + base64.b64encode(json_str.encode()).decode()

def ss_link(info, port=443):
    """生成 Shadowsocks 链接"""
    password = info['password']
    method = info['method']
    # SS2022 格式
    return f"ss://{base64.b64encode(f'{method}:{password}'.encode()).decode()}@{info['host']}:{port}#{(info['name'])}"

def trojan_link(info, port=443):
    """生成 Trojan 链接"""
    password = info['password']
    return f"trojan://{password}@{info['host']}:{port}#{info['name']}"

def vless_link(info, port=443):
    """生成 VLESS 链接"""
    uuid = info['uuid']
    return f"vless://{uuid}@{info['host']}:{port}?encryption=none&flow=xtls-rprx-vision&type=tcp#{info['name']}"

def generate_singbox_config(users, port=8080, dns_port=53):
    """生成 sing-box 主配置文件"""
    
    # 入站规则
    inbounds = []
    
    # Shadowsocks 入站
    for user in users:
        if user.get('protocol') in ['ss', 'all']:
            inbounds.append({
                "tag": f"ss-{user['id']}",
                "type": "shadowsocks",
                "listen": "0.0.0.0",
                "port": user.get('ss_port', 10001 + users.index(user)),
                "method": user.get('ss_method', '2022-blake3-aes-256-gcm'),
                "password": user['password']
            })
    
    # VMess 入站
    for user in users:
        if user.get('protocol') in ['vmess', 'all']:
            inbounds.append({
                "tag": f"vmess-{user['id']}",
                "type": "vmess",
                "listen": "0.0.0.0",
                "port": user.get('vmess_port', 10010 + users.index(user)),
                "protocol_version": "VISION",
                "users": [{
                    "uuid": user['uuid'],
                    "alter_id": 0
                }],
                "tls": {
                    "enabled": True,
                    "server_name": user.get('domain', 'example.com')
                }
            })
    
    # Trojan 入站
    for user in users:
        if user.get('protocol') in ['trojan', 'all']:
            inbounds.append({
                "tag": f"trojan-{user['id']}",
                "type": "trojan",
                "listen": "0.0.0.0",
                "port": user.get('trojan_port', 10020 + users.index(user)),
                "password": [user['password']],
                "tls": {
                    "enabled": True,
                    "server_name": user.get('domain', 'example.com'),
                    "certificate_path": "/etc/sing-box/cert.pem",
                    "key_path": "/etc/sing-box/key.pem"
                }
            })
    
    # VLESS 入站
    for user in users:
        if user.get('protocol') in ['vless', 'all']:
            inbounds.append({
                "tag": f"vless-{user['id']}",
                "type": "vless",
                "listen": "0.0.0.0",
                "port": user.get('vless_port', 10030 + users.index(user)),
                "users": [{
                    "uuid": user['uuid'],
                    "flow": "xtls-rprx-vision"
                }],
                "tls": {
                    "enabled": True,
                    "server_name": user.get('domain', 'example.com'),
                    "certificate_path": "/etc/sing-box/cert.pem",
                    "key_path": "/etc/sing-box/key.pem"
                }
            })
    
    # HTTP 管理面板入站
    inbounds.append({
        "tag": "web",
        "type": "http",
        "listen": "0.0.0.0",
        "port": port
    })
    
    # DNS 入站
    inbounds.append({
        "tag": "dns",
        "type": "direct",
        "listen": "0.0.0.0",
        "port": dns_port
    })
    
    # 出站
    outbounds = [
        {
            "tag": "direct",
            "type": "direct",
            "domain_strategy": "prefer_ipv4"
        },
        {
            "tag": "block",
            "type": "block"
        },
        {
            "tag": "dns-out",
            "type": "dns"
        }
    ]
    
    # 路由规则
    routes = {
        "dns_strategy": "prefer_ipv4",
        "rules": [
            {
                "type": "default",
                "outbound": "dns-out",
                "port": [53]
            },
            {
                "type": "default",
                "outbound": "direct"
            }
        ]
    }
    
    config = {
        "log": {
            "level": "info",
            "timestamp": True
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": routes
    }
    
    return json.dumps(config, indent=2, ensure_ascii=False)

def generate_user_info(user_id, name, host, domain="example.com"):
    """生成单个用户的完整信息"""
    password = generate_password()
    user_uuid = generate_uuid()
    
    return {
        'id': user_id,
        'name': name,
        'host': host,
        'domain': domain,
        'password': password,
        'uuid': user_uuid,
        'ss_method': '2022-blake3-aes-256-gcm',
        'created_at': datetime.now().isoformat()
    }

if __name__ == "__main__":
    # 测试
    host = input("请输入服务器IP或域名: ") or "1.2.3.4"
    test_user = generate_user_info(1, "测试用户", host)
    
    print("\n=== 用户信息 ===")
    print(f"ID: {test_user['id']}")
    print(f"名称: {test_user['name']}")
    print(f"密码: {test_user['password']}")
    print(f"UUID: {test_user['uuid']}")
    print(f"\nShadowsocks: {ss_link(test_user)}")
    print(f"\nVMess: {vmess_link(test_user)}")
    print(f"\nTrojan: {trojan_link(test_user)}")
    print(f"\nVLESS: {vless_link(test_user)}")
