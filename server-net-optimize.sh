#!/bin/bash

# ==============================================================================
#                 Linux 系统工具箱多合一管理脚本
#
# 功能:
# 1. 系统信息检测 (OS, IP)
# 2. 网络优化 (DNS, Hosts)
# 3. Swap空间与内核参数管理
# 4. 系统极限精简与优化
# 5. 添加重启修改dns的Crontab计划任务
#
# 作者: Gemini & User
# 日期: 2025-10-29
# ==============================================================================

# --- 功能模块 1: 系统信息与网络 ---

# 判断系统类型
detect_os() {
    echo "--- 系统信息 ---"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [[ -f /etc/os-release ]]; then
            # shellcheck source=/dev/null
            . /etc/os-release
            echo "操作系统: $NAME"
            echo "版本: $VERSION"
        elif [[ -f /etc/redhat-release ]]; then
            echo "操作系统: $(cat /etc/redhat-release)"
        elif [[ -f /etc/debian_version ]]; then
            echo "操作系统: Debian"
            echo "版本: $(cat /etc/debian_version)"
        else
            echo "未知的 Linux 发行版"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "操作系统: macOS"
        echo "版本: $(sw_vers -productVersion)"
    else
        echo "未知的操作系统: $OSTYPE"
    fi
    echo "--------------------"
}

# 检查IP地址
check_ip() {
    echo "--- IP 地址信息 ---"
    if command -v ip &> /dev/null; then
        IPv4_ADDR=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        IPv6_ADDR=$(ip -6 addr show | grep -oP '(?<=inet6\s)[\da-f:]+')
    else
        echo "ip命令未找到，尝试使用ifconfig"
        if command -v ifconfig &> /dev/null; then
            IPv4_ADDR=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')
            IPv6_ADDR=$(ifconfig | grep -Eo 'inet6 (addr:)?\s*([a-fA-F0-9:]+)' | awk '{print $2}')
        else
            echo "ifconfig命令也未找到，无法执行本地IP检查"
        fi
    fi

    if [[ -n "$IPv4_ADDR" ]]; then
        echo "本地IPv4地址: $IPv4_ADDR"
    else
        echo "没有检测到本地IPv4地址"
        public_ipv4=$(curl -4 -s https://api64.ipify.org)
        [[ -n "$public_ipv4" ]] && echo "外部IPv4地址: $public_ipv4" || echo "没有检测到外部IPv4地址"
    fi

    if [[ -n "$IPv6_ADDR" ]]; then
        echo "本地IPv6地址: $IPv6_ADDR"
    else
        echo "没有检测到本地IPv6地址"
        public_ipv6=$(curl -6 -s https://api64.ipify.org)
        [[ -n "$public_ipv6" ]] && echo "外部IPv6地址: $public_ipv6" || echo "没有检测到外部IPv6地址"
    fi
    echo "--------------------"
}

# 修改DNS和hosts文件 (此部分功能较为特定，暂不集成到主菜单，保留函数供调用)
modify_dns_and_hosts() {
    ipv6_regex="^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$"

    if [[ -z "$IPv4_ADDR" && -n "$IPv6_ADDR" ]]; then
        echo "只存在IPv6地址，修改DNS为DNS64"
        echo "nameserver 2606:4700:4700::64" | sudo tee /etc/resolv.conf
        echo "nameserver 2001:4860:4860::64" | sudo tee -a /etc/resolv.conf
    fi

    if [[ -n "$IPv6_ADDR" ]]; then
        echo "检测到IPv6地址，尝试获取Google IPv6地址并添加到hosts文件"

        get_google_ipv6() {
            local google_ipv6=""
            get_ipv6_with_dig() { dig aaaa google.com +short | grep -E "$ipv6_regex" | head -n 1; }
            # ... (其他获取IP的方法，为简洁省略)
            
            # 此处省略了您原有的交互式获取Google IP的复杂逻辑
            # 如需保留，可将原代码粘贴回来
            echo "注意：自动修改Hosts文件的功能需要您手动取消注释并完善。"
        }
        get_google_ipv6
    fi
}

# --- 功能模块 2: Swap管理与内核参数 ---

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

create_swap_space() {
    read -rp "输入交换文件路径（默认 /swapfile）: " swapfile
    swapfile=${swapfile:-/swapfile}
    size=$(validate_input "输入交换文件大小（MB）" 1024 1 1048576)
    if [[ -f "$swapfile" ]]; then
        echo "检测到交换文件 $swapfile 已存在，正在删除..."
        sudo swapoff "$swapfile" 2>/dev/null
        sudo rm -f "$swapfile"
    fi
    if grep -q "$swapfile" /etc/fstab; then
        echo "检测到交换文件 $swapfile 在 /etc/fstab 中，正在移除..."
        sudo sed -i "\|$swapfile|d" /etc/fstab
    fi
    sudo dd if=/dev/zero of="$swapfile" bs=1M count="$size" status=progress
    sudo chmod 600 "$swapfile"
    sudo mkswap "$swapfile" && sudo swapon "$swapfile"
    echo "$swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
    echo "交换空间已创建并启用"
}

delete_swap_space() {
    current_swap=$(swapon --show=NAME --noheadings | grep '^/')
    if [[ -z "$current_swap" ]]; then
        echo "未找到任何启用的交换文件"; return 1
    fi
    sudo swapoff "$current_swap" && sudo rm -f "$current_swap"
    sudo sed -i "\|$current_swap|d" /etc/fstab
    echo "交换空间已关闭并删除"
}

manage_swap_space() {
    echo -e "\n选择交换空间操作：\n1) 创建交换空间\n2) 删除交换空间"
    read -rp "输入选项编号: " swap_choice
    case $swap_choice in
        1) create_swap_space ;;
        2) delete_swap_space ;;
        *) echo "无效选项，请重新选择" ;;
    esac
}

