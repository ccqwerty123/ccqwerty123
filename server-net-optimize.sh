#!/bin/bash

#==============================================================================
# Linux 系统工具箱多合一管理脚本 (综合优化版)
# 功能:
#   1. 系统信息检测 (OS, IP)
#   2. Swap空间与内核参数管理
#   3. 系统极限精简与优化
#   4. DNS配置管理
#   5. 计划任务管理 (自动识别 Cron 或 Systemd Timer)
#   6. x-ui 和 WARP 极致优化 (包含完整自动化配置)
# 特性:
#   - 自动判断 Cron/Systemd Timer 双模调度
#   - LXC 容器兼容性优化
#   - 完善的变量转义和错误处理
#   - 保留 systemd-tmpfiles-clean.timer（防止临时文件填满磁盘）
#==============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 全局变量
SCRIPT_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
IS_LXC=false
HAS_CRON=false

#==============================================================================
# 核心辅助函数
#==============================================================================

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1
}

# 环境初始化检测
init_environment() {
    # 检测 LXC 容器
    if grep -qa "container=lxc" /proc/1/environ 2>/dev/null ||
       grep -qa "lxc" /proc/1/cgroup 2>/dev/null ||
       [ -f "/.dockerenv" ]; then
        IS_LXC=true
    fi

    # 检测 Cron
    if command -v crontab >/dev/null 2>&1 && \
       (systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1 || \
        pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1); then
        HAS_CRON=true
    fi

    # 检测必要命令
    for cmd in systemctl ip free df; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${YELLOW}警告: 命令 '$cmd' 未找到，部分功能可能受限${PLAIN}"
        fi
    done
}

# 带范围验证的输入函数
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
            return 0
        else
            echo -e "${RED}无效输入，请输入 $min 到 $max 之间的整数${PLAIN}" >&2
        fi
    done
}

# 安全地添加 Cron 任务（防止重复）
add_cron_task() {
    local task="$1"
    local task_id="$2"
    local current_cron

    current_cron=$(crontab -l 2>/dev/null || echo "")

    # 使用任务ID作为唯一标识检查重复
    if echo "$current_cron" | grep -Fq "# $task_id"; then
        echo -e "  ${YELLOW}[跳过]${PLAIN} Cron 任务已存在: $task_id"
        return 1
    else
        # 过滤空行后添加
        (echo "$current_cron" | grep -v "^$"; echo "$task # $task_id") | crontab -
        echo -e "  ${GREEN}[添加]${PLAIN} Cron: $task_id"
        return 0
    fi
}

# 安全地创建 Systemd Timer（防止重复）
add_systemd_timer() {
    local task_id="$1"
    local timer_type="$2"
    local timing="$3"
    local cmd="$4"

    local service_file="${SYSTEMD_DIR}/${task_id}.service"
    local timer_file="${SYSTEMD_DIR}/${task_id}.timer"

    # 如果已存在且正在运行，跳过
    if systemctl is-active --quiet "${task_id}.timer" 2>/dev/null; then
        echo -e "  ${YELLOW}[跳过]${PLAIN} Timer 已运行: $task_id"
        return 1
    fi

    # 停止并禁用旧的（如果存在）
    systemctl disable --now "${task_id}.timer" >/dev/null 2>&1

    # 创建 Service 文件
    cat > "$service_file" <<EOF
[Unit]
Description=Auto Task: $task_id
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '$cmd'
StandardOutput=null
StandardError=null
EOF

    # 创建 Timer 文件
    cat > "$timer_file" <<EOF
[Unit]
Description=Timer for $task_id

[Timer]
EOF

    # 根据类型写入时间规则
    case "$timer_type" in
        reboot)
            echo "OnBootSec=30" >> "$timer_file"
            ;;
        daily)
            # 确保格式正确 HH:MM -> HH:MM:00
            [[ "$timing" != *:*:* ]] && timing="${timing}:00"
            echo "OnCalendar=*-*-* $timing" >> "$timer_file"
            echo "Persistent=true" >> "$timer_file"
            ;;
        interval)
            echo "OnBootSec=2min" >> "$timer_file"
            echo "OnUnitActiveSec=$timing" >> "$timer_file"
            ;;
    esac

    cat >> "$timer_file" <<EOF
Unit=${task_id}.service

[Install]
WantedBy=timers.target
EOF

    # 激活 Timer
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now "${task_id}.timer" >/dev/null 2>&1

    if systemctl is-active --quiet "${task_id}.timer" 2>/dev/null; then
        echo -e "  ${GREEN}[添加]${PLAIN} Timer: $task_id"
        return 0
    else
        echo -e "  ${RED}[失败]${PLAIN} Timer 启动失败: $task_id"
        return 1
    fi
}

