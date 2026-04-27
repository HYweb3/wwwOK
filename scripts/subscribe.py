#!/usr/bin/env python3
"""
wwwOK - 订阅链接生成器
根据用户订阅ID生成完整的代理配置订阅内容
"""

import base64
import json
import sys
import os

# 添加项目路径
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

def generate_subscription(auth_id, base_url="http://localhost:8080"):
    """
    根据订阅ID生成订阅内容
    订阅内容包含所有协议的节点链接
    """
    # 这里需要连接数据库获取用户信息和节点列表
    # 简化版本：直接返回基础配置
    
    db_path = "/opt/wwwOK/db/users.db"
    
    if not os.path.exists(db_path):
        return None
    
    try:
        import sqlite3
        conn = sqlite3.connect(db_path)
        c = conn.cursor()
        
        # 获取用户信息
        c.execute("SELECT * FROM users WHERE auth_id=?", (auth_id,))
        user = c.fetchone()
        
        if not user:
            conn.close()
            return None
        
        # 获取所有启用的节点
        c.execute("SELECT id, name, host, port FROM nodes WHERE enable=1")
        nodes = c.fetchall()
        conn.close()
        
        if not nodes:
            return None
        
        # 生成订阅内容
        content = ""
        
        for node in nodes:
            node_id, node_name, host, port = node
            user_uuid = user[3]  # uuid
            password = user[2]   # password
            
            # 用户名
            uname = user[1]
            
            # 生成各协议链接
            name = f"{node_name}-{user[0]}"  # node-name-userid
            
            # Shadowsocks 2022
            method = "2022-blake3-aes-256-gcm"
            ss_data = f"{method}:{password}"
            ss_encoded = base64.b64encode(ss_data.encode()).decode()
            ss_link = f"ss://{ss_encoded}@{host}:{port}#{node_name}"
            
            # VMess
            vmess_config = {
                "v": "2",
                "ps": node_name,
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
            trojan_link = f"trojan://{password}@{host}:{port}#{node_name}"
            
            # VLESS
            vless_link = f"vless://{user_uuid}@{host}:{port}?encryption=none&flow=xtls-rprx-vision&type=tcp#{node_name}"
            
            # 添加到订阅内容
            content += f"#{node_name} (Shadowsocks)\n"
            content += f"{ss_link}\n\n"
            content += f"#{node_name} (VMess)\n"
            content += f"{vmess_link}\n\n"
            content += f"#{node_name} (Trojan)\n"
            content += f"{trojan_link}\n\n"
            content += f"#{node_name} (VLESS)\n"
            content += f"{vless_link}\n\n"
        
        return content
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return None


def generate_user_qr(auth_id, protocol='ss', base_url="http://localhost:8080"):
    """生成单个用户的二维码数据"""
    content = generate_subscription(auth_id, base_url)
    if not content:
        return None
    
    # 返回第一行链接用于生成二维码
    lines = [l for l in content.split('\n') if l.startswith(('ss://', 'vmess://', 'trojan://', 'vless://'))]
    if lines:
        return lines[0]
    return None


if __name__ == "__main__":
    if len(sys.argv) > 1:
        auth_id = sys.argv[1]
        content = generate_subscription(auth_id)
        if content:
            print(content)
        else:
            print("# No subscription found")
    else:
        print("Usage: subscribe.py <auth_id>")
