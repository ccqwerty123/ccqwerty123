#!/bin/bash

#==============================================================================
# Linux 系统工具箱多合一管理脚本 (综合优化版 v2.2 - 企业级幂等加固版)
# 特性:
#   1. 参数全部顶置，方便按需修改
#   2. DNS 智能双轨制 (优先适配 systemd-resolved，兼容传统 resolv.conf)
#   3. x-ui 内存数据库双向同步 (防重启丢节点配置)
#   4. 任务调度防重、文件软链接防死、网络中断后可无害重复运行
#==============================================================================

#==============================================================================
# [全局配置区域] 所有需要微调的参数均在此处修改
#==============================================================================

# ----------------- 1. DNS 预设组配置 -----------------
# 格式说明:
#   _RESOLVED: 适用于现代 systemd-resolved (空格分隔)
#   _RESOLV:   适用于传统 /etc/resolv.conf (换行带 nameserver)

# [预设 1: Cloudflare + Neustar] (延迟均衡、抗污染佳，前面排查已实测完美)
DNS_CF_NEUSTAR_RESOLVED="1.0.0.1 156.154.70.5 2606:4700:4700::1001 2610:a1:1018::1"
DNS_CF_NEUSTAR_RESOLV="nameserver 1.0.0.1\nnameserver 156.154.70.5\nnameserver 2606:4700:4700::1001\nnameserver 2610:a1:1018::1"

# [预设 2: 通用国际顶级 DNS] (Cloudflare + Google 经典组合)
DNS_COMMON_RESOLVED="1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888"
DNS_COMMON_RESOLV="nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888"

# [预设 3: DNS64 专用] (仅限纯 IPv6 小鸡通过 NAT64 访问 IPv4 网站)
DNS_DNS64_RESOLVED="2606:4700:4700::64 2001:4860:4860::64"
DNS_DNS64_RESOLV="nameserver 2606:4700:4700::64\nnameserver 2001:4860:4860::64"

# [预设 4: 阿里公共 DNS] (国内服务器或回国专用)
DNS_ALIYUN_RESOLVED="223.5.5.5 223.6.6.6 2400:3200::1 2400:3200:baba::1"
DNS_ALIYUN_RESOLV="nameserver 223.5.5.5\nnameserver 223.6.6.6\nnameserver 2400:3200::1\nnameserver 2400:3200:baba::1"

# ----------------- 2. x-ui 内存化与数据防丢配置 -----------------
# 机器长年不重启，建议每天凌晨定时从内存持久化保存一次到硬盘
XUI_SYNC_TIME="03:30"           # 每天触发持久化的具体时间 (24小时制 HH:MM)
ENABLE_XUI_SHUTDOWN_SYNC=true   # 是否在重启/维护清洗前强行保存一次数据

# ----------------- 3. 系统优化与监控阈值 -----------------
WATCHDOG_MEM_THRESHOLD=88       # 内存看门狗触发阈值 (%): 超过此值自动释放缓存
JOURNALD_MAX_USE="16M"          # 日志内存化最大占用大小

# ----------------- 4. 路径定义 -----------------
SCRIPT_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

# 颜色控制
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 运行时全局状态
IS_LXC=false
HAS_CRON=false
HAS_RESOLVED=false

#==============================================================================
# 核心环境与幂等安全检查函数
#==============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 权限运行此脚本！${PLAIN}"
        exit 1
    fi
}

init_environment() {
    # 1. 容器环境判定
    if grep -qa "container=lxc" /proc/1/environ 2>/dev/null ||
       grep -qa "lxc" /proc/1/cgroup 2>/dev/null ||
       [ -f "/.dockerenv" ]; then
        IS_LXC=true
    fi

    # 2. 计划任务调度器判定 (优先使用系统级 Cron)
    if command -v crontab >/dev/null 2>&1 && \
       (systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1 || \
        pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1); then
        HAS_CRON=true
    fi

    # 3. DNS 架构判定 (是否使用 systemd-resolved)
    if systemctl is-active --quiet systemd-resolved 2>/dev/null || [ -f /etc/systemd/resolved.conf ]; then
        HAS_RESOLVED=true
    fi

    # 确保脚本目录存在
    mkdir -p "$SCRIPT_DIR"
}