# 智能任务添加器（自动选择 Cron 或 Systemd Timer）
add_smart_task() {
    local task_type="$1"  # reboot / daily / interval
    local timing="$2"     # 时间格式：HH:MM 或 10min
    local cmd="$3"        # 执行的命令
    local task_id="$4"    # 任务唯一标识

    if [ "$HAS_CRON" = true ]; then
        local cron_time=""
        
        case "$task_type" in
            reboot)
                cron_time="@reboot sleep 30 &&"
                ;;
            daily)
                # 格式 HH:MM -> M H * * *
                local hour minute
                IFS=':' read -r hour minute <<< "$timing"
                hour=${hour:-4}
                minute=${minute:-0}
                # 去除前导零
                hour=$((10#$hour))
                minute=$((10#$minute))
                cron_time="$minute $hour * * *"
                ;;
            interval)
                # 格式 10min -> */10 * * * *
                local min_val
                min_val=$(echo "$timing" | grep -oE "[0-9]+")
                min_val=${min_val:-10}
                cron_time="*/$min_val * * * *"
                ;;
        esac
        
        if [ "$task_type" = "reboot" ]; then
            add_cron_task "${cron_time} ${cmd}" "$task_id"
        else
            add_cron_task "${cron_time} ${cmd} >/dev/null 2>&1" "$task_id"
        fi
    else
        add_systemd_timer "$task_id" "$task_type" "$timing" "$cmd"
    fi
}

# 删除计划任务
remove_smart_task() {
    local task_id="$1"

    if [ "$HAS_CRON" = true ]; then
        local current_cron
        current_cron=$(crontab -l 2>/dev/null)
        if echo "$current_cron" | grep -Fq "# $task_id"; then
            echo "$current_cron" | grep -Fv "# $task_id" | crontab -
            echo -e "  ${GREEN}[删除]${PLAIN} Cron 任务: $task_id"
        else
            echo -e "  ${YELLOW}[跳过]${PLAIN} 任务不存在: $task_id"
        fi
    else
        if systemctl is-enabled --quiet "${task_id}.timer" 2>/dev/null; then
            systemctl disable --now "${task_id}.timer" >/dev/null 2>&1
            rm -f "${SYSTEMD_DIR}/${task_id}.service" "${SYSTEMD_DIR}/${task_id}.timer"
            systemctl daemon-reload >/dev/null 2>&1
            echo -e "  ${GREEN}[删除]${PLAIN} Timer: $task_id"
        else
            echo -e "  ${YELLOW}[跳过]${PLAIN} 任务不存在: $task_id"
        fi
    fi
}

# 显示当前所有计划任务
show_all_tasks() {
    echo -e "\n${BLUE}--- 当前计划任务 ---${PLAIN}"

    if [ "$HAS_CRON" = true ]; then
        echo -e "调度模式: ${GREEN}Cron${PLAIN}"
        echo "────────────────────────────────────────"
        crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" || echo "  (无任务)"
    else
        echo -e "调度模式: ${GREEN}Systemd Timer${PLAIN}"
        echo "────────────────────────────────────────"
        systemctl list-timers --no-pager 2>/dev/null | head -20 || echo "  (无任务)"
    fi

    echo "────────────────────────────────────────"
}

#==============================================================================
# 功能模块 1: 系统信息与网络
#==============================================================================

detect_os() {
    echo -e "\n${BLUE}━━━ 系统信息 ━━━${PLAIN}"

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo -e "操作系统: ${GREEN}$NAME $VERSION${PLAIN}"
    else
        echo "操作系统: 未知"
    fi

    echo "内核版本: $(uname -r)"
    echo "系统架构: $(uname -m)"

    if [ "$IS_LXC" = true ]; then
        echo -e "容器环境: ${YELLOW}LXC/Docker${PLAIN}"
    else
        echo "容器环境: 否"
    fi

    echo -e "调度模式: $([ "$HAS_CRON" = true ] && echo "${GREEN}Cron${PLAIN}" || echo "${GREEN}Systemd Timer${PLAIN}")"
}

check_ip() {
    echo -e "\n${BLUE}━━━ IP地址信息 ━━━${PLAIN}"

    local local_ipv4="" local_ipv6="" public_ipv4="" public_ipv6=""

    if command -v ip &>/dev/null; then
        local_ipv4=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        local_ipv6=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[\da-f:]+' | head -1)
    fi

    echo "本地 IPv4: ${local_ipv4:-未检测到}"
    echo "本地 IPv6: ${local_ipv6:-未检测到}"

    # 公网IP检测（带超时）
    if command -v curl &>/dev/null; then
        public_ipv4=$(curl -4 -s --max-time 3 https://api64.ipify.org 2>/dev/null)
        public_ipv6=$(curl -6 -s --max-time 3 https://api64.ipify.org 2>/dev/null)
    fi

    echo "公网 IPv4: ${public_ipv4:-未检测到}"
    echo "公网 IPv6: ${public_ipv6:-未检测到}"
}

show_system_info() {
    detect_os
    check_ip

    echo -e "\n${BLUE}━━━ 内存状态 ━━━${PLAIN}"
    free -h

    echo -e "\n${BLUE}━━━ 磁盘使用 ━━━${PLAIN}"
    df -h / 2>/dev/null | head -2

    echo -e "\n${BLUE}━━━ Swap 状态 ━━━${PLAIN}"
    if swapon --show 2>/dev/null | grep -q .; then
        swapon --show
    else
        echo "  (未启用 Swap)"
    fi
}

#==============================================================================
# 功能模块 2: Swap管理与内核参数
#==============================================================================

create_swap_space() {
    local swapfile size

    read -rp "输入交换文件路径（默认 /swapfile）: " swapfile
    swapfile=${swapfile:-/swapfile}
    size=$(validate_input "输入交换文件大小（MB）" 1024 64 65536)

    if [ "$IS_LXC" = true ]; then
        echo -e "${YELLOW}警告: LXC 容器中 Swap 操作可能需要宿主机权限${PLAIN}"
        read -rp "继续尝试? (y/N): " confirm
        [[ ! "$confirm" =~ ^[yY]$ ]] && return 1
    fi

    # 清理旧的
    if [[ -f "$swapfile" ]]; then
        echo "检测到交换文件已存在，正在清理..."
        swapoff "$swapfile" 2>/dev/null
        rm -f "$swapfile"
    fi
    sed -i "\|$swapfile|d" /etc/fstab 2>/dev/null

    # 创建新的
    echo "正在创建 ${size}MB 交换文件..."
    if dd if=/dev/zero of="$swapfile" bs=1M count="$size" status=progress 2>/dev/null; then
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null 2>&1
        
        if swapon "$swapfile" 2>/dev/null; then
            echo "$swapfile none swap sw 0 0" >> /etc/fstab
            echo -e "${GREEN}✓ 交换空间已创建并启用${PLAIN}"
            swapon --show
        else
            echo -e "${RED}✗ Swap 启用失败（可能是容器权限限制）${PLAIN}"
            rm -f "$swapfile"
            return 1
        fi
    else
        echo -e "${RED}✗ 创建交换文件失败${PLAIN}"
        return 1
    fi
}

delete_swap_space() {
    echo "当前 Swap 状态:"
    swapon --show 2>/dev/null || echo "  (无 Swap)"

    read -rp "确认关闭并删除所有 Swap? (y/N): " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && return 1

    # 关闭所有 Swap
    swapoff -a 2>/dev/null

    # 删除 swap 文件
    local swap_files
    swap_files=$(grep -E "^[^#].*\sswap\s" /etc/fstab 2>/dev/null | awk '{print $1}')
    for sf in $swap_files; do
        if [[ -f "$sf" ]]; then
            rm -f "$sf"
            echo "已删除: $sf"
        fi
    done

    # 清理 fstab
    sed -i '/swap/d' /etc/fstab 2>/dev/null

    echo -e "${GREEN}✓ Swap 已关闭并清理${PLAIN}"
}

set_kernel_parameters() {
    echo -e "\n${BLUE}━━━ 内核参数设置 ━━━${PLAIN}"

    echo "当前值:"
    echo "  vm.swappiness = $(cat /proc/sys/vm/swappiness 2>/dev/null || echo '未知')"
    echo "  vm.vfs_cache_pressure = $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo '未知')"
    echo ""

    echo "vm.swappiness (0-100): 控制系统使用 Swap 的倾向"
    echo "  0 = 尽量不使用 Swap | 100 = 积极使用 Swap"
    local swappiness
    swappiness=$(validate_input "设置 vm.swappiness" 10 0 100)

    echo ""
    echo "vm.vfs_cache_pressure (0-1000): 控制内核回收缓存的倾向"
    echo "  50 = 平衡 | 更高 = 更积极回收"
    local vfs_cache_pressure
    vfs_cache_pressure=$(validate_input "设置 vm.vfs_cache_pressure" 75 0 1000)

    # 应用设置
    sysctl -w vm.swappiness="$swappiness" >/dev/null 2>&1
    sysctl -w vm.vfs_cache_pressure="$vfs_cache_pressure" >/dev/null 2>&1

    # 持久化
    mkdir -p /etc/sysctl.d/
    cat > /etc/sysctl.d/99-custom-memory.conf <<EOF
# 自定义内存管理参数
vm.swappiness = $swappiness
vm.vfs_cache_pressure = $vfs_cache_pressure
EOF

    echo -e "${GREEN}✓ 内核参数已设置并持久化${PLAIN}"
}

manage_swap_and_kernel() {
    while true; do
        echo -e "\n${BLUE}━━━ Swap与内核管理 ━━━${PLAIN}"
        echo ""
        echo "当前 Swap 状态:"
        swapon --show 2>/dev/null || echo "  (未启用)"
        echo ""
        echo "1) 创建/设置 Swap 空间"
        echo "2) 删除 Swap 空间"
        echo "3) 设置内核参数 (swappiness等)"
        echo "4) 返回主菜单"
        echo ""
        read -rp "选择操作: " choice

        case $choice in
            1) create_swap_space ;;
            2) delete_swap_space ;;
            3) set_kernel_parameters ;;
            4) break ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        
        read -n 1 -s -r -p "按任意键继续..."
    done
}

