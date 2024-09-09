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

    if ! command -v curl &> /dev/null; then
        echo "未找到 curl，正在安装..."
        sudo apt-get update
        sudo apt-get install -y curl
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
            ipv6_address=$(dig AAAA "$domain" @"$dns_server" +short | grep -E '^[0-9a-fA-F:]+$')
        else
            ipv6_address=$(dig AAAA "$domain" +short | grep -E '^[0-9a-fA-F:]+$')
        fi
    elif [ "$method" == "nslookup" ]; then
        if [ -n "$dns_server" ]; then
            ipv6_address=$(nslookup -query=AAAA "$domain" "$dns_server" | grep 'address' | awk '{print $2}' | grep -E '^[0-9a-fA-F:]+$')
        else
            ipv6_address=$(nslookup -query=AAAA "$domain" | grep 'address' | awk '{print $2}' | grep -E '^[0-9a-fA-F:]+$')
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
        echo "$ipv6_address"
        return 0
    fi
}

# 清理指定文件夹中的文件
clean_directory() {
    local dir="$1"
    if [ -d "$dir" ]; then
        echo "清理文件夹: $dir"
        rm -rf "$dir"/*
    else
        echo "文件夹不存在，正在创建: $dir"
        mkdir -p "$dir"
    fi
}

# 使用 IPv6 地址下载文件并测试速度
# 使用 IPv6 地址下载文件并测试速度
download_with_ipv6() {
    local ipv6_address="$1"
    local url="$2"
    local download_dir="$3"

    # 提取协议和路径
    local protocol=$(echo "$url" | awk -F'://' '{print $1}')
    local path=$(echo "$url" | awk -F'://' '{print $2}' | awk -F'/' '{print substr($0, index($0,$2))}')

    # 构造新的URL
    local new_url="$protocol://[$ipv6_address]/$path"

    # 清理下载目录
    clean_directory "$download_dir"

    # 下载文件到指定目录
    local output_file="$download_dir/$(basename "$path")"
    echo "使用 IPv6 地址下载文件: $new_url"
    curl -6 -o "$output_file" -w "下载速度: %{speed_download} bytes/sec\n" -L "$new_url"

    # 清理下载目录
    clean_directory "$download_dir"
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
        if query_ipv6 "$domain" "$dns_server" "$method"; then
            ipv6_address=$(query_ipv6 "$domain" "$dns_server" "$method")

            # 询问用户是否进行测速
            echo "是否使用查询到的 IPv6 地址进行测速?"
            echo "1) 是"
            echo "2) 否"
            read -p "请输入选项 (1/2): " speed_test_choice

            if [ "$speed_test_choice" == "1" ]; then
                # 选择下载目录
                read -p "请输入下载目录 (默认是 /tmp/download_test): " download_dir
                download_dir="${download_dir:-/tmp/download_test}"

                # 选择下载的URL
                read -p "请输入要下载的文件URL (默认是 https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe): " download_url
                download_url="${download_url:-https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe}"

                # 使用 IPv6 地址下载文件并测试速度
                download_with_ipv6 "$ipv6_address" "$download_url" "$download_dir"
            fi
        fi

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