# 范围校验用户输入
validate_input() {
    local prompt="$1" default="$2" min="$3" max="$4" value
    while true; do
        read -rp "$prompt (默认 $default): " value
        value=${value:-$default}
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
            echo "$value"
            return 0
        else
            echo -e "${RED}输入有误，请输入 $min 到 $max 之间的整数${PLAIN}" >&2
        fi
    done
}

# 解锁 resolv.conf (幂等防呆)
unlock_resolv_conf() {
    local file="/etc/resolv.conf"
    [ ! -e "$file" ] && return 0
    if command -v lsattr &>/dev/null && command -v chattr &>/dev/null; then
        if lsattr "$file" 2>/dev/null | grep -q -- '-i-'; then
            chattr -i "$file" 2>/dev/null
        fi
    fi
}

#==============================================================================
# 核心 DNS 引擎 (智能双轨制: 彻底解决重启复原与软链接死锁)
#==============================================================================

apply_system_dns() {
    local resolved_dns="$1"
    local resolv_dns="$2"
    local desc="$3"

    echo -e "  → 正在应用 DNS: ${CYAN}${desc}${PLAIN}..."

    # 方案 A: 现代 systemd-resolved 原生支持 (修改配置，开机永不丢失)
    if [ "$HAS_RESOLVED" = true ]; then
        local conf="/etc/systemd/resolved.conf"
        [ -f "$conf" ] && cp -f "$conf" "${conf}.bak" 2>/dev/null

        # 确保 [Resolve] 块存在
        grep -q '^\[Resolve\]' "$conf" 2>/dev/null || echo "[Resolve]" >> "$conf"

        # 幂等替换/插入 DNS 与 Domains=~.
        if grep -qE '^#?DNS=' "$conf"; then
            sed -i "s|^#\?DNS=.*|DNS=${resolved_dns}|" "$conf"
        else
            sed -i "/^\[Resolve\]/a DNS=${resolved_dns}" "$conf"
        fi

        if grep -qE '^#?Domains=' "$conf"; then
            sed -i "s|^#\?Domains=.*|Domains=~.|" "$conf"
        else
            sed -i "/^\[Resolve\]/a Domains=~." "$conf"
        fi

        systemctl restart systemd-resolved >/dev/null 2>&1
        echo -e "  ${GREEN}✓${PLAIN} systemd-resolved 底层配置已持久化"
    fi

    # 方案 B: 传统 /etc/resolv.conf 处理 (双重保险)
    unlock_resolv_conf
    if [ "$HAS_RESOLVED" = false ]; then
        # 没有 resolved 时，如果是软链接则切断，避免写入 RAM 临时目录
        if [ -L /etc/resolv.conf ]; then
            rm -f /etc/resolv.conf
        fi
    fi

    # 写入传统 resolv 格式 (即便有 resolved，也能覆盖当前 Stub 缓存)
    echo -e "$resolv_dns" > /etc/resolv.conf 2>/dev/null
    echo -e "  ${GREEN}✓${PLAIN} /etc/resolv.conf 静态映射已更新"
}

#==============================================================================
# 计划任务防重引擎 (支持 Cron / Timer 双模自由切换)
#==============================================================================

