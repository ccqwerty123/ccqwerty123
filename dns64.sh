#!/bin/bash
set -e

# 设置下载测试的默认 URL 和测试时间（秒）
DEFAULT_TEST_URL="https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
TEST_DURATION=10

# 纯 IPv4 网址列表
IPV4_WEBSITES=(
    "www.example.com"
    "ipv4.google.com"
    "ipv4only.arpa"
    "d.root-servers.net"
)

# 启用调试模式
DEBUG=true

# 调试输出函数
debug() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] $1" >&2
    fi
}

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$DISTRIB_ID
    elif [ -f /etc/debian_version ]; then
        OS=Debian
    elif [ -f /etc/redhat-release ]; then
        OS=RedHat
    else
        OS=$(uname -s)
    fi
}

# 清除DNS缓存
clear_dns_cache() {
    detect_os
    case $OS in
        Ubuntu|Debian)
            sudo systemd-resolve --flush-caches
            ;;
        CentOS|RedHat)
            sudo systemctl restart NetworkManager
            ;;
        MacOS|Darwin)
            sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
            ;;
        *)
            echo "未知操作系统，无法清除DNS缓存"
            ;;
    esac
    echo "DNS缓存已清除"
}

# 从 GitHub 获取 DNS64 服务器列表
get_dns64_servers() {
    local url="https://raw.githubusercontent.com/ccqwerty123/ccqwerty123/main/dns64.txt"
    local content
    debug "Fetching DNS64 server list from $url"
    if command -v curl &> /dev/null; then
        content=$(curl -s "$url")
    elif command -v wget &> /dev/null; then
        content=$(wget -qO- "$url")
    else
        echo "Error: Neither curl nor wget is available." >&2
        return 1
    fi
    if [ -z "$content" ]; then
        echo "Error: Failed to fetch DNS64 server list." >&2
        return 1
    fi
    debug "Raw content from GitHub:"
    debug "$content"
    local servers=$(echo "$content" | grep -v '^#' | awk '{print $1}' | grep -E '^[0-9a-fA-F:]+$')
    debug "Parsed DNS64 servers:"
    debug "$servers"
    echo "$servers"
}

# 测试DNS解析速度
test_dns_resolution_speed() {
    local domain="$1"
    local dns_server="$2"
    local start_time=$(date +%s.%N)
    dig AAAA "$domain" @"$dns_server" +short > /dev/null 2>&1
    local end_time=$(date +%s.%N)
    echo "$(echo "$end_time - $start_time" | bc) seconds"
}

# 测试NAT64连接性
test_nat64_connectivity() {
    local ipv4_addr="$1"
    local dns_server="$2"
    local ipv6_addr=$(dig AAAA "$ipv4_addr" @"$dns_server" +short)
    if [ -z "$ipv6_addr" ]; then
        echo "Failed to get IPv6 address for $ipv4_addr"
        return 1
    fi
    if ping6 -c 1 -W 2 "$ipv6_addr" > /dev/null 2>&1; then
        echo "NAT64 connectivity successful for $ipv4_addr"
        return 0
    else
        echo "NAT64 connectivity failed for $ipv4_addr"
        return 1
    fi
}

# 测试下载速度
test_download_speed() {
    local url="$1"
    local duration="$2"
    local temp_file=$(mktemp)
    curl -s -o "$temp_file" "$url" &
    local pid=$!
    sleep "$duration"
    kill $pid 2>/dev/null
    local file_size=$(stat -c %s "$temp_file")
    rm -f "$temp_file"
    echo "scale=2; $file_size * 8 / (1024 * 1024 * $duration)" | bc
}

# 备份当前DNS设置
backup_dns() {
    cp /etc/resolv.conf /etc/resolv.conf.backup
    echo "Current DNS settings backed up to /etc/resolv.conf.backup"
}

# 恢复DNS设置
restore_dns() {
    if [ -f /etc/resolv.conf.backup ]; then
        mv /etc/resolv.conf.backup /etc/resolv.conf
        echo "DNS settings restored from backup"
    else
        echo "No DNS backup found"
    fi
}

# 修改DNS设置
modify_dns() {
    local dns_servers=("$@")
    echo -n > /etc/resolv.conf
    for dns in "${dns_servers[@]}"; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    if grep -q "nameserver $dns" /etc/resolv.conf; then
        echo "DNS settings modified successfully"
        clear_dns_cache
        return 0
    else
        echo "Failed to modify DNS settings"
        return 1
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n欢迎使用DNS64和NAT64测速脚本"
        echo "该脚本可以测试DNS64服务器的解析速度、NAT64连接性和下载速度，并可以修改系统DNS设置。"
        echo "请选择以下选项："
        echo "1. 修改DNS并测速"
        echo "2. 不修改DNS测速"
        echo "3. 退出脚本"
        read -p "请输入您的选择 (1-3): " choice
        case $choice in
            1) modify_dns_and_test ;;
            2) test_without_modifying_dns ;;
            3) echo "感谢使用，再见！"; exit 0 ;;
            *) echo "无效的选择，请重试。" ;;
        esac
    done
}

