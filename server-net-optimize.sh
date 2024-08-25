#!/bin/bash

# 判断系统类型
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [[ -f /etc/os-release ]]; then
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
}

# 检查IP地址
check_ip() {
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
}

# 修改DNS和hosts文件
modify_dns_and_hosts() {
    if [[ -z "$IPv4_ADDR" && -n "$IPv6_ADDR" ]]; then
        echo "只存在IPv6地址，修改DNS为DNS64"
        echo "nameserver 2606:4700:4700::64" | sudo tee /etc/resolv.conf
        echo "nameserver 2001:4860:4860::64" | sudo tee -a /etc/resolv.conf
    fi

    if [[ -n "$IPv6_ADDR" ]]; then
        echo "检测到IPv6地址，尝试获取Google IPv6地址并添加到hosts文件"
        google_ipv6=""

        # 尝试使用curl
        if command -v curl &> /dev/null; then
            google_ipv6=$(curl -6 -s https://domains.google.com/checkip)
        fi

        # 如果curl失败，尝试使用dig
        if [[ -z "$google_ipv6" ]] && command -v dig &> /dev/null; then
            google_ipv6=$(dig AAAA google.com +short | head -n 1)
        fi

        # 如果dig失败，尝试使用host
        if [[ -z "$google_ipv6" ]] && command -v host &> /dev/null; then
            google_ipv6=$(host -t AAAA google.com | grep "has IPv6 address" | head -n 1 | awk '{print $NF}')
        fi

        # 如果host也失败，尝试使用nslookup
        if [[ -z "$google_ipv6" ]] && command -v nslookup &> /dev/null; then
            google_ipv6=$(nslookup -type=AAAA google.com | grep "has AAAA address" | head -n 1 | awk '{print $NF}')
        fi

        # 如果以上方法都失败，尝试使用getent
        if [[ -z "$google_ipv6" ]] && command -v getent &> /dev/null; then
            google_ipv6=$(getent ahostsv6 google.com | head -n 1 | awk '{print $1}')
        fi

        if [[ -n "$google_ipv6" ]]; then
            echo "获取到Google IPv6地址: $google_ipv6"
            echo "$google_ipv6 google.com" | sudo tee -a /etc/hosts
            echo "已将Google IPv6地址添加到hosts文件"
        else
            echo "无法获取Google IPv6地址，请检查网络连接或DNS设置"
        fi
    fi
}

# 主函数
main() {
    detect_os
    check_ip
    modify_dns_and_hosts
}

# 执行主函数
main