#==============================================================================
# 功能模块 3: 系统极限精简
#==============================================================================

system_streamline() {
    local start_disk_usage end_disk_usage space_freed
    local actions_taken=()

    start_disk_usage=$(df -k / 2>/dev/null | awk 'NR==2 {print $3}')

    log_action() { actions_taken+=("$1"); }

    disable_service_safe() {
        local service_name="$1"
        if systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}"; then
            systemctl stop "${service_name}" >/dev/null 2>&1
            systemctl disable "${service_name}" >/dev/null 2>&1 && log_action "禁用服务: ${service_name}"
        fi
    }

    echo -e "\n${YELLOW}=========== 系统极限精简开始 ===========${PLAIN}"
    echo -e "${RED}警告: 此操作将删除文档、清理缓存并禁用非必要服务${PLAIN}"
    echo ""

    # 1. APT 清理
    if command -v apt-get &>/dev/null; then
        echo "  → 清理 APT 缓存..."
        apt-get clean >/dev/null 2>&1
        apt-get autoremove --purge -y >/dev/null 2>&1
        rm -rf /var/lib/apt/lists/* 2>/dev/null
        log_action "清理 APT 缓存和遗留包"
    fi

    # 2. 清理系统文档
    echo "  → 清理系统文档..."
    if [ -d "/usr/share/doc" ]; then
        rm -rf /usr/share/doc/* 2>/dev/null && log_action "移除 /usr/share/doc"
    fi
    if [ -d "/usr/share/man" ]; then
        rm -rf /usr/share/man/* 2>/dev/null && log_action "移除 /usr/share/man"
    fi
    if [ -d "/usr/share/locale" ]; then
        # 保留英文和中文
        find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
            ! -name 'en*' ! -name 'zh*' -exec rm -rf {} \; 2>/dev/null
        log_action "清理多余语言包"
    fi

    # 3. 清理日志
    echo "  → 清理系统日志..."
    journalctl --rotate >/dev/null 2>&1
    journalctl --vacuum-time=1s >/dev/null 2>&1
    find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) -delete 2>/dev/null
    # 清空但保留文件
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
    log_action "清理系统日志"

    # 4. 禁用非核心服务（保留 systemd-tmpfiles-clean.timer）
    echo "  → 禁用非核心服务..."
    local services_to_disable=(
        "apt-daily.timer"
        "apt-daily-upgrade.timer"
        "unattended-upgrades.service"
        "man-db.timer"
        "e2scrub_reap.service"
        "e2scrub_all.timer"
        "fstrim.timer"
    )
    # 注意：故意不禁用 systemd-tmpfiles-clean.timer，防止临时文件填满磁盘

    for service in "${services_to_disable[@]}"; do
        disable_service_safe "$service"
    done

    # 5. 清理临时文件
    echo "  → 清理临时文件..."
    rm -rf /tmp/* /var/tmp/* 2>/dev/null
    log_action "清理临时文件"

    # 计算释放空间
    sync
    end_disk_usage=$(df -k / 2>/dev/null | awk 'NR==2 {print $3}')
    space_freed=$(( (start_disk_usage - end_disk_usage) / 1024 ))
    [ "$space_freed" -lt 0 ] && space_freed=0

    echo -e "\n${GREEN}=========== 精简完成 ===========${PLAIN}"
    echo "执行的操作:"
    for action in "${actions_taken[@]}"; do
        echo -e "  ${GREEN}✓${PLAIN} ${action}"
    done
    echo ""
    echo -e "释放空间: ${GREEN}${space_freed} MB${PLAIN}"
    echo "=================================="
}

#==============================================================================
# 功能模块 4: DNS配置管理
#==============================================================================

# DNS 预设
DNS_COMMON="nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888"
DNS_DNS64="nameserver 2606:4700:4700::64\nnameserver 2001:4860:4860::64"
DNS_TAIWAN="nameserver 168.95.1.1\nnameserver 2001:b000:168::1\nnameserver 129.250.35.250\nnameserver 2001:2f8:0:1::2:3"
DNS_ALIYUN="nameserver 223.5.5.5\nnameserver 223.6.6.6\nnameserver 2400:3200::1\nnameserver 2400:3200:baba::1"

set_dns() {
    local dns_content="$1"

    # 检查 resolv.conf 是否为符号链接
    if [ -L /etc/resolv.conf ]; then
        echo -e "${YELLOW}注意: /etc/resolv.conf 是符号链接${PLAIN}"
        local link_target
        link_target=$(readlink -f /etc/resolv.conf)
        echo "链接目标: $link_target"
        read -rp "是否解除链接并直接写入? (y/N): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            rm -f /etc/resolv.conf
        else
            echo "保持链接，尝试写入..."
        fi
    fi

    echo -e "$dns_content" > /etc/resolv.conf
    echo -e "${GREEN}✓ DNS 已更新${PLAIN}"
    echo "当前配置:"
    cat /etc/resolv.conf
}

manage_dns() {
    while true; do
        echo -e "\n${BLUE}━━━ DNS配置管理 ━━━${PLAIN}"
        echo ""
        echo "当前 DNS 配置:"
        echo "────────────────────"
        cat /etc/resolv.conf 2>/dev/null | grep -E "^nameserver" || echo "  (无配置)"
        echo "────────────────────"
        echo ""
        echo "预设选项:"
        echo "1) 通用 DNS (Cloudflare + Google)"
        echo "2) DNS64 (仅 IPv6 网络使用)"
        echo "3) 台湾 DNS (HiNet + NTT)"
        echo "4) 阿里 DNS"
        echo "5) 自定义 DNS"
        echo ""
        echo "自动化:"
        echo "6) 添加开机自动设置 DNS 任务"
        echo "7) 删除开机自动设置 DNS 任务"
        echo ""
        echo "8) 返回主菜单"
        echo ""
        read -rp "选择: " dns_choice

        case $dns_choice in
            1) set_dns "$DNS_COMMON" ;;
            2) set_dns "$DNS_DNS64" ;;
            3) set_dns "$DNS_TAIWAN" ;;
            4) set_dns "$DNS_ALIYUN" ;;
            5)
                echo "请输入 DNS 服务器地址 (每行一个，输入空行结束):"
                local custom_dns=""
                while true; do
                    read -rp "nameserver: " dns_addr
                    [[ -z "$dns_addr" ]] && break
                    custom_dns+="nameserver $dns_addr\n"
                done
                if [[ -n "$custom_dns" ]]; then
                    set_dns "$custom_dns"
                fi
                ;;
            6)
                echo "选择要自动设置的 DNS:"
                echo "1) 通用 DNS  2) DNS64  3) 台湾 DNS  4) 阿里 DNS"
                read -rp "选择: " auto_dns_choice
                local dns_cmd=""
                case $auto_dns_choice in
                    1) dns_cmd="echo -e '$DNS_COMMON' > /etc/resolv.conf" ;;
                    2) dns_cmd="echo -e '$DNS_DNS64' > /etc/resolv.conf" ;;
                    3) dns_cmd="echo -e '$DNS_TAIWAN' > /etc/resolv.conf" ;;
                    4) dns_cmd="echo -e '$DNS_ALIYUN' > /etc/resolv.conf" ;;
                    *) echo "无效选择"; continue ;;
                esac
                add_smart_task "reboot" "" "$dns_cmd" "auto_dns_fix"
                ;;
            7)
                remove_smart_task "auto_dns_fix"
                ;;
            8) break ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        
        read -n 1 -s -r -p "按任意键继续..."
    done
}

#==============================================================================
# 功能模块 5: 计划任务管理
#==============================================================================

manage_crontab() {
    while true; do
        echo -e "\n${BLUE}━━━ 计划任务管理 ━━━${PLAIN}"

        show_all_tasks
        
        echo ""
        echo "可添加的预设任务:"
        echo "1) x-ui 保活 (每30分钟)"
        echo "2) x-ui 定时重启 (每天凌晨2点)"
        echo "3) 内存清理 (每天凌晨4点)"
        echo "4) 自定义任务"
        echo ""
        echo "管理操作:"
        echo "5) 删除指定任务"
        echo "6) 编辑任务 (仅Cron模式)"
        echo "7) 清空所有任务"
        echo ""
        echo "8) 返回主菜单"
        echo ""
        read -rp "选择: " cron_choice
        
        case $cron_choice in
            1)
                if [ -f "/usr/local/x-ui/goxui.sh" ]; then
                    add_smart_task "interval" "30min" "/usr/local/x-ui/goxui.sh" "xui_keepalive"
                else
                    echo -e "${YELLOW}未找到 x-ui 保活脚本，尝试使用 systemctl restart${PLAIN}"
                    add_smart_task "interval" "30min" "systemctl restart x-ui" "xui_keepalive"
                fi
                ;;
            2)
                add_smart_task "daily" "02:00" "systemctl restart x-ui" "xui_daily_restart"
                ;;
            3)
                add_smart_task "daily" "04:00" "sync; echo 3 > /proc/sys/vm/drop_caches" "memory_clean"
                ;;
            4)
                echo "任务类型: 1) 开机执行  2) 每日定时  3) 间隔执行"
                read -rp "选择类型: " task_type_choice
                
                local task_type timing
                case $task_type_choice in
                    1) task_type="reboot"; timing="" ;;
                    2) 
                        task_type="daily"
                        read -rp "执行时间 (格式 HH:MM，如 04:00): " timing
                        ;;
                    3)
                        task_type="interval"
                        read -rp "执行间隔 (如 10min, 1h): " timing
                        ;;
                    *) echo "无效选择"; continue ;;
                esac
                
                read -rp "执行命令: " custom_cmd
                read -rp "任务标识 (用于管理): " task_id
                
                if [[ -n "$custom_cmd" && -n "$task_id" ]]; then
                    # 清理标识中的特殊字符
                    task_id=$(echo "$task_id" | tr -cd 'a-zA-Z0-9_-')
                    add_smart_task "$task_type" "$timing" "$custom_cmd" "$task_id"
                else
                    echo -e "${RED}命令和标识不能为空${PLAIN}"
                fi
                ;;
            5)
                read -rp "输入要删除的任务标识: " del_task_id
                if [[ -n "$del_task_id" ]]; then
                    remove_smart_task "$del_task_id"
                fi
                ;;
            6)
                if [ "$HAS_CRON" = true ]; then
                    crontab -e
                else
                    echo -e "${YELLOW}当前使用 Systemd Timer 模式，请直接编辑 ${SYSTEMD_DIR}/*.timer${PLAIN}"
                fi
                ;;
            7)
                read -rp "确认清空所有计划任务? (y/N): " confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    if [ "$HAS_CRON" = true ]; then
                        crontab -r 2>/dev/null
                        echo -e "${GREEN}✓ 已清空 Cron 任务${PLAIN}"
                    else
                        # 删除所有 opt_ 开头的 timer
                        for timer in "${SYSTEMD_DIR}"/opt_*.timer; do
                            if [ -f "$timer" ]; then
                                local name
                                name=$(basename "$timer" .timer)
                                systemctl disable --now "${name}.timer" >/dev/null 2>&1
                                rm -f "${SYSTEMD_DIR}/${name}.service" "${SYSTEMD_DIR}/${name}.timer"
                            fi
                        done
                        systemctl daemon-reload >/dev/null 2>&1
                        echo -e "${GREEN}✓ 已清空 Systemd Timer 任务${PLAIN}"
                    fi
                fi
                ;;
            8) break ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        
        read -n 1 -s -r -p "按任意键继续..."
    done
}

#==============================================================================
# 功能模块 6: x-ui 和 WARP 极致优化
#==============================================================================

detect_xui() {
    local xui_db_path=""

    # 检测 x-ui 服务
    if pgrep -f "x-ui" >/dev/null 2>&1 || \
       systemctl is-active --quiet x-ui 2>/dev/null || \
       [ -f "/usr/local/x-ui/bin/x-ui" ] || \
       [ -f "/usr/local/x-ui/x-ui" ]; then
        
        # 查找数据库路径
        if [ -f "/etc/x-ui/x-ui.db" ]; then
            xui_db_path="/etc/x-ui/x-ui.db"
        elif [ -f "/etc/x-ui-yg/x-ui-yg.db" ]; then
            xui_db_path="/etc/x-ui-yg/x-ui-yg.db"
        fi
        
        echo "$xui_db_path"
        return 0
    fi

    return 1
}

detect_warp() {
    # 检测 WARP 相关服务和接口
    if ip link show 2>/dev/null | grep -qE "wgcf|warp|CloudflareWARP" ||
       pgrep -f "warp-svc" >/dev/null 2>&1 ||
       pgrep -f "warp-go" >/dev/null 2>&1 ||
       systemctl is-active --quiet warp-svc 2>/dev/null ||
       systemctl is-active --quiet warp-go 2>/dev/null ||
       systemctl is-active --quiet wg-quick@wgcf 2>/dev/null; then
        return 0
    fi
    return 1
}

generate_reset_script() {
    local has_xui="$1"
    local has_warp="$2"
    local db_path="$3"
    local db_name=""
    local db_backup_path=""

    if [ -n "$db_path" ]; then
        db_name=$(basename "$db_path")
        db_backup_path="${db_path}.backup"
    fi

    cat > "${SCRIPT_DIR}/reset_ram_state.sh" <<'SCRIPT_EOF'
#!/bin/bash
#==============================================================================
# 内存状态重置脚本 (自动生成)
# 功能: 重启服务、恢复内存数据库、清理缓存
#==============================================================================

LOG_TAG="[RAM-RESET]"
log() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') $1"; }

log "Starting RAM reset..."

# 创建锁文件防止并发执行
LOCK_FILE="/tmp/reset_ram_state.lock"
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
        log "Another instance is running (PID: $pid), exiting."
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

SCRIPT_EOF

    # 添加停止服务的逻辑
    if [ "$has_xui" = true ]; then
        cat >> "${SCRIPT_DIR}/reset_ram_state.sh" <<'EOF'

# 停止 x-ui
log "Stopping x-ui..."
systemctl stop x-ui 2>/dev/null
EOF
    fi

    if [ "$has_warp" = true ]; then
        cat >> "${SCRIPT_DIR}/reset_ram_state.sh" <<'EOF'

# 停止 WARP 相关服务
log "Stopping WARP services..."
systemctl stop warp-go 2>/dev/null
systemctl stop wg-quick@wgcf 2>/dev/null
systemctl stop warp-svc 2>/dev/null
pkill -f "WARP-UP.sh" 2>/dev/null
screen -wipe 2>/dev/null
EOF
    fi

    # 添加数据库恢复逻辑
    if [ -n "$db_path" ]; then
        cat >> "${SCRIPT_DIR}/reset_ram_state.sh" <<EOF

# 恢复 x-ui 数据库到内存
log "Restoring database to RAM..."
DB_PATH="$db_path"
DB_NAME="$db_name"
DB_BACKUP="$db_backup_path"

if [ -f "\$DB_BACKUP" ]; then
    cp -f "\$DB_BACKUP" "/dev/shm/\$DB_NAME"
    log "Database restored: \$DB_NAME"
else
    log "Warning: Backup not found at \$DB_BACKUP"
fi
EOF
    fi

    # 添加清理和恢复逻辑
    cat >> "${SCRIPT_DIR}/reset_ram_state.sh" <<'EOF'

# 重建必要的日志目录
log "Rebuilding log directories..."
mkdir -p /var/log/journal 2>/dev/null
chmod 755 /var/log 2>/dev/null

# 清理内存缓存
log "Dropping caches..."
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

# 清理旧日志
journalctl --vacuum-time=1s >/dev/null 2>&1
EOF

    # 添加启动服务的逻辑
    if [ "$has_warp" = true ]; then
        cat >> "${SCRIPT_DIR}/reset_ram_state.sh" <<'EOF'

# 启动 WARP 服务（先于 x-ui，因为可能需要网络）
log "Starting WARP services..."
systemctl start warp-go 2>/dev/null
systemctl start wg-quick@wgcf 2>/dev/null
systemctl start warp-svc 2>/dev/null
sleep 3

# 触发刷 IP 脚本（如果存在）
if [ -f "/root/WARP-UP.sh" ] && command -v screen >/dev/null 2>&1; then
    log "Starting WARP-UP.sh in screen..."
    screen -UdmS warp_up /bin/bash -c "/root/WARP-UP.sh >/dev/null 2>&1"
fi
EOF
    fi

    if [ "$has_xui" = true ]; then
        cat >> "${SCRIPT_DIR}/reset_ram_state.sh" <<'EOF'

# 启动 x-ui
log "Starting x-ui..."
systemctl start x-ui 2>/dev/null
EOF
    fi

    # 添加结束日志
    cat >> "${SCRIPT_DIR}/reset_ram_state.sh" <<'EOF'

log "RAM reset completed."
EOF

    chmod +x "${SCRIPT_DIR}/reset_ram_state.sh"
}

generate_watchdog_script() {
    local threshold="${1:-88}"

    cat > "${SCRIPT_DIR}/check_memory.sh" <<EOF
#!/bin/bash
#==============================================================================
# 内存看门狗脚本 (自动生成)
# 功能: 内存使用超过阈值时自动触发清洗
#==============================================================================

THRESHOLD=$threshold
LOCK_FILE="/tmp/check_memory.lock"

# 防止并发
if [ -f "\$LOCK_FILE" ]; then
    pid=\$(cat "\$LOCK_FILE" 2>/dev/null)
    if kill -0 "\$pid" 2>/dev/null; then
        exit 0
    fi
fi
echo \$\$ > "\$LOCK_FILE"
trap "rm -f \$LOCK_FILE" EXIT

# 获取内存使用率
mem_info=\$(free | grep Mem)
mem_total=\$(echo "\$mem_info" | awk '{print \$2}')
mem_used=\$(echo "\$mem_info" | awk '{print \$3}')
mem_percent=\$((mem_used * 100 / mem_total))

if [ "\$mem_percent" -gt "\$THRESHOLD" ]; then
    echo "[WATCHDOG] Memory usage \${mem_percent}% > \${THRESHOLD}%, triggering reset..."
    ${SCRIPT_DIR}/reset_ram_state.sh
fi
EOF

    chmod +x "${SCRIPT_DIR}/check_memory.sh"
}

optimize_xui_warp() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║           x-ui 和 WARP 极致优化 (智能适配版)                 ║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${PLAIN}"
    echo ""
    echo "此模式将自动完成以下操作:"
    echo ""
    echo -e "  ${GREEN}[系统优化]${PLAIN}"
    echo "  ├─ 关闭 Swap (防止磁盘过度写入)"
    echo "  ├─ 配置日志为内存模式 (journald volatile)"
    echo "  └─ WARP 日志重定向到黑洞"
    echo ""
    echo -e "  ${GREEN}[x-ui 优化]${PLAIN}"
    echo "  ├─ 数据库迁移到内存 (/dev/shm)"
    echo "  └─ 创建数据库备份用于自动恢复"
    echo ""
    echo -e "  ${GREEN}[自动化脚本]${PLAIN}"
    echo "  ├─ reset_ram_state.sh (每日清洗 + 开机恢复)"
    echo "  └─ check_memory.sh (内存看门狗)"
    echo ""
    echo -e "  ${GREEN}[计划任务]${PLAIN} (自动添加，防止重复)"
    echo "  ├─ 开机: 执行清洗脚本"
    echo "  ├─ 开机: 修改 DNS"
    echo "  ├─ 每天 04:00: 执行清洗"
    echo "  └─ 每 10 分钟: 内存检查"
    echo ""

    read -rp "确认执行完整优化? (y/N): " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && echo "已取消" && return

    echo ""
    echo -e "${GREEN}[1/7] 检测软件环境...${PLAIN}"

    local has_xui=false
    local has_warp=false
    local xui_db_path=""

    # 检测 x-ui
    xui_db_path=$(detect_xui)
    if [ $? -eq 0 ]; then
        has_xui=true
        echo -e "  ${GREEN}✓${PLAIN} 检测到 x-ui"
        [ -n "$xui_db_path" ] && echo -e "    数据库: $xui_db_path"
    else
        echo -e "  ${YELLOW}○${PLAIN} 未检测到 x-ui"
    fi

    # 检测 WARP
    if detect_warp; then
        has_warp=true
        echo -e "  ${GREEN}✓${PLAIN} 检测到 WARP/WireGuard"
    else
        echo -e "  ${YELLOW}○${PLAIN} 未检测到 WARP"
    fi

    # ==================== 关闭 Swap ====================
    echo -e "\n${GREEN}[2/7] 关闭 Swap...${PLAIN}"
    swapoff -a 2>/dev/null
    sed -i '/swap/s/^/#/' /etc/fstab 2>/dev/null
    # 尝试删除 swapfile
    for sf in /swapfile /swap.img; do
        [ -f "$sf" ] && rm -f "$sf" 2>/dev/null
    done
    echo -e "  ${GREEN}✓${PLAIN} Swap 已关闭"

    # ==================== 日志内存化 ====================
    echo -e "\n${GREEN}[3/7] 配置日志内存模式...${PLAIN}"

    if [ -f /etc/systemd/journald.conf ]; then
        # 备份原配置
        cp -f /etc/systemd/journald.conf /etc/systemd/journald.conf.bak 2>/dev/null
        
        # 使用 sed 安全修改（先删除旧配置再添加新配置）
        sed -i '/^Storage=/d; /^RuntimeMaxUse=/d; /^SystemMaxUse=/d' /etc/systemd/journald.conf
        
        # 添加新配置
        cat >> /etc/systemd/journald.conf <<EOF

# 优化配置 (自动生成)
Storage=volatile
RuntimeMaxUse=16M
EOF

        systemctl restart systemd-journald >/dev/null 2>&1
        echo -e "  ${GREEN}✓${PLAIN} 日志已配置为内存模式 (最大 16M)"
    else
        echo -e "  ${YELLOW}○${PLAIN} 未找到 journald.conf，跳过"
    fi

    # WARP 日志黑洞
    if [ "$has_warp" = true ]; then
        # 停止可能正在写日志的进程
        pkill -f "WARP-UP.sh" 2>/dev/null
        
        if [ -d "/root/warpip" ]; then
            rm -f /root/warpip/warp_log.txt 2>/dev/null
            ln -sf /dev/null /root/warpip/warp_log.txt 2>/dev/null
            echo -e "  ${GREEN}✓${PLAIN} WARP 日志已重定向到黑洞"
        fi
    fi

    # ==================== x-ui 数据库内存化 ====================
    echo -e "\n${GREEN}[4/7] 迁移 x-ui 数据库...${PLAIN}"

    if [ "$has_xui" = true ] && [ -n "$xui_db_path" ]; then
        local db_name db_backup_path
        db_name=$(basename "$xui_db_path")
        db_backup_path="${xui_db_path}.backup"
        
        # 检查是否已经是软链接
        if [ -L "$xui_db_path" ]; then
            echo -e "  ${YELLOW}○${PLAIN} 数据库已是软链接，跳过迁移"
        elif [ -f "$xui_db_path" ]; then
            # 停止服务
            systemctl stop x-ui 2>/dev/null
            sleep 1
            
            # 备份并迁移
            cp -f "$xui_db_path" "$db_backup_path"
            mv "$xui_db_path" "/dev/shm/${db_name}"
            ln -sf "/dev/shm/${db_name}" "$xui_db_path"
            
            # 重启服务
            systemctl start x-ui 2>/dev/null
            
            echo -e "  ${GREEN}✓${PLAIN} 数据库已迁移到 /dev/shm/"
            echo -e "  ${GREEN}✓${PLAIN} 备份已保存: $db_backup_path"
        else
            echo -e "  ${YELLOW}○${PLAIN} 数据库文件不存在"
        fi
    else
        echo -e "  ${YELLOW}○${PLAIN} 跳过 (未检测到 x-ui 或数据库)"
    fi

    # ==================== 生成脚本 ====================
    echo -e "\n${GREEN}[5/7] 生成自动化脚本...${PLAIN}"

    generate_reset_script "$has_xui" "$has_warp" "$xui_db_path"
    echo -e "  ${GREEN}✓${PLAIN} 创建 ${SCRIPT_DIR}/reset_ram_state.sh"

    generate_watchdog_script 88
    echo -e "  ${GREEN}✓${PLAIN} 创建 ${SCRIPT_DIR}/check_memory.sh"

    # ==================== 配置计划任务 ====================
    echo -e "\n${GREEN}[6/7] 配置计划任务...${PLAIN}"

    # 备份当前任务
    if [ "$HAS_CRON" = true ]; then
        crontab -l > "/root/crontab_backup_$(date +%Y%m%d%H%M%S).txt" 2>/dev/null
    fi

    # 任务 1: 开机执行清洗脚本
    add_smart_task "reboot" "" "${SCRIPT_DIR}/reset_ram_state.sh" "opt_reset_boot"

    # 任务 2: 开机修改 DNS
    add_smart_task "reboot" "" "echo -e '$DNS_COMMON' > /etc/resolv.conf" "opt_dns_boot"

    # 任务 3: 每天凌晨4点清洗
    add_smart_task "daily" "04:00" "${SCRIPT_DIR}/reset_ram_state.sh" "opt_daily_reset"

    # 任务 4: 每10分钟内存检查
    add_smart_task "interval" "10min" "${SCRIPT_DIR}/check_memory.sh" "opt_mem_watchdog"

    # 任务 5: WARP 日志黑洞保险
    if [ "$has_warp" = true ] && [ -d "/root/warpip" ]; then
        add_smart_task "daily" "00:00" "ln -sf /dev/null /root/warpip/warp_log.txt" "opt_warp_log"
    fi

    # ==================== 安装 screen (如果需要) ====================
    echo -e "\n${GREEN}[7/7] 检查依赖...${PLAIN}"

    if [ "$has_warp" = true ] && [ -f "/root/WARP-UP.sh" ]; then
        if ! command -v screen >/dev/null 2>&1; then
            echo -e "  ${YELLOW}○${PLAIN} WARP-UP.sh 需要 screen，正在安装..."
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update >/dev/null 2>&1 && apt-get install -y screen >/dev/null 2>&1
            elif command -v yum >/dev/null 2>&1; then
                yum install -y screen >/dev/null 2>&1
            fi
            
            if command -v screen >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓${PLAIN} screen 已安装"
            else
                echo -e "  ${RED}✗${PLAIN} screen 安装失败，WARP-UP.sh 可能无法后台运行"
            fi
        else
            echo -e "  ${GREEN}✓${PLAIN} screen 已存在"
        fi
    else
        echo -e "  ${GREEN}✓${PLAIN} 无额外依赖"
    fi

    # ==================== 完成总结 ====================
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${GREEN}║                    极致优化配置完成！                        ║${PLAIN}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${PLAIN}"
    echo ""
    echo "已完成的配置:"
    echo -e "  ${GREEN}✓${PLAIN} Swap 已关闭"
    echo -e "  ${GREEN}✓${PLAIN} 系统日志使用内存存储"
    [ "$has_warp" = true ] && echo -e "  ${GREEN}✓${PLAIN} WARP 日志已黑洞化"
    [ "$has_xui" = true ] && [ -n "$xui_db_path" ] && echo -e "  ${GREEN}✓${PLAIN} x-ui 数据库已内存化"
    echo -e "  ${GREEN}✓${PLAIN} 清洗脚本已创建"
    echo -e "  ${GREEN}✓${PLAIN} 看门狗脚本已创建"
    echo -e "  ${GREEN}✓${PLAIN} 计划任务已配置"
    echo ""
    echo "当前计划任务:"
    echo "────────────────────────────────────────"
    if [ "$HAS_CRON" = true ]; then
        crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | head -10
    else
        systemctl list-timers --no-pager 2>/dev/null | grep "opt_" | head -10
    fi
    echo "────────────────────────────────────────"
    echo ""

    read -rp "是否立即重启系统以使所有更改生效? (y/N): " reboot_opt
    if [[ "$reboot_opt" =~ ^[yY]$ ]]; then
        echo "正在重启..."
        sleep 2
        reboot
    else
        echo -e "${YELLOW}请稍后手动重启系统以使更改完全生效 (命令: reboot)${PLAIN}"
    fi
}

#==============================================================================
# 主菜单
#==============================================================================

main_menu() {
    check_root
    init_environment

    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${PLAIN}"
        echo -e "${CYAN}║           Linux 系统工具箱 (综合优化版 v2.0)                 ║${PLAIN}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${PLAIN}"
        echo -e "${CYAN}║${PLAIN}  环境: $([ "$IS_LXC" = true ] && echo "${YELLOW}LXC容器${PLAIN}" || echo "物理机/VM") | 调度: $([ "$HAS_CRON" = true ] && echo "${GREEN}Cron${PLAIN}" || echo "${GREEN}Systemd Timer${PLAIN}")               ${CYAN}║${PLAIN}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${PLAIN}"
        echo ""
        echo "  1) 显示系统和 IP 信息"
        echo "  2) 管理 Swap 空间与内核参数"
        echo "  3) 执行系统极限精简 (慎用)"
        echo "  4) DNS 配置管理"
        echo "  5) 计划任务管理 (Cron/Timer)"
        echo ""
        echo -e "  ${GREEN}6) x-ui 和 WARP 极致优化 (一键配置)${PLAIN}"
        echo ""
        echo "  7) 退出"
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        read -rp "请输入选项 [1-7]: " main_choice

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
                echo -e "${RED}警告：此操作将删除系统文档、清理缓存并禁用非核心服务！${PLAIN}"
                read -rp "确认继续? (y/N): " confirm
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
                echo ""
                echo "感谢使用，再见！"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请输入 1-7 之间的数字${PLAIN}"
                ;;
        esac
        
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

#==============================================================================
# 脚本入口
#==============================================================================

main_menu
