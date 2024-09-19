#!/bin/bash

set -e

# 设置下载测试的 URL 和测试时间（秒）
TEST_URL="https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
TEST_DURATION=10

# 启用调试模式
DEBUG=true

# 调试输出函数
debug() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] $1" >&2
    fi
}

# 从 GitHub 获取 DNS64 服务器列表
get_dns64_servers() {
    local url="https://raw.githubusercontent.com/ccqwerty123/ccqwerty123/main/dns64.txt"
    local content

    debug "获取DNS64服务器列表，URL: $url"

    if command -v curl &> /dev/null; then
        content=$(curl -s "$url")
    elif command -v wget &> /dev/null; then
        content=$(wget -qO- "$url")
    else
        echo "错误：未找到 curl 或 wget。" >&2
        return 1
    fi

    if [ -z "$content" ]; then
        echo "错误：无法获取DNS64服务器列表。" >&2
        return 1
    fi

    debug "从GitHub获取的原始内容："
    debug "$content"

    local servers=$(echo "$content" | grep -v '^#' | awk '{print $1}' | grep -E '^[0-9a-fA-F:]+$')
    debug "解析后的DNS64服务器："
    debug "$servers"

    echo "$servers"
}

# 检查是否有原生 IPv6 地址
get_native_ipv6() {
    local domain=$(echo "$1" | sed -E 's#https?://##' | cut -d'/' -f1)
    local non_dns64_server="8.8.8.8"

    debug "检查域名 $domain 是否有原生IPv6地址"

    local ipv6_address=""
    if command -v dig &> /dev/null; then
        debug "使用 dig 查询IPv6地址"
        ipv6_address=$(dig AAAA "$domain" @"$non_dns64_server" +short | grep -E '^[0-9a-fA-F:]+$' | head -n1)
    elif command -v nslookup &> /dev/null; then
        debug "使用 nslookup 查询IPv6地址"
        ipv6_address=$(nslookup -type=AAAA "$domain" "$non_dns64_server" | grep 'has AAAA address' | awk '{print $NF}')
    elif command -v host &> /dev/null; then
        debug "使用 host 查询IPv6地址"
        ipv6_address=$(host -t AAAA "$domain" "$non_dns64_server" | grep 'has IPv6 address' | awk '{print $NF}')
    else
        echo "错误：未找到合适的DNS查询工具（dig、nslookup 或 host）。" >&2
        return 1
    fi

    if [ -n "$ipv6_address" ]; then
        debug "域名 $domain 有原生IPv6地址：$ipv6_address"
        echo "$ipv6_address"
        return 0
    else
        debug "域名 $domain 没有原生IPv6地址，需要使用DNS64服务器合成IPv6地址"
        return 1
    fi
}

# 获取合成的 IPv6 地址
get_synthesized_ipv6() {
    local domain=$(echo "$1" | sed -E 's#https?://##' | cut -d'/' -f1)
    local dns64_server="$2"

    debug "使用DNS64服务器 $dns64_server 获取域名 $domain 的合成IPv6地址"

    local result
    if command -v dig &> /dev/null; then
        debug "使用 dig 查询合成IPv6地址"
        result=$(dig AAAA "$domain" @"$dns64_server" +short)
    elif command -v nslookup &> /dev/null; then
        debug "使用 nslookup 查询合成IPv6地址"
        result=$(nslookup -type=AAAA "$domain" "$dns64_server" | grep 'has AAAA address' | awk '{print $NF}')
    elif command -v host &> /dev/null; then
        debug "使用 host 查询合成IPv6地址"
        result=$(host -t AAAA "$domain" "$dns64_server" | grep 'has IPv6 address' | awk '{print $NF}')
    else
        echo "错误：未找到合适的DNS查询工具（dig、nslookup 或 host）。" >&2
        return 1
    fi

    debug "DNS查询原始结果："
    debug "$result"

    local ipv6_address=$(echo "$result" | grep -E '^[0-9a-fA-F:]+$' | head -n1)
    debug "提取的IPv6地址：$ipv6_address"

    echo "$ipv6_address"
}

# 测试下载速度
test_download_speed() {
    local url="$1"
    local ipv6_address="$2"
    local duration="$3"

    local domain=$(echo "$url" | sed -E 's#https?://##' | cut -d'/' -f1)
    local ipv6_url=$(echo "$url" | sed -E "s#https?://$domain#https://[$ipv6_address]#")

    debug "测试下载速度，URL: $ipv6_url"
    debug "测试持续时间: $duration 秒"

    local speed=0
    local error_message=""

    if command -v curl &> /dev/null; then
        debug "使用 curl 进行下载测试"
        local curl_output=$(curl -g -6 -o /dev/null -m "$duration" -w "%{speed_download}\n%{http_code}" "$ipv6_url" 2>&1)
        speed=$(echo "$curl_output" | head -n1)
        local http_code=$(echo "$curl_output" | tail -n1)
        debug "Curl 输出: $curl_output"
        debug "HTTP 状态码: $http_code"
        if [ "$http_code" != "200" ]; then
            error_message="HTTP 错误: $http_code"
        fi
    elif command -v wget &> /dev/null; then
        debug "使用 wget 进行下载测试"
        local wget_output=$(wget -6 -O /dev/null "$ipv6_url" 2>&1)
        debug "Wget 输出: $wget_output"
        speed=$(echo "$wget_output" | grep -i "avg. speed" | awk '{print $(NF-1) * 8}')
        if [ -z "$speed" ]; then
            error_message="无法解析 wget 输出"
        fi
    else
        echo "错误：未找到 curl 或 wget 进行下载速度测试。" >&2
        return 1
    fi

    if [ -n "$error_message" ]; then
        echo "错误: $error_message" >&2
        echo "0"
    else
        echo "$speed" | awk '{printf "%.2f\n", $1 / 1000000}'
    fi
}

# 主函数
main() {
    debug "开始测试URL: $TEST_URL"

    local native_ipv6=$(get_native_ipv6 "$TEST_URL")
    if [ -n "$native_ipv6" ]; then
        echo "URL $TEST_URL 已经有原生IPv6地址: $native_ipv6"
        local speed=$(test_download_speed "$TEST_URL" "$native_ipv6" "$TEST_DURATION")
        echo "原生IPv6下载速度: $speed Mbps"
        exit 0
    fi

    local dns64_servers=($(get_dns64_servers))
    if [ ${#dns64_servers[@]} -eq 0 ]; then
        echo "错误：未找到有效的DNS64服务器。使用默认服务器。"
        dns64_servers=("2001:4860:4860::6464" "2001:4860:4860::64")
    fi

    local fastest_dns=""
    local highest_speed=0

    for dns in "${dns64_servers[@]}"; do
        echo "测试DNS64服务器: $dns"
        local ipv6_address=$(get_synthesized_ipv6 "$TEST_URL" "$dns")
        if [ -z "$ipv6_address" ]; then
            echo "无法从 $dns 获取合成的IPv6地址"
            continue
        fi

        echo "合成的IPv6地址: $ipv6_address"
        local speed=$(test_download_speed "$TEST_URL" "$ipv6_address" "$TEST_DURATION")
        echo "下载速度: $speed Mbps"

        if (( $(echo "$speed > $highest_speed" | bc -l) )); then
            highest_speed=$speed
            fastest_dns=$dns
        fi
    done

    if [ -n "$fastest_dns" ]; then
        echo "最快的DNS64服务器是 $fastest_dns，速度为 $highest_speed Mbps"
    else
        echo "无法确定最快的DNS64服务器。"
    fi
}

# 运行主函数
main
