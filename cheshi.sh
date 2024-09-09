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
    local dns_server="$2"
    local method="$3"
    local ipv6_address=""

    if [ "$method" == "dig" ]; then
        if [ -n "$dns_server" ]; then
            ipv6_address=$(dig AAAA "$domain" @"$dns_server" +short)
        else
            ipv6_address=$(dig AAAA "$domain" +short)
        fi
    elif [ "$method" == "nslookup" ]; then
        if [ -n "$dns_server" ]; then
            ipv6_address=$(nslookup -query=AAAA "$domain" "$dns_server" | grep 'address' | awk '{print $2}')
        else
            ipv6_address=$(nslookup -query=AAAA "$domain" | grep 'address' | awk '{print $2}')
        fi
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

    while true; do
        # 默认值
        local domain="sohu.com"
        local dns_server=""
        local method="dig"  # 可选值: dig, nslookup

        # 允许用户输入域名
        read -p "请输入要查询的域名 (默认是 sohu.com): " user_domain
        if [ -n "$user_domain" ]; then
            domain="$user_domain"
        fi

        # 允许用户输入 DNS 服务器
        read -p "请输入 DNS 服务器 (留空使用默认 DNS): " user_dns
        if [ -n "$user_dns" ]; then
            dns_server="$user_dns"
        fi

        # 允许用户选择查询方式
        read -p "请选择查询方式 (dig/nslookup)，默认是 dig: " user_method
        if [[ "$user_method" == "dig" || "$user_method" == "nslookup" ]]; then
            method="$user_method"
        fi

        # 查询 IPv6 地址
        query_ipv6 "$domain" "$dns_server" "$method"

        # 询问用户是否继续查询
        read -p "是否继续查询? (y/n): " continue_choice
        if [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]]; then
            echo "退出程序。"
            break
        fi
    done
}

# 执行主程序
main