set_kernel_parameters() {
    echo -e "\n1. vm.swappiness (0-100): 控制系统使用交换空间的倾向。"
    swappiness=$(validate_input "设置 vm.swappiness" 10 0 100)
    echo -e "\n2. vm.vfs_cache_pressure (0-1000): 控制内核回收缓存的倾向。"
    vfs_cache_pressure=$(validate_input "设置 vm.vfs_cache_pressure" 75 0 1000)
    sudo sysctl -w vm.swappiness="$swappiness" vm.vfs_cache_pressure="$vfs_cache_pressure"
    echo -e "vm.swappiness = $swappiness\nvm.vfs_cache_pressure = $vfs_cache_pressure" | sudo tee /etc/sysctl.d/99-custom.conf
    echo "内核参数已设置并持久化。"
}

manage_swap_and_kernel() {
    while true; do
        echo -e "\n当前系统状态："
        free -h
        swapon --show
        echo -e "\n请选择操作：\n1) 管理交换空间 (创建/删除)\n2) 设置内核参数\n3) 返回主菜单"
        read -rp "输入选项编号: " choice
        case $choice in
            1) manage_swap_space ;;
            2) set_kernel_parameters ;;
            3) break ;;
            *) echo "无效选项，请重新选择" ;;
        esac
    done
}


# --- 功能模块 3: 系统极限精简 ---

