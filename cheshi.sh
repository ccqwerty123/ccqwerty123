#!/bin/bash

# 设置变量
DOMAIN="dldir1.qq.com"
FILE_PATH="/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
TIMEOUT=10

# 检查 IPv6 地址连接性的函数
check_ipv6_connectivity() {
    local ipv6=$1
    local url="https://[$ipv6]$FILE_PATH"

    echo "检查连接性: $url"
    if curl -6 -o /dev/null -s -H "Host: $DOMAIN" -m $TIMEOUT "$url"; then
        echo "IPv6 地址 $ipv6 可以连接"
        return 0
    else
        echo "IPv6 地址 $ipv6 无法连接"
        return 1
    fi
}

# 测试下载的函数
test_download() {
    local ipv6=$1
    local url="https://[$ipv6]$FILE_PATH"

    echo "测试下载：$url"
    curl -6 -o /dev/null -w "HTTP状态码: %{http_code}\n下载速度: %{speed_download} bytes/sec\n" -H "Host: $DOMAIN" -m 30 "$url"
}

# 主函数
main() {
    local ipv6_addresses=("64:ff9b::cbcd:89eb" "64:ff9b::cbcd:89ea")

    for ipv6 in "${ipv6_addresses[@]}"; do
        echo "测试 IPv6 地址: $ipv6"
        if check_ipv6_connectivity "$ipv6"; then
            test_download "$ipv6"
        else
            echo "跳过不可连接的地址 $ipv6"
        fi
        echo "------------------------"
    done
}

# 运行主函数
main
