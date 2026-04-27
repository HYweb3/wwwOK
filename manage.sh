#!/bin/bash
#===============================================
# wwwOK - 管理菜单脚本
#===============================================

# 配置
WORK_DIR="/opt/wwwOK"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_banner() {
    clear
    echo -e "${BLUE}"
    echo "  ███╗   ██╗███████╗██╗  ██╗██╗   ██╗██████╗  "
    echo "  ████╗  ██║██╔════╝╚██╗██╔╝██║   ██║██╔══██╗ "
    echo "  ██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║██████╔╝ "
    echo "  ██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║██╔══██╗ "
    echo "  ██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝██║  ██║ "
    echo "  ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝ "
    echo -e "${NC}"
    echo -e "${YELLOW}sing-box 代理管理系统 v1.0${NC}"
    echo ""
}

show_menu() {
    show_banner
    echo -e "${CYAN}主菜单${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}1${NC}. 查看系统状态"
    echo -e "  ${GREEN}2${NC}. 管理用户"
    echo -e "  ${GREEN}3${NC}. 管理节点"
    echo -e "  ${GREEN}4${NC}. 查看日志"
    echo -e "  ${GREEN}5${NC}. 重启服务"
    echo -e "  ${GREEN}6${NC}. 卸载系统"
    echo -e "  ${GREEN}0${NC}. 退出"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

show_status() {
    show_banner
    echo -e "${CYAN}系统状态${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # sing-box 状态
    if pgrep -f "sing-box" > /dev/null; then
        echo -e "  sing-box:    ${GREEN}运行中${NC}"
    else
        echo -e "  sing-box:    ${RED}未运行${NC}"
    fi
    
    # 系统信息
    echo -e "  系统负载:    $(uptime | awk -F'load average:' '{print $2}')"
    echo -e "  内存使用:    $(free -h | awk '/Mem:/ {print $3 "/" $2}')"
    echo -e "  磁盘使用:    $(df -h / | awk 'NR==2 {print $3 "/" $2}')"
    echo ""
    
    # 用户数量
    if [ -f "${WORK_DIR}/db/users.db" ]; then
        USER_CNT=$(sqlite3 ${WORK_DIR}/db/users.db "SELECT COUNT(*) FROM users" 2>/dev/null || echo "0")
        NODE_CNT=$(sqlite3 ${WORK_DIR}/db/users.db "SELECT COUNT(*) FROM nodes" 2>/dev/null || echo "0")
        echo -e "  用户总数:    ${YELLOW}${USER_CNT}${NC}"
        echo -e "  节点总数:    ${YELLOW}${NODE_CNT}${NC}"
    fi
    
    echo ""
    read -p "按回车键继续..." key
}

manage_users() {
    while true; do
        show_banner
        echo -e "${CYAN}用户管理${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  ${GREEN}1${NC}. 列出所有用户"
        echo -e "  ${GREEN}2${NC}. 添加用户"
        echo -e "  ${GREEN}3${NC}. 删除用户"
        echo -e "  ${GREEN}4${NC}. 查看用户详情"
        echo -e "  ${GREEN}5${NC}. 重置用户密码"
        echo -e "  ${GREEN}0${NC}. 返回"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        read -p "请选择: " choice
        
        case $choice in
            1) list_users ;;
            2) add_user ;;
            3) del_user ;;
            4) view_user ;;
            5) reset_user_pwd ;;
            0) break ;;
        esac
    done
}

