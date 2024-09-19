#!/bin/bash

set -e

# 设置下载测试的 URL 和测试时间（秒）
TEST_URL="https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
TEST_DURATION=10

# 从 GitHub 获取 DNS64 服务器列表
get_dns64_servers() {
    local url="https://raw.githubusercontent.com/ccqwerty123/ccqwerty123/main/dns64.txt"
    local content

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

    echo "$content" | grep -v '^#' | awk '{print $1}' | grep -E '^[0-9a-fA-F:]+$'
}

# 检查是否有原生 IPv6 地址
has_native_ipv6() {
    local domain=$(echo "$1" | sed -E 's#https?://##' | cut -d'/' -f1)
    local non_dns64_server="8.8.8.8"

    if command -v dig &> /dev/null; then
        if dig AAAA "$domain" @"$non_dns64_server" +short | grep -q '^[0-9a-fA-F:]\+$'; then
            return 0
        fi
    elif command -v nslookup &> /dev/null; then
        if nslookup -type=AAAA "$domain" "$non_dns64_server" | grep -q 'has AAAA address'; then
            return 0
        fi
    elif command -v host &> /dev/null; then
        if host -t AAAA "$domain" "$non_dns64_server" | grep -q 'has IPv6 address'; then
            return 0
        fi
    else
        echo "Error: No suitable DNS query tool found (dig, nslookup, or host)." >&2
        return 1
    fi

    return 1
}

# 获取合成的 IPv6 地址
get_synthesized_ipv6() {
    local domain=$(echo "$1" | sed -E 's#https?://##' | cut -d'/' -f1)
    local dns64_server="$2"

    if command -v dig &> /dev/null; then
        dig AAAA "$domain" @"$dns64_server" +short | grep '^[0-9a-fA-F:]\+$' | head -n1
    elif command -v nslookup &> /dev/null; then
        nslookup -type=AAAA "$domain" "$dns64_server" | grep 'has AAAA address' | awk '{print $NF}' | head -n1
    elif command -v host &> /dev/null; then
        host -t AAAA "$domain" "$dns64_server" | grep 'has IPv6 address' | awk '{print $NF}' | head -n1
    else
        echo "Error: No suitable DNS query tool found (dig, nslookup, or host)." >&2
        return 1
    fi
}

# 测试下载速度
test_download_speed() {
    local url="$1"
    local ipv6_address="$2"
    local duration="$3"

    local domain=$(echo "$url" | sed -E 's#https?://##' | cut -d'/' -f1)
    local ipv6_url=$(echo "$url" | sed -E "s#https?://$domain#&/\[$ipv6_address\]#")

    if command -v curl &> /dev/null; then
        local speed=$(curl -g -6 -o /dev/null -m "$duration" -w "%{speed_download}" "$ipv6_url" 2>/dev/null)
        echo "$speed" | awk '{printf "%.2f\n", $1 / 1000000}'
    elif command -v wget &> /dev/null; then
        local speed=$(wget -6 -O /dev/null "$ipv6_url" 2>&1 | grep -i "avg. speed" | awk '{print $(NF-1) * 8}')
        echo "$speed" | awk '{printf "%.2f\n", $1 / 1000000}'
    else
        echo "Error: Neither curl nor wget is available for download speed test." >&2
        echo "0"
    fi
}

# 主函数
main() {
    if has_native_ipv6 "$TEST_URL"; then
        echo "The URL $TEST_URL already has a native IPv6 address."
        exit 0
    fi

    local dns64_servers=($(get_dns64_servers))
    if [ ${#dns64_servers[@]} -eq 0 ]; then
        echo "Error: No valid DNS64 servers found. Using default servers."
        dns64_servers=("2001:4860:4860::6464" "2001:4860:4860::64")
    fi

    local fastest_dns=""
    local highest_speed=0

    for dns in "${dns64_servers[@]}"; do
        echo "Testing DNS64 server: $dns"
        local ipv6_address=$(get_synthesized_ipv6 "$TEST_URL" "$dns")
        if [ -z "$ipv6_address" ]; then
            echo "Failed to get synthesized IPv6 address from $dns"
            continue
        fi

        local speed=$(test_download_speed "$TEST_URL" "$ipv6_address" "$TEST_DURATION")
        echo "Download speed: $speed Mbps"

        if (( $(echo "$speed > $highest_speed" | bc -l) )); then
            highest_speed=$speed
            fastest_dns=$dns
        fi
    done

    if [ -n "$fastest_dns" ]; then
        echo "The fastest DNS64 server is $fastest_dns with a speed of $highest_speed Mbps"
    else
        echo "Could not determine the fastest DNS64 server."
    fi
}

# 运行主函数
main