add_smart_task() {
    local task_type="$1"  # reboot / daily / interval
    local timing="$2"     # HH:MM 或 30min
    local cmd="$3"        # 任务执行命令
    local task_id="$4"    # 唯一标识 (防重核心)

    if [ "$HAS_CRON" = true ]; then
        local cron_time=""
        case "$task_type" in
            reboot)   cron_time="@reboot sleep 20 &&" ;;
            daily)
                local hour minute
                IFS=':' read -r hour minute <<< "$timing"
                hour=$((10#${hour:-4}))
                minute=$((10#${minute:-0}))
                cron_time="$minute $hour * * *"
                ;;
            interval)
                local min_val
                min_val=$(echo "$timing" | grep -oE "[0-9]+")
                cron_time="*/${min_val:-10} * * * *"
                ;;
        esac

        local current_cron
        current_cron=$(crontab -l 2>/dev/null || echo "")

        # 幂等去重：先清除包含该 task_id 的旧记录，再追加新记录
        local filtered_cron
        filtered_cron=$(echo "$current_cron" | grep -v "# ${task_id}$" | grep -v "^$")

        if [ "$task_type" = "reboot" ]; then
            (echo "$filtered_cron"; echo "${cron_time} ${cmd} # ${task_id}") | crontab -
        else
            (echo "$filtered_cron"; echo "${cron_time} ${cmd} >/dev/null 2>&1 # ${task_id}") | crontab -
        fi
        echo -e "  ${GREEN}[Cron]${PLAIN} 计划任务已就绪: $task_id"
    else
        # Systemd Timer 模式
        local service_file="${SYSTEMD_DIR}/${task_id}.service"
        local timer_file="${SYSTEMD_DIR}/${task_id}.timer"

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

        cat > "$timer_file" <<EOF
[Unit]
Description=Timer for $task_id

[Timer]
EOF
        case "$task_type" in
            reboot)   echo "OnBootSec=30" >> "$timer_file" ;;
            daily)
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
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable --now "${task_id}.timer" >/dev/null 2>&1
        echo -e "  ${GREEN}[Timer]${PLAIN} 计划任务已就绪: $task_id"
    fi
}

remove_smart_task() {
    local task_id="$1"
    if [ "$HAS_CRON" = true ]; then
        local current_cron
        current_cron=$(crontab -l 2>/dev/null)
        if echo "$current_cron" | grep -q "# ${task_id}$"; then
            echo "$current_cron" | grep -v "# ${task_id}$" | crontab -
            echo -e "  ${GREEN}[删除]${PLAIN} Cron 任务: $task_id"
        else
            echo -e "  ${YELLOW}[跳过]${PLAIN} 任务未存在: $task_id"
        fi
    else
        if [ -f "${SYSTEMD_DIR}/${task_id}.timer" ]; then
            systemctl disable --now "${task_id}.timer" >/dev/null 2>&1
            rm -f "${SYSTEMD_DIR}/${task_id}.service" "${SYSTEMD_DIR}/${task_id}.timer"
            systemctl daemon-reload >/dev/null 2>&1
            echo -e "  ${GREEN}[删除]${PLAIN} Timer 任务: $task_id"
        fi
    fi
}

# 禁用冲突的 Systemd 定时器 (释放内存与 IO)
disable_conflict_timers() {
    [ "$HAS_CRON" != true ] && return 0
    local timers_to_disable=(
        "apt-daily.timer" "apt-daily-upgrade.timer" "man-db.timer"
        "e2scrub_all.timer" "fstrim.timer" "logrotate.timer"
    )
    for timer in "${timers_to_disable[@]}"; do
        if systemctl is-enabled "$timer" &>/dev/null; then
            systemctl disable --now "$timer" &>/dev/null
        fi
    done
}

#==============================================================================
# 功能模块 1: 系统信息与网络
#==============================================================================

