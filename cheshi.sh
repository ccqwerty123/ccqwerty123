#!/bin/bash

# 检查并安装必要的工具
install_tools() {
    if ! command -v dig &> /dev/null; then
        echo "未找到 dig，正在安装..."
        sudo apt-get update
        sudo apt-get install -y dnsutils
    fi

    if ! command -v nslookup &> /dev/null; then
        echo "未找到 nslookup，正在安装..."
        sudo apt-get update
        sudo apt-get install -y dnsutils
    fi
}

# 查询 IPv6 地址的函数
query_ipv6() {
    local domain="$1"
    local method="$2"
    local ipv6_address=""

    if [ "$method" == "dig" ]; then
        ipv6_address=$(dig AAAA "$domain" +short)
    elif [ "$method" == "nslookup" ]; then
        ipv6_address=$(nslookup -query=AAAA "$domain" | grep 'address' | awk '{print $2}')
    else
        echo "不支持的查询方式: $method"
        return 1
    fi

    if [ -z "$ipv6_address" ]; then
        echo "未找到 $domain 的 IPv6 地址"
        return 1
    else
        echo "$domain 的 IPv6 地址是: $ipv6_address"
        return 0
    fi
}

# 主程序
main() {
    install_tools

    # 默认域名和查询方式
    local domain="sohu.com"
    local method="dig"  # 可选值: dig, nslookup

    # 允许用户选择查询方式
    read -p "请选择查询方式 (dig/nslookup)，默认是 dig: " user_method
    if [[ "$user_method" == "dig" || "$user_method" == "nslookup" ]]; then
        method="$user_method"
    fi

    # 查询 IPv6 地址
    query_ipv6 "$domain" "$method"
}

# 执行主程序
main
