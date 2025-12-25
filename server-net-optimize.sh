#!/bin/bash

# ==============================================================================
#                 Linux 系统工具箱多合一管理脚本 (增强版)
#
# 功能:
# 1. 系统信息检测 (OS, IP)
# 2. Swap空间与内核参数管理
# 3. 系统极限精简与优化
# 4. DNS配置管理
# 5. Crontab计划任务管理
# 6. x-ui 和 WARP 极致优化 (包含完整Crontab配置)
#
# ==============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# --- 通用辅助函数 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1
}

validate_input() {
    local prompt="$1"
    local default="$2"
    local min="$3"
    local max="$4"
    local value

    while true; do
        read -rp "$prompt (默认 $default): " value
        value=${value:-$default}
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
            echo "$value"
            return
        else
            echo "无效输入，请输入 $min 到 $max 之间的整数"
        fi
    done
}

# 添加Crontab任务（防止重复）
# 参数1: 任务内容
# 参数2: 用于判断重复的关键字
add_cron_task() {
    local task="$1"
    local keyword="$2"
    local current_crontab
    
    current_crontab=$(crontab -l 2>/dev/null || echo "")
    
    if echo "$current_crontab" | grep -Fq "$keyword"; then
        echo -e "  ${YELLOW}[跳过]${PLAIN} 任务已存在: $keyword"
        return 1
    else
        (echo "$current_crontab"; echo "$task") | crontab -
        echo -e "  ${GREEN}[添加]${PLAIN} $task"
        return 0
    fi
}

# --- 功能模块 1: 系统信息与网络 ---
detect_os() {
    echo -e "\n${BLUE}--- 系统信息 ---${PLAIN}"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "操作系统: $NAME $VERSION"
    else
        echo "操作系统: 未知"
    fi
    echo "内核版本: $(uname -r)"
    echo "--------------------"
}

check_ip() {
    echo -e "\n${BLUE}--- IP 地址信息 ---${PLAIN}"
    
    if command -v ip &> /dev/null; then
        local_ipv4=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
        local_ipv6=$(ip -6 addr show | grep -oP '(?<=inet6\s)[\da-f:]+' | grep -v '^::1' | grep -v '^fe80' | head -1)
    fi
    
    echo "本地IPv4: ${local_ipv4:-未检测到}"
    echo "本地IPv6: ${local_ipv6:-未检测到}"
    
    public_ipv4=$(curl -4 -s --max-time 5 https://api64.ipify.org 2>/dev/null)
    public_ipv6=$(curl -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null)
    
    echo "外部IPv4: ${public_ipv4:-未检测到}"
    echo "外部IPv6: ${public_ipv6:-未检测到}"
    echo "--------------------"
}

show_system_info() {
    detect_os
    check_ip
    echo -e "\n${BLUE}--- 内存与磁盘 ---${PLAIN}"
    free -h
    echo ""
    df -h /
    echo "--------------------"
}

# --- 功能模块 2: Swap管理与内核参数 ---
create_swap_space() {
    read -rp "输入交换文件路径（默认 /swapfile）: " swapfile
    swapfile=${swapfile:-/swapfile}
    size=$(validate_input "输入交换文件大小（MB）" 1024 1 1048576)
    
    if [[ -f "$swapfile" ]]; then
        echo "检测到交换文件已存在，正在删除..."
        swapoff "$swapfile" 2>/dev/null
        rm -f "$swapfile"
    fi
    
    sed -i "\|$swapfile|d" /etc/fstab 2>/dev/null
    
    dd if=/dev/zero of="$swapfile" bs=1M count="$size" status=progress
    chmod 600 "$swapfile"
    mkswap "$swapfile" && swapon "$swapfile"
    echo "$swapfile none swap sw 0 0" >> /etc/fstab
    echo -e "${GREEN}交换空间已创建并启用${PLAIN}"
}

delete_swap_space() {
    current_swap=$(swapon --show=NAME --noheadings | grep '^/' | head -1)
    if [[ -z "$current_swap" ]]; then
        echo "未找到任何启用的交换文件"
        return 1
    fi
    swapoff "$current_swap" && rm -f "$current_swap"
    sed -i "\|$current_swap|d" /etc/fstab
    echo -e "${GREEN}交换空间已关闭并删除${PLAIN}"
}

set_kernel_parameters() {
    echo -e "\n${YELLOW}内核参数设置${PLAIN}"
    echo "1. vm.swappiness (0-100): 控制系统使用交换空间的倾向"
    swappiness=$(validate_input "设置 vm.swappiness" 10 0 100)
    
    echo "2. vm.vfs_cache_pressure (0-1000): 控制内核回收缓存的倾向"
    vfs_cache_pressure=$(validate_input "设置 vm.vfs_cache_pressure" 75 0 1000)
    
    sysctl -w vm.swappiness="$swappiness" vm.vfs_cache_pressure="$vfs_cache_pressure"
    
    mkdir -p /etc/sysctl.d/
    cat > /etc/sysctl.d/99-custom.conf <<EOF
vm.swappiness = $swappiness
vm.vfs_cache_pressure = $vfs_cache_pressure
EOF
    echo -e "${GREEN}内核参数已设置并持久化${PLAIN}"
}

manage_swap_and_kernel() {
    while true; do
        echo -e "\n${BLUE}当前系统状态：${PLAIN}"
        free -h
        swapon --show
        echo -e "\n请选择操作："
        echo "1) 创建交换空间"
        echo "2) 删除交换空间"
        echo "3) 设置内核参数"
        echo "4) 返回主菜单"
        read -rp "输入选项: " choice
        case $choice in
            1) create_swap_space ;;
            2) delete_swap_space ;;
            3) set_kernel_parameters ;;
            4) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