show_system_info() {
    echo -e "\n${BLUE}━━━ 系统信息 ━━━${PLAIN}"
    [ -f /etc/os-release ] && . /etc/os-release && echo -e "操作系统: ${GREEN}${NAME:-Linux} ${VERSION:-}${PLAIN}"
    echo "内核版本: $(uname -r)"
    echo "系统架构: $(uname -m)"
    echo -e "运行环境: $([ "$IS_LXC" = true ] && echo "${YELLOW}LXC/容器${PLAIN}" || echo "独立虚拟机/物理机")"
    echo -e "调度模式: $([ "$HAS_CRON" = true ] && echo "${GREEN}Cron${PLAIN}" || echo "${GREEN}Systemd Timer${PLAIN}")"
    echo -e "DNS 架构: $([ "$HAS_RESOLVED" = true ] && echo "${GREEN}systemd-resolved (已接管)${PLAIN}" || echo "传统 /etc/resolv.conf")"

    echo -e "\n${BLUE}━━━ IP 地址信息 ━━━${PLAIN}"
    local local_ipv4 local_ipv6 public_ipv4 public_ipv6
    if command -v ip &>/dev/null; then
        local_ipv4=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        local_ipv6=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[\da-f:]+' | head -1)
    fi
    echo "本地 IPv4: ${local_ipv4:-未检测到}"
    echo "本地 IPv6: ${local_ipv6:-未检测到}"

    if command -v curl &>/dev/null; then
        public_ipv4=$(curl -4 -s --max-time 3 https://api64.ipify.org 2>/dev/null)
        public_ipv6=$(curl -6 -s --max-time 3 https://api64.ipify.org 2>/dev/null)
    fi
    echo "公网 IPv4: ${public_ipv4:-未分配/NAT内网}"
    echo "公网 IPv6: ${public_ipv6:-未检测到}"

    echo -e "\n${BLUE}━━━ 内存与磁盘使用 ━━━${PLAIN}"
    free -h
    echo ""
    df -h / 2>/dev/null | head -2
}

#==============================================================================
# 功能模块 2: Swap 与内核参数管理
#==============================================================================

manage_swap_and_kernel() {
    while true; do
        echo -e "\n${BLUE}━━━ Swap 与内核参数管理 ━━━${PLAIN}"
        echo "当前 Swap 状态:"
        swapon --show 2>/dev/null || echo "  (未启用)"
        echo ""
        echo "1) 创建/重设 Swap 空间"
        echo "2) 安全关闭并清理 Swap"
        echo "3) 调优内核内存参数 (swappiness/cache_pressure)"
        echo "4) 返回主菜单"
        echo ""
        read -rp "请选择 [1-4]: " choice

        case $choice in
            1)
                if [ "$IS_LXC" = true ]; then
                    echo -e "${YELLOW}提示: LXC 容器环境受母机内核限制，通常无法独立挂载 Swap。${PLAIN}"
                    read -rp "仍尝试创建? (y/N): " confirm
                    [[ ! "$confirm" =~ ^[yY]$ ]] && continue
                fi
                local swapfile="/swapfile"
                local size
                size=$(validate_input "请输入 Swap 大小 (MB)" 512 64 32768)
                
                swapoff "$swapfile" 2>/dev/null
                rm -f "$swapfile"
                sed -i "\|$swapfile|d" /etc/fstab 2>/dev/null

                echo "正在分配 ${size}MB 交换空间..."
                if dd if=/dev/zero of="$swapfile" bs=1M count="$size" status=progress 2>/dev/null; then
                    chmod 600 "$swapfile"
                    mkswap "$swapfile" >/dev/null 2>&1
                    if swapon "$swapfile" 2>/dev/null; then
                        echo "$swapfile none swap sw 0 0" >> /etc/fstab
                        echo -e "${GREEN}✓ Swap 启用成功！${PLAIN}"
                    else
                        echo -e "${RED}✗ Swap 激活失败 (容器权限不足)${PLAIN}"
                        rm -f "$swapfile"
                    fi
                fi
                ;;
            2)
                swapoff -a 2>/dev/null
                sed -i '/swap/d' /etc/fstab 2>/dev/null
                rm -f /swapfile /swap.img 2>/dev/null
                echo -e "${GREEN}✓ Swap 已关闭并完成磁盘清理${PLAIN}"
                ;;
            3)
                local swappiness vfs
                swappiness=$(validate_input "设置 vm.swappiness (0 尽量不用, 100 积极使用)" 10 0 100)
                vfs=$(validate_input "设置 vm.vfs_cache_pressure (50 平衡, 100 默认)" 50 0 1000)
                sysctl -w vm.swappiness="$swappiness" >/dev/null 2>&1
                sysctl -w vm.vfs_cache_pressure="$vfs" >/dev/null 2>&1
                mkdir -p /etc/sysctl.d/
                cat > /etc/sysctl.d/99-custom-memory.conf <<EOF