# 修改DNS并测速
modify_dns_and_test() {
    echo "您选择了修改DNS并测速"
    echo "1. 测试DNS64解析速度和NAT64连接性"
    echo "2. 测试DNS下载速度"
    read -p "请选择测试类型 (1-2): " test_type
    
    backup_dns
    
    local dns64_servers=($(get_dns64_servers))
    if [ ${#dns64_servers[@]} -eq 0 ]; then
        echo "Error: No valid DNS64 servers found. Using default servers."
        dns64_servers=("2001:4860:4860::6464" "2001:4860:4860::64")
    fi
    
    local best_dns=()
    local best_speed=()
    
    case $test_type in
        1)
            echo "正在测试DNS64解析速度和NAT64连接性..."
            for dns in "${dns64_servers[@]}"; do
                if ! modify_dns "$dns"; then
                    continue
                fi
                local avg_speed=0
                local nat64_success=0
                for website in "${IPV4_WEBSITES[@]}"; do
                    for i in {1..3}; do
                        local speed=$(test_dns_resolution_speed "$website" "$dns")
                        avg_speed=$(echo "$avg_speed + $speed" | bc)
                    done
                    if test_nat64_connectivity "$website" "$dns"; then
                        nat64_success=$((nat64_success + 1))
                    fi
                done
                avg_speed=$(echo "scale=3; $avg_speed / (3 * ${#IPV4_WEBSITES[@]})" | bc)
                echo "DNS: $dns"
                echo "  平均DNS64解析速度: $avg_speed 秒"
                echo "  NAT64连接性成功率: $nat64_success / ${#IPV4_WEBSITES[@]}"
                best_dns+=("$dns")
                best_speed+=("$avg_speed")
            done
            ;;
        2)
            read -p "请输入测速文件地址 (留空使用默认地址): " TEST_URL
            TEST_URL=${TEST_URL:-$DEFAULT_TEST_URL}
            echo "正在测试DNS下载速度..."
            for dns in "${dns64_servers[@]}"; do
                if ! modify_dns "$dns"; then
                    continue
                fi
                local avg_speed=0
                for i in {1..3}; do
                    local speed=$(test_download_speed "$TEST_URL" "$TEST_DURATION")
                    avg_speed=$(echo "$avg_speed + $speed" | bc)
                done
                avg_speed=$(echo "scale=2; $avg_speed / 3" | bc)
                echo "DNS: $dns, 平均下载速度: $avg_speed Mbps"
                best_dns+=("$dns")
                best_speed+=("$avg_speed")
            done
            ;;
        *)
            echo "无效的选择，返回主菜单"
            return
            ;;
    esac
    
    # 排序并找出最快的两个DNS
    for ((i=0; i<${#best_dns[@]}; i++)); do
        for ((j=i+1; j<${#best_dns[@]}; j++)); do
            if (( $(echo "${best_speed[$i]} > ${best_speed[$j]}" | bc -l) )); then
                temp_dns=${best_dns[$i]}
                temp_speed=${best_speed[$i]}
                best_dns[$i]=${best_dns[$j]}
                best_speed[$i]=${best_speed[$j]}
                best_dns[$j]=$temp_dns
                best_speed[$j]=$temp_speed
            fi
        done
    done
    
    echo "最快的两个DNS服务器是："
    echo "1. ${best_dns[-1]} (${best_speed[-1]})"
    echo "2. ${best_dns[-2]} (${best_speed[-2]})"
    
    read -p "是否要将DNS修改为这两个最快的服务器？(y/n，默认为n): " modify_choice
    if [[ $modify_choice == "y" || $modify_choice == "Y" ]]; then
        if modify_dns "${best_dns[-1]}" "${best_dns[-2]}"; then
            echo "DNS已修改为最快的两个服务器"
        fi
    else
        restore_dns
        echo "DNS已恢复为原始设置"
    fi
}

# 不修改DNS测速
test_without_modifying_dns() {
    echo "您选择了不修改DNS测速"
    local dns64_servers=($(get_dns64_servers))
    if [ ${#dns64_servers[@]} -eq 0 ]; then
        echo "Error: No valid DNS64 servers found. Using default servers."
        dns64_servers=("2001:4860:4860::6464" "2001:4860:4860::64")
    fi
    
    echo "正在测试DNS64解析延迟和NAT64连接性..."
    for dns in "${dns64_servers[@]}"; do
        local avg_speed=0
        local nat64_success=0
        for website in "${IPV4_WEBSITES[@]}"; do
            for i in {1..3}; do
                local speed=$(test_dns_resolution_speed "$website" "$dns")
                avg_speed=$(echo "$avg_speed + $speed" | bc)
            done
            if test_nat64_connectivity "$website" "$dns"; then
                nat64_success=$((nat64_success + 1))
            fi
        done
        avg_speed=$(echo "scale=3; $avg_speed / (3 * ${#IPV4_WEBSITES[@]})" | bc)
        echo "DNS: $dns"
        echo "  平均DNS64解析延迟: $avg_speed 秒"
        echo "  NAT64连接性成功率: $nat64_success / ${#IPV4_WEBSITES[@]}"
    done
}

# 运行主菜单
main_menu
