#!/bin/bash

# 设置变量
DOMAIN="dldir1.qq.com"
FILE_PATH="/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
TIMEOUT=30
MAX_RETRIES=3
RETRY_DELAY=5

# 使用 nc 检查 IPv6 地址连接性
check_ipv6_nc() {
    local ipv6=$1
    for ((i=1; i<=MAX_RETRIES; i++)); do
        echo "使用 nc 检查连接性: $ipv6 (尝试 $i/$MAX_RETRIES)"
        if nc -z -v -w 5 "$ipv6" 443 &>/dev/null; then
            echo "nc: IPv6 地址 $ipv6 可以连接"
            return 0
        else
            echo "nc: 尝试 $i 失败"
            [ $i -lt $MAX_RETRIES ] && sleep $RETRY_DELAY
        fi
    done
    echo "nc: IPv6 地址 $ipv6 在 $MAX_RETRIES 次尝试后仍无法连接"
    return 1
}

# 使用 curl 检查 IPv6 地址连接性
check_ipv6_curl() {
    local ipv6=$1
    local url="https://[$ipv6]$FILE_PATH"
    for ((i=1; i<=MAX_RETRIES; i++)); do
        echo "使用 curl 检查连接性: $url (尝试 $i/$MAX_RETRIES)"
        if curl -6 -o /dev/null -s -H "Host: $DOMAIN" -m $TIMEOUT "$url"; then
            echo "curl: IPv6 地址 $ipv6 可以连接"
            return 0
        else
            echo "curl: 尝试 $i 失败，错误: $?"
            [ $i -lt $MAX_RETRIES ] && sleep $RETRY_DELAY
        fi
    done
    echo "curl: IPv6 地址 $ipv6 在 $MAX_RETRIES 次尝试后仍无法连接"
    return 1
}

# 测试下载的函数
test_download() {
    local ipv6=$1
    local url="https://[$ipv6]$FILE_PATH"
    echo "测试下载：$url"
    curl -6 -o /dev/null -w "HTTP状态码: %{http_code}\n下载速度: %{speed_download} bytes/sec\n" -H "Host: $DOMAIN" -m $TIMEOUT "$url"
}

# 主函数
main() {
    local ipv6_addresses=("64:ff9b::cbcd:89eb" "64:ff9b::cbcd:89ea")

    for ipv6 in "${ipv6_addresses[@]}"; do
        echo "测试 IPv6 地址: $ipv6"
        nc_result=0
        curl_result=0
        
        check_ipv6_nc "$ipv6" || nc_result=1
        check_ipv6_curl "$ipv6" || curl_result=1

        if [ $nc_result -eq 0 ] || [ $curl_result -eq 0 ]; then
            echo "至少一种方法检测到连接成功，进行下载测试"
            test_download "$ipv6"
        else
            echo "两种方法都检测到连接失败，跳过下载测试"
        fi