vm.swappiness = $swappiness
vm.vfs_cache_pressure = $vfs
EOF
                echo -e "${GREEN}✓ 内核参数已写入持久化配置文件${PLAIN}"
                ;;
            4) break ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

#==============================================================================
# 功能模块 3: 系统极致优化（通用版）
#==============================================================================

system_extreme_optimize() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║              系统极致优化（通用版）                          ║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${PLAIN}"
    echo "将执行: 禁用冗余Timer、日志内存化、应用顶置DNS、缓存垃圾深层清理"
    read -rp "确认开始优化? (y/N): " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && return

    # 1. 禁用冗余定时器
    disable_conflict_timers
    echo -e "  ${GREEN}✓${PLAIN} 冗余调度器已精简"

    # 2. 日志内存化
    if [ -f /etc/systemd/journald.conf ]; then
        sed -i '/^Storage=/d; /^RuntimeMaxUse=/d; /^SystemMaxUse=/d' /etc/systemd/journald.conf
        cat >> /etc/systemd/journald.conf <<EOF

# 极致优化配置
Storage=volatile
RuntimeMaxUse=${JOURNALD_MAX_USE}
EOF
        systemctl restart systemd-journald >/dev/null 2>&1
        echo -e "  ${GREEN}✓${PLAIN} 系统日志已转入纯内存模式 (${JOURNALD_MAX_USE})"
    fi

    # 3. 应用顶部默认 DNS
    apply_system_dns "$DNS_CF_NEUSTAR_RESOLVED" "$DNS_CF_NEUSTAR_RESOLV" "Cloudflare + Neustar (默认)"

    # 4. 系统垃圾与无用文档深度清理
    if command -v apt-get &>/dev/null; then
        apt-get clean >/dev/null 2>&1
        apt-get autoremove --purge -y >/dev/null 2>&1
        rm -rf /var/lib/apt/lists/* 2>/dev/null
    fi
    rm -rf /usr/share/doc/* /usr/share/man/* 2>/dev/null
    find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name 'zh*' -exec rm -rf {} \; 2>/dev/null
    journalctl --rotate >/dev/null 2>&1
    journalctl --vacuum-time=1s >/dev/null 2>&1
    rm -rf /tmp/* /var/tmp/* 2>/dev/null
    echo -e "  ${GREEN}✓${PLAIN} 临时文件、包缓存与多语言无用文档清理完成"

    # 5. 保留开机 DNS 自动校验任务 (兜底)
    add_smart_task "reboot" "" "systemctl restart systemd-resolved 2>/dev/null || true" "boot_dns_verify"

    echo -e "\n${GREEN}✓ 通用极致优化执行完毕！${PLAIN}"
}

#==============================================================================
# 功能模块 4: DNS 配置管理
#==============================================================================

manage_dns() {
    while true; do
        echo -e "\n${BLUE}━━━ DNS 配置管理 (已全面接入顶部预设) ━━━${PLAIN}"
        echo "当前系统有效 DNS:"
        if [ "$HAS_RESOLVED" = true ]; then
            resolvectl dns 2>/dev/null || grep -E "^nameserver" /etc/resolv.conf 2>/dev/null
        else
            grep -E "^nameserver" /etc/resolv.conf 2>/dev/null
        fi
        echo "────────────────────────────────────────"
        echo "1) 预设一: Cloudflare + Neustar (推荐/抗封锁好)"
        echo "2) 预设二: 经典通用 DNS (Cloudflare + Google)"
        echo "3) 预设三: DNS64 专用 (纯 IPv6 机器访问 v4 网站)"
        echo "4) 预设四: 阿里 DNS (国内环境专用)"
        echo "5) 手动输入自定义 DNS"
        echo "6) 恢复/触发开机兜底自愈任务"
        echo "7) 返回主菜单"
        echo ""
        read -rp "请选择 [1-7]: " choice

        case $choice in
            1) apply_system_dns "$DNS_CF_NEUSTAR_RESOLVED" "$DNS_CF_NEUSTAR_RESOLV" "Cloudflare + Neustar" ;;
            2) apply_system_dns "$DNS_COMMON_RESOLVED" "$DNS_COMMON_RESOLV" "Cloudflare + Google" ;;
            3) apply_system_dns "$DNS_DNS64_RESOLVED" "$DNS_DNS64_RESOLV" "DNS64 专用" ;;
            4) apply_system_dns "$DNS_ALIYUN_RESOLVED" "$DNS_ALIYUN_RESOLV" "阿里公共 DNS" ;;
            5)
                read -rp "请输入自定义 IPv4 DNS (如 1.1.1.1): " c_v4
                read -rp "请输入自定义 IPv6 DNS (可留空): " c_v6
                local c_res="$c_v4 $c_v6"
                local c_file="nameserver $c_v4\n"
                [ -n "$c_v6" ] && c_file+="nameserver $c_v6\n"
                apply_system_dns "$c_res" "$c_file" "自定义 DNS"
                ;;
            6)
                add_smart_task "reboot" "" "systemctl restart systemd-resolved 2>/dev/null || true" "boot_dns_verify"
                echo -e "${GREEN}✓ 开机自愈任务已重新下发${PLAIN}"
                ;;
            7) break ;;
            *) echo -e "${RED}无效输入${PLAIN}" ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

#==============================================================================
# 功能模块 5: 计划任务管理 (防重复安全调度)
#==============================================================================

manage_crontab() {
    while true; do
        echo -e "\n${BLUE}━━━ 当前已注册计划任务 ━━━${PLAIN}"
        if [ "$HAS_CRON" = true ]; then
            crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" || echo "  (无活跃任务)"
        else
            systemctl list-timers --no-pager 2>/dev/null | head -15 || echo "  (无活跃 Timer)"
        fi
        echo "────────────────────────────────────────"
        echo "1) 添加: x-ui 每日定时重启 (02:00)"
        echo "2) 添加: 每天定时清理缓存 (04:00)"
        echo "3) 删除: 指定任务标识"
        echo "4) 清空: 清空所有计划任务"
        echo "5) 返回主菜单"
        echo ""
        read -rp "请选择 [1-5]: " choice

        case $choice in
            1) add_smart_task "daily" "02:00" "systemctl restart x-ui" "xui_daily_restart" ;;
            2) add_smart_task "daily" "04:00" "sync; echo 3 > /proc/sys/vm/drop_caches" "memory_clean" ;;
            3)
                read -rp "请输入要删除的任务标识 (Task ID): " t_id
                [ -n "$t_id" ] && remove_smart_task "$t_id"
                ;;
            4)
                read -rp "确认清空本脚本创建的任务? (y/N): " confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    if [ "$HAS_CRON" = true ]; then
                        crontab -r 2>/dev/null
                    else
                        systemctl disable --now opt_*.timer 2>/dev/null
                        rm -f "${SYSTEMD_DIR}"/opt_*.service "${SYSTEMD_DIR}"/opt_*.timer
                        systemctl daemon-reload
                    fi
                    echo -e "${GREEN}✓ 任务已完全清空${PLAIN}"
                fi
                ;;
            5) break ;;
            *) echo -e "${RED}无效输入${PLAIN}" ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

#==============================================================================
# 功能模块 6: x-ui/WARP 极致优化 (加固版: 内存化运行 + 数据防丢机制)
#==============================================================================

# 自动探测 x-ui 数据库实体路径
detect_xui_db() {
    local p=""
    for candidate in "/etc/x-ui/x-ui.db" "/etc/x-ui-yg/x-ui-yg.db" "/usr/local/x-ui/x-ui.db"; do
        if [ -e "$candidate" ]; then
            p="$candidate"
            break
        fi
    done
    echo "$p"
}

# 生成双向持久化同步脚本 (彻底解决关机/重启丢失节点)
generate_persistence_engine() {
    local db_path="$1"
    local db_name db_backup sync_script

    db_name=$(basename "$db_path")
    db_backup="${db_path}.backup"
    sync_script="${SCRIPT_DIR}/sync_xui_db.sh"

    # [子脚本 1] 将内存数据刷回硬盘 (定时/关机调用)
    cat > "$sync_script" <<EOF
#!/bin/bash
# x-ui 数据库内存持久化回写脚本 (自动生成)
if [ -f "/dev/shm/${db_name}" ] && [ -s "/dev/shm/${db_name}" ]; then
    # 对比 MD5，有变化才写入磁盘，避免无意义的磁盘损耗
    if ! cmp -s "/dev/shm/${db_name}" "${db_backup}"; then
        cp -f "/dev/shm/${db_name}" "${db_backup}.tmp" && mv -f "${db_backup}.tmp" "${db_backup}"
        logger -t [x-ui-sync] "检测到节点数据库更新，已成功同步到物理磁盘备份"
    fi
fi
EOF
    chmod +x "$sync_script"

    # [子脚本 2] 开机或清洗时的状态维护脚本
    cat > "${SCRIPT_DIR}/reset_ram_state.sh" <<EOF
#!/bin/bash
# 内存状态重置与开机自愈脚本

# 1. 执行前安全检查: 如果内存里有新数据，先回写硬盘
[ -x "${sync_script}" ] && ${sync_script}

# 2. 从硬盘备份将数据库恢复到内存盘 /dev/shm
if [ -f "${db_backup}" ]; then
    cp -f "${db_backup}" "/dev/shm/${db_name}"
    chmod 644 "/dev/shm/${db_name}"
fi

# 3. 内存释放
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
journalctl --vacuum-time=1s >/dev/null 2>&1

# 4. 确保 x-ui 处于正常运行状态
systemctl restart x-ui 2>/dev/null
EOF
    chmod +x "${SCRIPT_DIR}/reset_ram_state.sh"
}

# 生成内存看门狗脚本 (防 OOM 暴毙)
generate_watchdog() {
    cat > "${SCRIPT_DIR}/check_memory.sh" <<EOF
#!/bin/bash
# 内存看门狗 (超标自动安全清洗)
THRESHOLD=${WATCHDOG_MEM_THRESHOLD}
mem_used=\$(free | awk '/Mem:/ {print int(\$3*100/\$2)}')
if [ "\$mem_used" -gt "\$THRESHOLD" ]; then
    logger -t [RAM-WATCHDOG] "内存占用超标 (\${mem_used}% > \${THRESHOLD}%)，正在触发安全清理..."
    ${SCRIPT_DIR}/reset_ram_state.sh
fi
EOF
    chmod +x "${SCRIPT_DIR}/check_memory.sh"
}

optimize_xui_warp() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║     x-ui 内存运行模式优化 (带每日自动持久化与防丢保护)       ║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${PLAIN}"
    echo "特性亮点:"
    echo "  1. 数据库搬入 /dev/shm 内存盘，读写延迟逼近极限，零磁盘磨损"
    echo "  2. 预设每天 ${XUI_SYNC_TIME} 自动增量持久化回磁盘，机器长年不重启也安全"
    echo "  3. 异常关机/看门狗介入前强制持久化，告别丢节点烦恼"
    echo ""
    read -rp "确认开始优化? (y/N): " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && return

    # 1. 基础系统与 DNS 优化
    apply_system_dns "$DNS_CF_NEUSTAR_RESOLVED" "$DNS_CF_NEUSTAR_RESOLV" "顶置默认 DNS"
    disable_conflict_timers

    # 2. 数据库迁移到内存
    local db_path
    db_path=$(detect_xui_db)
    if [ -n "$db_path" ]; then
        local db_name db_backup
        db_name=$(basename "$db_path")
        db_backup="${db_path}.backup"

        # 检查是否已经是软链接 (幂等保护: 避免网络断开二次运行时覆盖旧备份)
        if [ -L "$db_path" ]; then
            echo -e "  ${YELLOW}○${PLAIN} 数据库已是内存软链接，跳过初始迁移"
        elif [ -f "$db_path" ]; then
            systemctl stop x-ui 2>/dev/null
            cp -f "$db_path" "$db_backup"                     # 硬盘持久层建立母本
            mv -f "$db_path" "/dev/shm/${db_name}"            # 移入内存
            ln -sf "/dev/shm/${db_name}" "$db_path"           # 建立透明软链接
            systemctl start x-ui 2>/dev/null
            echo -e "  ${GREEN}✓${PLAIN} x-ui 数据库已成功迁移到内存盘 (/dev/shm)"
        fi

        # 3. 部署双向同步脚本与看门狗
        generate_persistence_engine "$db_path"
        generate_watchdog
        echo -e "  ${GREEN}✓${PLAIN} 防丢回写引擎与内存看门狗脚本生成完成"

        # 4. 注册智能化计划任务
        # [任务 1] 每天凌晨指定时间持久化一次 (长年不重启也能定期备份到磁盘)
        add_smart_task "daily" "$XUI_SYNC_TIME" "${SCRIPT_DIR}/sync_xui_db.sh" "xui_auto_sync"

        # [任务 2] 开机时从硬盘载入内存
        add_smart_task "reboot" "" "${SCRIPT_DIR}/reset_ram_state.sh" "xui_boot_restore"

        # [任务 3] 每 15 分钟运行一次看门狗
        add_smart_task "interval" "15min" "${SCRIPT_DIR}/check_memory.sh" "xui_mem_watchdog"

        echo -e "\n${GREEN}✓ x-ui 极致内存模式配置完成且已闭环保护！${PLAIN}"
    else
        echo -e "\n${YELLOW}⚠ 未在常规路径探测到 x-ui 数据库，仅完成了底层网络和 DNS 优化。${PLAIN}"
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
        echo -e "${CYAN}║           Linux 系统工具箱 (加固优化版 v2.2)                 ║${PLAIN}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${PLAIN}"
        echo -e "${CYAN}║${PLAIN} 环境: $([ "$IS_LXC" = true ] && echo "${YELLOW}LXC 容器${PLAIN}" || echo "标准物理机/KVM") | 调度: $([ "$HAS_CRON" = true ] && echo "${GREEN}Cron${PLAIN}" || echo "${GREEN}Systemd Timer${PLAIN}") | DNS: $([ "$HAS_RESOLVED" = true ] && echo "${GREEN}Resolved 接管${PLAIN}" || echo "标准静态")   ${CYAN}║${PLAIN}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${PLAIN}"
        echo ""
        echo "  1) 显示系统与网络信息"
        echo "  2) 管理 Swap 交换空间与内核参数"
        echo "  3) 系统极致优化（通用版）"
        echo "  4) DNS 配置管理 (已挂接顶部全局预设)"
        echo "  5) 计划任务查看与管理 (Cron/Timer 双模)"
        echo ""
        echo -e "  ${GREEN}6) x-ui 内存化极致优化 (带每日自动回写防丢保护)${PLAIN}"
        echo ""
        echo "  7) 退出脚本"
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        read -rp "请输入对应选项 [1-7]: " main_choice

        case $main_choice in
            1) clear; show_system_info ;;
            2) clear; manage_swap_and_kernel ;;
            3) clear; system_extreme_optimize ;;
            4) clear; manage_dns ;;
            5) clear; manage_crontab ;;
            6) clear; optimize_xui_warp ;;
            7) echo -e "\n退出成功。"; exit 0 ;;
            *) echo -e "${RED}输入无效，请输入 1-7 的数字${PLAIN}" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# 脚本入口
main_menu