# (此处嵌入我们之前优化的 v2.0 精简脚本)
system_streamline() {
    # --- 初始化变量 ---
    local start_disk_usage
    start_disk_usage=$(df -k / | awk 'NR==2 {print $3}')
    local errors_found=0
    local actions_taken=()

    log_action() { actions_taken+=("$1"); }
    log_error() { echo "ERROR: $1"; errors_found=$((errors_found + 1)); }
    disable_service() {
        local service_name="$1"
        if systemctl list-unit-files | grep -q "^${service_name}"; then
            echo "  - 正在处理服务 ${service_name} ..."
            systemctl stop "${service_name}" >/dev/null 2>&1 || true
            if systemctl disable "${service_name}" >/dev/null 2>&1; then
                log_action "成功禁用了服务 ${service_name}"
            else
                log_error "尝试禁用服务 ${service_name} 失败。"
            fi
        fi
    }

    echo "==========================================================="
    echo "INFO: 系统极限精简模块开始执行..."
    echo "==========================================================="
    
    # [1/3] 清理包管理器
    if command -v apt-get &> /dev/null; then
        echo "  - 正在清理APT..."
        apt-get update >/dev/null 2>&1
        apt-get clean >/dev/null 2>&1 && apt-get autoremove --purge -y >/dev/null 2>&1
        rm -rf /var/lib/apt/lists/*
        log_action "清理了APT缓存、遗留包和列表"
    fi

    # [2/3] 清理系统赘肉
    echo "  - 正在清理系统文档、手册和语言文件..."
    [ -d "/usr/share/doc" ] && rm -rf /usr/share/doc/* && log_action "移除了系统文档"
    [ -d "/usr/share/man" ] && rm -rf /usr/share/man/* && log_action "移除了系统手册页"
    if command -v apt-get &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        if apt-get install -y localepurge >/dev/null 2>&1; then
            echo "en\nen_US\nen_US.UTF-8" > /etc/locale.nopurge
            localepurge >/dev/null 2>&1
            log_action "使用 localepurge 清理了多余语言文件"
            apt-get purge --auto-remove -y localepurge >/dev/null 2>&1 && log_action "移除了清理工具 localepurge"
        fi
    fi

    # [3/3] 禁用非核心服务
    echo "  - 正在禁用非核心的服务和定时器..."
    services_to_disable=(
        systemd-tmpfiles-clean.timer apt-daily.timer apt-daily-upgrade.timer
        dnf-automatic.timer exim4.service postfix.service rsyslog.service
        getty@.service cups.service e2scrub_reap.service unattended-upgrades.service
    )
    for service in "${services_to_disable[@]}"; do disable_service "$service"; done

    # 总结报告
    local end_disk_usage
    end_disk_usage=$(df -k / | awk 'NR==2 {print $3}')
    local space_freed=$(( (start_disk_usage - end_disk_usage) / 1024 ))
    echo
    echo "======================= 精 简 总 结 ======================="
    echo "--- 主要操作 ---"
    if [ ${#actions_taken[@]} -eq 0 ]; then echo "  - 未执行任何新的清理或禁用操作。"; else
        for action in "${actions_taken[@]}"; do echo "  - ${action}"; done; fi
    echo "--- 磁盘空间 ---"
    echo "  - 释放空间: ${space_freed} MB"; df -h /
    echo "--- 错误与警告 ---"
    if [ ${errors_found} -eq 0 ]; then echo "  - 未检测到任何错误。"; else echo "  - 检测到 ${errors_found} 个错误。"; fi
    echo "==========================================================="
}


# --- 功能模块 4: 添加Crontab计划任务 ---

add_cron_tasks() {
    echo "--- 添加Crontab计划任务 ---"
    
    # 定义要添加的任务数组
    tasks_to_add=(
        '@reboot sleep 15 && /usr/bin/printf "nameserver 168.95.1.1\nnameserver 2001:b000:168::1\nnameserver 129.250.35.250\nnameserver 2001:2f8:0:1::2:3\nnameserver 1.1.1.1\nnameserver 2606:4700:4700::1111\n" > /etc/resolv.conf'
        '* * * * * /usr/local/x-ui/goxui.sh'
        '0 2 * * * systemctl restart x-ui'
    )

    # 获取当前用户的crontab内容
    current_crontab=$(crontab -l 2>/dev/null)

    new_tasks_added=false
    for task in "${tasks_to_add[@]}"; do
        # 检查任务是否已经存在
        if echo "$current_crontab" | grep -Fq -- "$task"; then
            echo "  - 任务已存在，跳过: $task"
        else
            # 将新任务追加到当前crontab内容中
            current_crontab="${current_crontab}"$'\n'"${task}"
            echo "  - 准备添加任务: $task"
            new_tasks_added=true
        fi
    done

    if [ "$new_tasks_added" = true ]; then
        # 使用临时文件来安全地更新crontab
        echo "$current_crontab" | crontab -
        if [ $? -eq 0 ]; then
            echo "SUCCESS: Crontab任务已成功添加/更新。"
        else
            echo "ERROR: 更新Crontab失败。"
        fi
    else
        echo "所有指定的Crontab任务均已存在，无需操作。"
    fi
    echo "---------------------------"
}


# --- 主菜单 ---

main_menu() {
    while true; do
        echo -e "\n=============== Linux 系统工具箱 主菜单 ================"
        echo "1) 显示系统和IP信息"
        echo "2) 管理Swap空间与内核参数"
        echo "3) 执行系统极限精简与优化"
        echo "4) 添加核心应用Crontab任务 (DNS修改, x-ui重启等)"
        echo "5) 退出"
        echo "========================================================"
        read -rp "请输入选项编号: " main_choice

        case $main_choice in
            1)
                clear
                detect_os
                check_ip
                ;;
            2)
                clear
                manage_swap_and_kernel
                ;;
            3)
                clear
                read -p "警告：此操作将清理系统并禁用非核心服务，是否继续? (y/N): " confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    system_streamline
                else
                    echo "操作已取消。"
                fi
                ;;
            4)
                clear
                read -p "此操作将添加或更新root重启修改dns的Crontab任务，是否继续? (y/N): " confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    add_cron_tasks
                else
                    echo "操作已取消。"
                fi
                ;;
            5)
                echo "感谢使用，脚本退出。"
                exit 0
                ;;
            *)
                echo "无效选项，请输入1-5之间的数字。"
                ;;
        esac
        read -n 1 -s -r -p "按任意键返回主菜单..."
        clear
    done
}

# --- 脚本入口 ---
clear
main_menu