# --- 功能模块 3: 系统极限精简 ---
system_streamline() {
    local start_disk_usage
    start_disk_usage=$(df -k / | awk 'NR==2 {print $3}')
    local actions_taken=()

    log_action() { actions_taken+=("$1"); }
    
    disable_service() {
        local service_name="$1"
        if systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}"; then
            systemctl stop "${service_name}" >/dev/null 2>&1 || true
            systemctl disable "${service_name}" >/dev/null 2>&1 && log_action "禁用服务 ${service_name}"
        fi
    }

    echo -e "${GREEN}=========== 系统极限精简开始 ===========${PLAIN}"
    
    if command -v apt-get &> /dev/null; then
        echo "  - 正在清理APT..."
        apt-get update >/dev/null 2>&1
        apt-get clean >/dev/null 2>&1
        apt-get autoremove --purge -y >/dev/null 2>&1
        rm -rf /var/lib/apt/lists/*
        log_action "清理了APT缓存和遗留包"
    fi

    echo "  - 正在清理系统文档..."
    [ -d "/usr/share/doc" ] && rm -rf /usr/share/doc/* && log_action "移除系统文档"
    [ -d "/usr/share/man" ] && rm -rf /usr/share/man/* && log_action "移除手册页"

    echo "  - 正在清理日志..."
    journalctl --rotate >/dev/null 2>&1
    journalctl --vacuum-time=1s >/dev/null 2>&1
    find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" \) -delete 2>/dev/null
    log_action "清理了系统日志"

    echo "  - 正在禁用非核心服务..."
    services_to_disable=(
        apt-daily.timer apt-daily-upgrade.timer
        systemd-tmpfiles-clean.timer e2scrub_reap.service
        unattended-upgrades.service
    )
    for service in "${services_to_disable[@]}"; do
        disable_service "$service"
    done

    local end_disk_usage
    end_disk_usage=$(df -k / | awk 'NR==2 {print $3}')
    local space_freed=$(( (start_disk_usage - end_disk_usage) / 1024 ))
    
    echo -e "\n${GREEN}=========== 精简总结 ===========${PLAIN}"
    for action in "${actions_taken[@]}"; do echo "  ✓ ${action}"; done
    echo -e "  释放空间: ${space_freed} MB"
    echo "=================================="
}

# --- 功能模块 4: DNS配置管理 ---
manage_dns() {
    while true; do
        echo -e "\n${BLUE}--- DNS配置管理 ---${PLAIN}"
        echo "当前DNS配置:"
        cat /etc/resolv.conf 2>/dev/null | grep -E "^nameserver" || echo "  (无)"
        echo ""
        echo "1) 设置为通用DNS (Cloudflare + Google)"
        echo "2) 设置为DNS64 (仅IPv6网络使用)"
        echo "3) 设置为台湾DNS (HiNet + NTT)"
        echo "4) 自定义DNS"
        echo "5) 返回主菜单"
        read -rp "选择: " dns_choice
        
        case $dns_choice in
            1)
                cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
                echo -e "${GREEN}已设置为通用DNS${PLAIN}"
                ;;
            2)
                cat > /etc/resolv.conf <<EOF
nameserver 2606:4700:4700::64
nameserver 2001:4860:4860::64
EOF
                echo -e "${GREEN}已设置为DNS64${PLAIN}"
                ;;
            3)
                cat > /etc/resolv.conf <<EOF
nameserver 168.95.1.1
nameserver 2001:b000:168::1
nameserver 129.250.35.250
nameserver 2001:2f8:0:1::2:3
EOF
                echo -e "${GREEN}已设置为台湾DNS${PLAIN}"
                ;;
            4)
                echo "请输入DNS服务器地址 (每行一个，输入空行结束):"
                > /etc/resolv.conf
                while true; do
                    read -rp "nameserver: " dns_addr
                    [[ -z "$dns_addr" ]] && break
                    echo "nameserver $dns_addr" >> /etc/resolv.conf
                done
                echo -e "${GREEN}自定义DNS已设置${PLAIN}"
                ;;
            5) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

# --- 功能模块 5: Crontab计划任务管理 (单独任务) ---
manage_crontab() {
    while true; do
        echo -e "\n${BLUE}--- Crontab计划任务管理 ---${PLAIN}"
        echo "当前计划任务:"
        echo "--------------------"
        crontab -l 2>/dev/null || echo "  (无任务)"
        echo "--------------------"
        echo ""
        echo "可添加的单独任务:"
        echo "1) 开机修改DNS (通用DNS)"
        echo "2) 开机修改DNS (台湾DNS)"
        echo "3) x-ui保活脚本 (每30分钟)"
        echo "4) x-ui定时重启 (每天凌晨2点)"
        echo "5) 自定义任务"
        echo ""
        echo "管理操作:"
        echo "6) 编辑Crontab"
        echo "7) 清空所有任务"
        echo "8) 返回主菜单"
        read -rp "选择: " cron_choice
        
        case $cron_choice in
            1)
                add_cron_task '@reboot sleep 15 && /usr/bin/printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\n" > /etc/resolv.conf' "resolv.conf"
                ;;
            2)
                add_cron_task '@reboot sleep 15 && /usr/bin/printf "nameserver 168.95.1.1\nnameserver 2001:b000:168::1\nnameserver 129.250.35.250\nnameserver 2001:2f8:0:1::2:3\n" > /etc/resolv.conf' "resolv.conf"
                ;;
            3)
                if [ -f "/usr/local/x-ui/goxui.sh" ]; then
                    add_cron_task '*/30 * * * * /usr/local/x-ui/goxui.sh >/dev/null 2>&1' "goxui.sh"
                else
                    echo -e "${RED}未找到 /usr/local/x-ui/goxui.sh${PLAIN}"
                fi
                ;;
            4)
                add_cron_task '0 2 * * * systemctl restart x-ui >/dev/null 2>&1' "restart x-ui"
                ;;
            5)
                read -rp "输入Crontab任务 (如: */5 * * * * /path/to/script.sh): " custom_task
                if [[ -n "$custom_task" ]]; then
                    read -rp "输入用于判断重复的关键字: " custom_keyword
                    add_cron_task "$custom_task" "${custom_keyword:-$custom_task}"
                fi
                ;;
            6)
                crontab -e
                ;;
            7)
                read -rp "确认清空所有计划任务? (y/N): " confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    crontab -r 2>/dev/null
                    echo -e "${GREEN}已清空所有计划任务${PLAIN}"
                fi
                ;;
            8) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

