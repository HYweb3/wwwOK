#!/usr/bin/env python3
import sys
sys.path.insert(0, '/opt/wwwOK/scripts')
from wwwOK_api import get_user_by_auth, get_nodes, generate_links, DB_PATH
import sqlite3

auth_id = 'RVMxx0Uqi_vkybn9e8MYrQ'
print(f"DB_PATH: {DB_PATH}")
print(f"auth_id: {auth_id}")

try:
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT id, username, uuid, password, enable FROM users WHERE auth_id=?", (auth_id,))
    row = c.fetchone()
    print(f"User row: {row}")
    conn.close()
except Exception as e:
    print(f"DB error: {e}")

try:
    user = get_user_by_auth(auth_id)
    print(f"User by auth: {user}")
except Exception as e:
    print(f"get_user_by_auth error: {e}")
    import traceback
    traceback.print_exc()

try:
    nodes = get_nodes()
    print(f"Nodes: {nodes}")
except Exception as e:
    print(f"get_nodes error: {e}")

try:
    if user:
        configs = generate_links(user['id'], user['uuid'], user['password'], nodes)
        print(f"Configs count: {len(configs)}")
        for cfg in configs:
            print(f"  Node: {cfg['node']}, SS: {cfg['ss'][:50]}...")
except Exception as e:
    print(f"generate_links error: {e}")
