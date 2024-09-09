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
        echo "$domain 的 IPv6 地址是:"
        echo "$ipv6_address"
        return 0
    fi
}

# 主程序
main() {
    install_tools

    while true; do
        # 一级菜单：选择查询方式或退出
        echo "请选择查询方式 (默认是 dig):"
        echo "1) dig"
        echo "2) nslookup"
        echo "3) 退出"
        read -p "请输入选项 (1/2/3): " method_choice

        case "$method_choice" in
            1|"")
                method="dig"
                ;;
            2)
                method="nslookup"
                ;;
            3)
                echo "退出程序。"
                break
                ;;
            *)
                echo "无效的选项，请重新选择。"
                continue
                ;;
        esac

        # 选择查询的域名
        read -p "请输入要查询的域名 (默认是 dldir1.qq.com): " user_domain
        domain="${user_domain:-dldir1.qq.com}"

        # 选择 DNS 服务器
        read -p "请输入 DNS 服务器 (默认是 2001:4860:4860::64): " user_dns
        dns_server="${user_dns:-2001:4860:4860::64}"

        # 查询 IPv6 地址
        query_ipv6 "$domain" "$dns_server" "$method"

        # 询问用户是否继续查询
        echo "是否继续查询?"
        echo "1) 是"
        echo "2) 否"
        read -p "请输入选项 (1/2): " continue_choice

        if [ "$continue_choice" != "1" ]; then
            echo "退出程序。"
            break
        fi
    done
}

# 执行主程序
main