# --- 功能模块 6: x-ui 和 WARP 极致优化 (完整方案) ---
optimize_xui_warp() {
    echo -e "\n${YELLOW}========================================${PLAIN}"
    echo -e "${YELLOW}   x-ui 和 WARP 极致优化 (一站式方案)${PLAIN}"
    echo -e "${YELLOW}========================================${PLAIN}"
    echo ""
    echo "此模式将自动完成以下所有操作："
    echo ""
    echo "  [系统优化]"
    echo "    ├─ 强制关闭 Swap (防止烂盘卡死)"
    echo "    ├─ 系统日志挂载到内存 (/var/log → tmpfs)"
    echo "    └─ WARP日志重定向到黑洞"
    echo ""
    echo "  [x-ui优化]"
    echo "    ├─ 数据库迁移到内存 (/dev/shm)"
    echo "    └─ 创建数据库备份用于自动恢复"
    echo ""
    echo "  [自动化脚本]"
    echo "    ├─ 生成 reset_ram_state.sh (每日清洗)"
    echo "    └─ 生成 check_memory.sh (内存看门狗)"
    echo ""
    echo "  [Crontab任务] (自动添加，防止重复)"
    echo "    ├─ @reboot 开机执行清洗脚本"
    echo "    ├─ @reboot 开机修改DNS"
    echo "    ├─ 0 4 * * * 每天凌晨4点清洗"
    echo "    └─ */10 * * * * 每10分钟内存检查"
    echo ""
    read -rp "确认执行完整优化? (y/N): " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && echo "已取消" && return

    # ==================== 第一步: 检测环境 ====================
    echo -e "\n${GREEN}[1/6] 检测软件环境...${PLAIN}"
    
    has_xui=false
    has_warp=false
    xui_db_path=""
    
    # 检测 x-ui
    if [ -f "/usr/local/x-ui/bin/x-ui" ] || systemctl is-active --quiet x-ui 2>/dev/null; then
        has_xui=true
        if [ -f "/etc/x-ui-yg/x-ui-yg.db" ]; then
            xui_db_path="/etc/x-ui-yg/x-ui-yg.db"
        elif [ -f "/etc/x-ui/x-ui.db" ]; then
            xui_db_path="/etc/x-ui/x-ui.db"
        fi
        echo -e "  ${GREEN}✓${PLAIN} 检测到 x-ui"
        [ -n "$xui_db_path" ] && echo -e "    数据库路径: $xui_db_path"
    else
        echo -e "  ${YELLOW}✗${PLAIN} 未检测到 x-ui"
    fi

    # 检测 WARP
    if systemctl list-unit-files 2>/dev/null | grep -qE "warp-go|warp-svc|wg-quick"; then
        has_warp=true
        echo -e "  ${GREEN}✓${PLAIN} 检测到 WARP/WireGuard 服务"
    else
        echo -e "  ${YELLOW}✗${PLAIN} 未检测到 WARP"
    fi

    # ==================== 第二步: 关闭Swap ====================
    echo -e "\n${GREEN}[2/6] 关闭 Swap...${PLAIN}"
    swapoff -a 2>/dev/null
    sed -i '/swap/s/^/#/' /etc/fstab 2>/dev/null
    rm -f /swapfile 2>/dev/null
    echo -e "  ${GREEN}✓${PLAIN} Swap 已关闭"

    # ==================== 第三步: 日志内存化 ====================
    echo -e "\n${GREEN}[3/6] 优化日志存储...${PLAIN}"
    
    # 系统日志
    if ! grep -q "tmpfs /var/log" /etc/fstab 2>/dev/null; then
        echo "tmpfs /var/log tmpfs defaults,noatime,mode=0755,size=15M 0 0" >> /etc/fstab
        echo -e "  ${GREEN}✓${PLAIN} 系统日志将挂载到内存 (重启后生效)"
    else
        echo -e "  ${YELLOW}-${PLAIN} 日志内存挂载已配置"
    fi

    # WARP日志黑洞
    if [ "$has_warp" = true ]; then
        pkill -f WARP-UP.sh 2>/dev/null
        screen -wipe 2>/dev/null
        
        if [ -d "/root/warpip" ]; then
            rm -f /root/warpip/warp_log.txt 2>/dev/null
            ln -sf /dev/null /root/warpip/warp_log.txt
            echo -e "  ${GREEN}✓${PLAIN} WARP日志已重定向到黑洞"
        fi
    fi

    # ==================== 第四步: x-ui数据库内存化 ====================
    if [ "$has_xui" = true ] && [ -n "$xui_db_path" ]; then
        echo -e "\n${GREEN}[4/6] 迁移 x-ui 数据库至内存...${PLAIN}"
        
        systemctl stop x-ui 2>/dev/null
        
        db_dir=$(dirname "$xui_db_path")
        db_name=$(basename "$xui_db_path")
        backup_path="${xui_db_path}.backup"
        
        if [ -f "$xui_db_path" ] && [ ! -L "$xui_db_path" ]; then
            cp -f "$xui_db_path" "$backup_path"
            mv "$xui_db_path" "/dev/shm/${db_name}"
            ln -sf "/dev/shm/${db_name}" "$xui_db_path"
            echo -e "  ${GREEN}✓${PLAIN} 数据库已迁移到 /dev/shm/"
            echo -e "  ${GREEN}✓${PLAIN} 备份已保存: $backup_path"
        elif [ -L "$xui_db_path" ]; then
            echo -e "  ${YELLOW}-${PLAIN} 数据库已经是软链接，跳过"
        fi
        
        systemctl start x-ui 2>/dev/null
    else
        echo -e "\n${GREEN}[4/6] x-ui数据库迁移...${PLAIN}"
        echo -e "  ${YELLOW}-${PLAIN} 跳过 (未检测到x-ui或数据库)"
    fi

    # ==================== 第五步: 生成脚本 ====================
    echo -e "\n${GREEN}[5/6] 生成自动化脚本...${PLAIN}"
    
    # --- 生成清洗脚本 ---
    cat > /usr/local/bin/reset_ram_state.sh <<'SCRIPT_HEAD'
#!/bin/bash
# 自动生成的内存优化清洗脚本
# 用途: 重启服务、恢复内存数据库、清理缓存

echo "[$(date)] Starting RAM reset..."

# --- 停止服务 ---
SCRIPT_HEAD

    [ "$has_xui" = true ] && echo "systemctl stop x-ui 2>/dev/null" >> /usr/local/bin/reset_ram_state.sh
    
    if [ "$has_warp" = true ]; then
        cat >> /usr/local/bin/reset_ram_state.sh <<'EOF'
systemctl stop warp-go 2>/dev/null
systemctl stop wg-quick@wgcf 2>/dev/null
systemctl stop warp-svc 2>/dev/null
pkill -f WARP-UP.sh 2>/dev/null
screen -wipe 2>/dev/null
EOF
    fi

    cat >> /usr/local/bin/reset_ram_state.sh <<'EOF'

# --- 清理与恢复 ---
EOF

    if [ -n "$xui_db_path" ]; then
        cat >> /usr/local/bin/reset_ram_state.sh <<EOF
# 恢复 x-ui 数据库到内存
if [ -f "${xui_db_path}.backup" ]; then
    cp -f "${xui_db_path}.backup" "/dev/shm/$(basename $xui_db_path)"
    echo "  Database restored to RAM"
fi
EOF
    fi

    cat >> /usr/local/bin/reset_ram_state.sh <<'EOF'

# 重建日志目录结构
mkdir -p /var/log/journal 2>/dev/null
mkdir -p /var/log/x-ui 2>/dev/null
chmod 755 /var/log 2>/dev/null

# 释放内存缓存
sync
echo 3 > /proc/sys/vm/drop_caches

# --- 重启服务 ---
EOF

    if [ "$has_warp" = true ]; then
        cat >> /usr/local/bin/reset_ram_state.sh <<'EOF'
# 先启动 WARP (提供网络)
systemctl start warp-go 2>/dev/null
systemctl restart wg-quick@wgcf 2>/dev/null
systemctl restart warp-svc 2>/dev/null
sleep 5

# 启动刷IP脚本
if [ -f "/root/WARP-UP.sh" ]; then
    screen -UdmS up /bin/bash -c "/root/WARP-UP.sh >/dev/null 2>&1"
fi
EOF
    fi

    [ "$has_xui" = true ] && echo "systemctl start x-ui 2>/dev/null" >> /usr/local/bin/reset_ram_state.sh

    echo 'echo "[$(date)] RAM Reset Complete"' >> /usr/local/bin/reset_ram_state.sh
    chmod +x /usr/local/bin/reset_ram_state.sh
    echo -e "  ${GREEN}✓${PLAIN} 创建 /usr/local/bin/reset_ram_state.sh"

    # --- 生成看门狗脚本 ---
    cat > /usr/local/bin/check_memory.sh <<'EOF'
#!/bin/bash
# 内存看门狗 - 内存使用超过88%时自动触发清洗

mem_used=$(free | grep Mem | awk '{print int($3/$2 * 100)}')

if [ "$mem_used" -gt 88 ]; then
    echo "[$(date)] Memory ${mem_used}% > 88%, triggering reset..."
    /usr/local/bin/reset_ram_state.sh
fi
EOF
    chmod +x /usr/local/bin/check_memory.sh
    echo -e "  ${GREEN}✓${PLAIN} 创建 /usr/local/bin/check_memory.sh"

    # ==================== 第六步: 配置Crontab ====================
    echo -e "\n${GREEN}[6/6] 配置 Crontab 计划任务...${PLAIN}"
    
    # 备份当前crontab
    crontab -l > /root/crontab_backup_$(date +%Y%m%d%H%M%S).txt 2>/dev/null
    
    # 添加任务 (使用防重复函数)
    add_cron_task '@reboot /usr/local/bin/reset_ram_state.sh' "reset_ram_state.sh"
    add_cron_task '@reboot sleep 15 && /usr/bin/printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\n" > /etc/resolv.conf' "resolv.conf"
    add_cron_task '0 4 * * * /usr/local/bin/reset_ram_state.sh >/dev/null 2>&1' "0 4 * * * /usr/local/bin/reset_ram_state.sh"
    add_cron_task '*/10 * * * * /usr/local/bin/check_memory.sh >/dev/null 2>&1' "check_memory.sh"
    
    # 添加WARP日志黑洞保险
    if [ "$has_warp" = true ] && [ -d "/root/warpip" ]; then
        add_cron_task '0 0 * * * ln -sf /dev/null /root/warpip/warp_log.txt' "warp_log.txt"
    fi

    # ==================== 完成 ====================
    echo -e "\n${GREEN}===========================================${PLAIN}"
    echo -e "${GREEN}          极致优化配置完成！${PLAIN}"
    echo -e "${GREEN}===========================================${PLAIN}"
    echo ""
    echo "已完成的配置:"
    echo "  ✓ Swap 已关闭"
    echo "  ✓ 系统日志将使用内存存储"
    [ "$has_warp" = true ] && echo "  ✓ WARP日志已黑洞化"
    [ "$has_xui" = true ] && [ -n "$xui_db_path" ] && echo "  ✓ x-ui数据库已内存化"
    echo "  ✓ 清洗脚本已创建"
    echo "  ✓ 看门狗脚本已创建"
    echo "  ✓ Crontab任务已配置"
    echo ""
    echo "当前Crontab任务:"
    crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$"
    echo ""
    
    read -rp "是否立即重启系统以使所有更改生效? (y/N): " reboot_opt
    if [[ "$reboot_opt" =~ ^[yY]$ ]]; then
        echo "正在重启..."
        reboot
    else
        echo -e "${YELLOW}请稍后手动重启系统 (命令: reboot)${PLAIN}"
    fi
}