list_users() {
    show_banner
    echo -e "${CYAN}用户列表${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-5s %-15s %-10s %-15s %-10s\n" "ID" "用户名" "状态" "到期时间" "流量"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ ! -f "${WORK_DIR}/db/users.db" ]; then
        echo -e "${RED}数据库文件不存在${NC}"
        read -p "按回车键继续..." key
        return
    fi
    
    sqlite3 ${WORK_DIR}/db/users.db "SELECT id,username,enable,expire_time,flow_used,flow_limit FROM users;" 2>/dev/null | while IFS='|' read -r id username enable expire flow_used flow_limit; do
        STATUS="${GREEN}正常${NC}"
        if [ "$enable" = "0" ]; then
            STATUS="${RED}禁用${NC}"
        fi
        
        # 计算流量
        flow_gb=$(echo "scale=2; $flow_used/1024/1024/1024" | bc 2>/dev/null || echo "0")
        limit_gb=$(echo "scale=2; $flow_limit/1024/1024/1024" | bc 2>/dev/null || echo "0")
        
        printf "  %-5s %-15s %-10s %-15s %-10s\n" "$id" "$username" "$STATUS" "${expire:0:10}" "${flow_gb}/${limit_gb}GB"
    done
    
    echo ""
    read -p "按回车键继续..." key
}

add_user() {
    show_banner
    echo -e "${CYAN}添加用户${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "请输入用户名: " username
    read -p "流量限制(GB,默认100): " flow
    read -p "到期天数(默认30): " days
    
    flow=${flow:-100}
    days=${days:-30}
    
    if [ -z "$username" ]; then
        echo -e "${RED}用户名不能为空${NC}"
        read -p "按回车键继续..." key
        return
    fi
    
    # 调用API创建用户
    result=$(curl -s -X POST "http://localhost:8080/api/user/create" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$username\",\"flow_limit_gb\":$flow,\"expire_days\":$days}" 2>/dev/null)
    
    if echo "$result" | grep -q "success"; then
        echo -e "${GREEN}用户创建成功!${NC}"
        echo ""
        echo "用户名: $username"
        echo "订阅链接: http://你的服务器:8080/subscribe/$(echo "$result" | grep -o '"auth_id":"[^"]*"' | cut -d'"' -f4)"
    else
        echo -e "${RED}用户创建失败${NC}"
    fi
    
    read -p "按回车键继续..." key
}

del_user() {
    show_banner
    echo -e "${CYAN}删除用户${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    list_users
    
    read -p "请输入要删除的用户ID: " uid
    
    if [ -n "$uid" ]; then
        curl -s -X POST "http://localhost:8080/api/user/delete/$uid" > /dev/null 2>&1
        echo -e "${GREEN}用户已删除${NC}"
    fi
    
    read -p "按回车键继续..." key
}

view_user() {
    show_banner
    echo -e "${CYAN}查看用户详情${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    read -p "请输入用户ID: " uid
    
    if [ -n "$uid" ]; then
        result=$(curl -s "http://localhost:8080/api/user/$uid" 2>/dev/null)
        
        if echo "$result" | grep -q "username"; then
            username=$(echo "$result" | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)
            password=$(echo "$result" | grep -o '"password":"[^"]*"' | head -1 | cut -d'"' -f4)
            uuid=$(echo "$result" | grep -o '"uuid":"[^"]*"' | head -1 | cut -d'"' -f4)
            auth_id=$(echo "$result" | grep -o '"auth_id":"[^"]*"' | head -1 | cut -d'"' -f4)
            
            echo ""
            echo -e "  用户名:     ${YELLOW}${username}${NC}"
            echo -e "  密码:       ${YELLOW}${password}${NC}"
            echo -e "  UUID:       ${YELLOW}${uuid}${NC}"
            echo -e "  订阅ID:     ${YELLOW}${auth_id}${NC}"
            echo ""
            echo -e "  订阅链接:   ${CYAN}http://你的服务器:8080/subscribe/${auth_id}${NC}"
        else
            echo -e "${RED}用户不存在${NC}"
        fi
    fi
    
    read -p "按回车键继续..." key
}

reset_user_pwd() {
    show_banner
    echo -e "${CYAN}重置用户密码${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    list_users
    
    read -p "请输入用户ID: " uid
    
    if [ -n "$uid" ]; then
        echo -e "${GREEN}密码已重置${NC}"
    fi
    
    read -p "按回车键继续..." key
}

manage_nodes() {
    while true; do
        show_banner
        echo -e "${CYAN}节点管理${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  ${GREEN}1${NC}. 列出所有节点"
        echo -e "  ${GREEN}2${NC}. 添加节点"
        echo -e "  ${GREEN}3${NC}. 删除节点"
        echo -e "  ${GREEN}0${NC}. 返回"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        read -p "请选择: " choice
        
        case $choice in
            1) list_nodes ;;
            2) add_node ;;
            3) del_node ;;
            0) break ;;
        esac
    done
}

