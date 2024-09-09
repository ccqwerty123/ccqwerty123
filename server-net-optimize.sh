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
        echo "检测到IPv6地址，尝试获取Google IPv6地址..."

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
                        handle_google_ipv6 "$google_ipv6"
                        return
                    else
                        echo "使用 $method 未能获取到IPv6地址"
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

        handle_google_ipv6() {
            local ipv6_address="$1"
            echo "请选择操作："
            echo "1) 将此地址添加到 /etc/hosts"
            echo "2) 使用备用地址：2607:f8b0:4004:c19::6a www.google.com"
            echo "3) 返回主菜单"
            read -p "请输入选项 (1/2/3): " choice

            case $choice in
                1)
                    echo "$ipv6_address google.com" | sudo tee -a /etc/hosts
                    echo "已将Google IPv6地址添加到hosts文件"
                    ;;
                2)
                    echo "2607:f8b0:4004:c19::6a www.google.com" | sudo tee -a /etc/hosts
                    echo "已将备用地址添加到hosts文件"
                    ;;
                3)
                    echo "返回主菜单"
                    return
                    ;;
                *)
                    echo "无效选项，请重新选择。"
                    handle_google_ipv6 "$ipv6_address"
                    ;;
            esac
        }

        get_google_ipv6
    fi
}





manage_swap() {
    while true; do
        echo -e "\n当前系统状态："

        # 显示交换空间使用情况
        if command -v swapon &> /dev/null; then
            swap_info=$(swapon --show=NAME,SIZE,USED --noheadings)
            if [[ -n "$swap_info" ]]; then
                echo -e "交换空间存在，使用情况如下："
                echo "$swap_info"
            else
                echo "当前没有启用的交换空间。"
            fi
        else
            echo "swapon 命令不可用，无法检测交换空间。"
        fi

        # 显示磁盘空间使用情况
        if command -v df &> /dev/null; then
            disk_info=$(df -h --output=source,size,used,avail,pcent | grep -E '^/dev/')
            if [[ -n "$disk_info" ]]; then
                echo -e "\n磁盘使用情况："
                echo "$disk_info"
            else
                echo "无法获取磁盘使用情况，或没有已挂载的磁盘。"
            fi
        else
            echo "df 命令不可用，无法检测磁盘使用情况。"
        fi

        # 显示内存使用情况
        if command -v free &> /dev/null; then
            memory_info=$(free -h --si | awk '/^Mem:/ {print "内存：" $3 " 已用 / " $2 " 总量"}')
            swap_memory_info=$(free -h --si | awk '/^Swap:/ {print "交换空间：" $3 " 已用 / " $2 " 总量"}')
            echo -e "\n内存使用情况："
            echo "$memory_info"
            echo "$swap_memory_info"
        else
            echo "free 命令不可用，无法检测内存使用情况。"
        fi

        # 打印操作菜单
        echo -e "\n请选择操作：\n1) 设置交换空间\n2) 设置内核参数\n3) 退出"
        read -rp "输入选项编号: " choice

        case $choice in
            1) manage_swap_space ;;
            2) set_kernel_parameters ;;
            3) echo "退出"; break ;;
            *) echo "无效选项，请重新选择" ;;
        esac
    done
}
 

validate_input() {
    local prompt="$1"
    local default="$2"
    local min="$3"
    local max="$4"
    local value

    while true; do
        read -rp "$prompt (默认 $default): " value
        value=${value:-$default}
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
            echo "$value"
            return
        else
            echo "无效输入，请输入 $min 到 $max 之间的整数"
        fi
    done
}

manage_swap_space() {
    echo -e "\n选择交换空间操作：\n1) 创建交换空间\n2) 删除交换空间"
    read -rp "输入选项编号: " swap_choice

    case $swap_choice in
        1)
            read -rp "输入交换文件路径（默认 /swapfile）: " swapfile
            swapfile=${swapfile:-/swapfile}
            size=$(validate_input "输入交换文件大小（MB）" 1024 1 1048576)

            if [[ -f "$swapfile" ]]; then
                echo "错误：交换文件 $swapfile 已存在"; return 1
            fi

            # 创建交换文件
            sudo dd if=/dev/zero of="$swapfile" bs=1M count="$size" status=progress
            sudo chmod 600 "$swapfile"
            sudo mkswap "$swapfile" && sudo swapon "$swapfile"
            echo "$swapfile none swap sw 0 0" | sudo tee -a /etc/fstab

            echo "交换空间已创建并启用"
            ;;
        2)
            current_swap=$(swapon --show=NAME --noheadings | grep '^/')
            if [[ -z "$current_swap" ]]; then
                echo "未找到任何启用的交换文件"; return 1
            fi

            sudo swapoff "$current_swap" && sudo rm -f "$current_swap"
            sudo sed -i "\|$current_swap|d" /etc/fstab

            echo "交换空间已关闭并删除"
            ;;
        *)
            echo "无效选项，请重新选择"
            ;;
    esac
}

set_kernel_parameters() {
    echo -e "\n设置内核参数："

    # 说明 vm.swappiness 参数
    echo -e "\n1. vm.swappiness: 该参数控制系统使用交换空间的倾向。"
    echo "   值越低，系统越倾向于使用物理内存。"
    echo "   取值范围：0-100，默认值为10。"
    swappiness=$(validate_input "设置 vm.swappiness" 10 0 100)

    # 说明 vm.vfs_cache_pressure 参数
    echo -e "\n2. vm.vfs_cache_pressure: 该参数控制内核回收用于缓存inode和dentry信息的内存倾向。"
    echo "   值越高，系统越倾向于回收这些缓存以释放内存。"
    echo "   取值范围：0-1000，默认值为75。"
    vfs_cache_pressure=$(validate_input "设置 vm.vfs_cache_pressure" 75 0 1000)

    # 说明 vm.min_free_kbytes 参数
    echo -e "\n3. vm.min_free_kbytes: 该参数定义了系统在内存不足时要保留的最小内存量。"
    echo "   该值通常根据系统总内存量进行调整，以确保系统在内存紧张时能够正常运行。"
    echo "   取值范围：1024-262144，默认值为32768。"
    min_free_kbytes=$(validate_input "设置 vm.min_free_kbytes" 32768 1024 262144)

    # 设置内核参数
    sudo sysctl -w vm.swappiness="$swappiness" \
                 vm.vfs_cache_pressure="$vfs_cache_pressure" \
                 vm.min_free_kbytes="$min_free_kbytes"

    # 将参数写入 /etc/sysctl.conf 以便重启后生效
    echo -e "vm.swappiness = $swappiness\nvm.vfs_cache_pressure = $vfs_cache_pressure\nvm.min_free_kbytes = $min_free_kbytes" | sudo tee -a /etc/sysctl.conf

    echo "内核参数已设置"
}



# 主函数
main() {
    detect_os
    check_ip
    modify_dns_and_hosts
    manage_swap
}

# 执行主函数
main