# --- 主菜单 ---
main_menu() {
    check_root
    while true; do
        clear
        echo -e "${BLUE}=============== Linux 系统工具箱 (增强版) ================${PLAIN}"
        echo "1) 显示系统和IP信息"
        echo "2) 管理Swap空间与内核参数"
        echo "3) 执行系统极限精简与优化"
        echo "4) DNS配置管理"
        echo "5) Crontab计划任务管理 (单独任务)"
        echo -e "6) ${GREEN}x-ui 和 WARP 极致优化 (完整方案)${PLAIN}"
        echo "7) 退出"
        echo "============================================================"
        read -rp "请输入选项: " main_choice

        case $main_choice in
            1)
                clear
                show_system_info
                ;;
            2)
                clear
                manage_swap_and_kernel
                ;;
            3)
                clear
                read -rp "警告：此操作将清理系统并禁用非核心服务，是否继续? (y/N): " confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    system_streamline
                else
                    echo "操作已取消。"
                fi
                ;;
            4)
                clear
                manage_dns
                ;;
            5)
                clear
                manage_crontab
                ;;
            6)
                clear
                optimize_xui_warp
                ;;
            7)
                echo "感谢使用，脚本退出。"
                exit 0
                ;;
            *)
                echo "无效选项，请输入1-7之间的数字。"
                ;;
        esac
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# --- 脚本入口 ---
main_menu