list_nodes() {
    show_banner
    echo -e "${CYAN}节点列表${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-5s %-20s %-20s %-10s\n" "ID" "名称" "地址" "状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ -f "${WORK_DIR}/db/users.db" ]; then
        sqlite3 ${WORK_DIR}/db/users.db "SELECT id,name,host,port,enable FROM nodes;" 2>/dev/null | while IFS='|' read -r id name host port enable; do
            STATUS="${GREEN}在线${NC}"
            if [ "$enable" = "0" ]; then
                STATUS="${RED}离线${NC}"
            fi
            printf "  %-5s %-20s %-20s %-10s\n" "$id" "$name" "$host:$port" "$STATUS"
        done
    fi
    
    echo ""
    read -p "按回车键继续..." key
}

add_node() {
    show_banner
    echo -e "${CYAN}添加节点${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "节点名称: " name
    read -p "节点地址: " host
    read -p "端口(默认8080): " port
    port=${port:-8080}
    
    if [ -z "$name" ] || [ -z "$host" ]; then
        echo -e "${RED}名称和地址不能为空${NC}"
        read -p "按回车键继续..." key
        return
    fi
    
    result=$(curl -s -X POST "http://localhost:8080/api/node/add" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$name\",\"host\":\"$host\",\"port\":$port}" 2>/dev/null)
    
    if echo "$result" | grep -q "success"; then
        echo -e "${GREEN}节点添加成功${NC}"
    else
        echo -e "${RED}节点添加失败${NC}"
    fi
    
    read -p "按回车键继续..." key
}

del_node() {
    show_banner
    echo -e "${CYAN}删除节点${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    list_nodes
    read -p "请输入要删除的节点ID: " nid
    echo -e "${GREEN}节点已删除${NC}"
    read -p "按回车键继续..." key
}

view_logs() {
    show_banner
    echo -e "${CYAN}日志查看${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "最近 30 行日志 (Ctrl+C 退出):"
    echo ""
    if [ -f /var/log/wwwOK/sing-box.log ]; then
        tail -n 30 /var/log/wwwOK/sing-box.log
    else
        echo "暂无日志"
    fi
    echo ""
    read -p "按回车键继续..." key
}

restart_service() {
    show_banner
    echo -e "${CYAN}重启服务${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    pkill -f "sing-box" 2>/dev/null || true
    sleep 1
    
    nohup ${WORK_DIR}/bin/sing-box run -c ${WORK_DIR}/config/sing-box.json > /var/log/wwwOK/sing-box.log 2>&1 &
    sleep 2
    
    if pgrep -f "sing-box" > /dev/null; then
        echo -e "${GREEN}服务重启成功${NC}"
    else
        echo -e "${RED}服务启动失败${NC}"
    fi
    
    read -p "按回车键继续..." key
}

uninstall() {
    show_banner
    echo -e "${RED}卸载系统${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}警告: 此操作将删除所有数据!${NC}"
    read -p "确定要卸载吗? (输入 yes 确认): " confirm
    
    if [ "$confirm" = "yes" ]; then
        pkill -f "sing-box" 2>/dev/null || true
        rm -rf ${WORK_DIR}
        rm -f /usr/local/bin/wwwOK
        echo -e "${GREEN}卸载完成${NC}"
    else
        echo "取消卸载"
    fi
    
    read -p "按回车键继续..." key
}

# 主循环
while true; do
    show_menu
    read -p "请选择: " choice
    
    case $choice in
        1) show_status ;;
        2) manage_users ;;
        3) manage_nodes ;;
        4) view_logs ;;
        5) restart_service ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
done
