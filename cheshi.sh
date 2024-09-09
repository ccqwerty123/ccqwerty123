#!/bin/sh
export IPv4_ADDR=""  # 设置为空，表示没有IPv4地址
export IPv6_ADDR="2001:db8::1"  # 设置为一个示例IPv6地址

modify_dns_and_hosts() {
    ipv6_regex="^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$"

    if [ -z "$IPv4_ADDR" ] && [ -n "$IPv6_ADDR" ]; then
        echo "检测到只存在IPv6地址，是否将DNS设置为DNS64？"
        echo "1) 是（默认）"
        echo "2) 否"
        read -p "请选择 (1/2，默认为1): " dns_choice
        dns_choice=${dns_choice:-1}

        if [ "$dns_choice" = "1" ]; then
            echo "正在设置DNS为DNS64..."
            echo "nameserver 2606:4700:4700::64" | sudo tee /etc/resolv.conf
            echo "nameserver 2001:4860:4860::64" | sudo tee -a /etc/resolv.conf
            echo "DNS已设置为DNS64"
        else
            echo "保持当前DNS设置不变"
        fi
    fi

    if [ -n "$IPv6_ADDR" ]; then
        echo "检测到IPv6地址，尝试获取Google IPv6地址并添加到hosts文件"

        get_google_ipv6() {
            google_ipv6=""

            get_ipv6_with_nslookup() {
                nslookup -type=AAAA google.com 2>/dev/null | grep -E "$ipv6_regex" | awk '{print $NF}' | head -n 1
            }

            get_ipv6_with_host() {
                host -t AAAA google.com 2>/dev/null | grep -E "$ipv6_regex" | awk '{print $NF}' | head -n 1
            }

            get_ipv6_with_dig() {
                dig AAAA google.com +short 2>/dev/null | grep -E "$ipv6_regex" | head -n 1
            }

            get_ipv6_with_curl() {
                curl -6 -s 'https://ipv6.icanhazip.com' 2>/dev/null | grep -E "$ipv6_regex"
            }

            get_ipv6_with_wget() {
                wget -6 -qO - 'https://ipv6.icanhazip.com' 2>/dev/null | grep -E "$ipv6_regex"
            }

            # 尝试获取 IPv6 地址
            for method in get_ipv6_with_nslookup get_ipv6_with_host get_ipv6_with_dig get_ipv6_with_curl get_ipv6_with_wget; do
                if command -v "${method#get_ipv6_with_}" > /dev/null; then
                    google_ipv6=$($method)
                    if [ -n "$google_ipv6" ]; then
                        echo "获取到的谷歌 IPv6 地址: $google_ipv6"
                        
                        echo "请选择操作："
                        echo "1) 将此地址添加到 /etc/hosts"
                        echo "2) 使用备用地址：2607:f8b0:4004:c19::6a www.google.com"
                        echo "3) 退出脚本"
                        read -p "请输入选项 (1/2/3): " choice

                        case $choice in
                            1)
                                echo "$google_ipv6 google.com" | sudo tee -a /etc/hosts
                                echo "已将Google IPv6地址添加到hosts文件"
                                return
                                ;;
                            2)
                                echo "2607:f8b0:4004:c19::6a www.google.com" | sudo tee -a /etc/hosts
                                echo "已将备用地址添加到hosts文件"
                                return
                                ;;
                            3)
                                echo "退出脚本"
                                exit 0
                                ;;
                            *)
                                echo "无效选项，退出脚本"
                                exit 1
                                ;;
                        esac
                    fi
                fi
            done

            echo "很抱歉，无法获取到谷歌的 IPv6 地址。"
            echo "是否要使用备用地址？(2607:f8b0:4004:c19::6a)"
            read -p "请选择 (y/n): " use_backup
            if [ "$use_backup" = "y" ]; then
                echo "2607:f8b0:4004:c19::6a www.google.com" | sudo tee -a /etc/hosts
                echo "已将备用地址添加到hosts文件"
            else
                echo "未添加任何地址到hosts文件"
            fi
        }

        get_google_ipv6
    fi
}

# 调用函数
modify_dns_and_hosts
