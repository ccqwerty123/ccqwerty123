#!/bin/bash

# 日志级别: 0=ERROR, 1=INFO, 2=DEBUG
LOG_LEVEL=1

log() {
    local level=$1
    local message=$2
    if [[ $level -le $LOG_LEVEL ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >&2
    fi
}

get_google_ipv6() {
    local ipv6_regex="^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$"
    local google_ipv6=""
    local timeout=5

    get_ipv6_with_dig() {
        timeout $timeout dig aaaa google.com +short | grep -E "$ipv6_regex" | head -n 1
    }

    get_ipv6_with_curl() {
        timeout $timeout curl -6 -s 'https://ifconfig.co' | grep -Eo "$ipv6_regex" | head -n 1
    }

    get_ipv6_with_wget() {
        timeout $timeout wget -6 -qO - 'https://ifconfig.co' | grep -Eo "$ipv6_regex" | head -n 1
    }

    get_ipv6_with_ping6() {
        timeout $timeout ping6 -c 1 google.com 2>&1 | grep 'from' | sed 's/.*from \([0-9a-fA-F:]*\).*/\1/'
    }

    get_ipv6_with_getent() {
        timeout $timeout getent hosts google.com | grep -Eo "$ipv6_regex" | head -n 1
    }

    for method in get_ipv6_with_dig get_ipv6_with_curl get_ipv6_with_wget get_ipv6_with_ping6 get_ipv6_with_getent; do
        if command -v "${method:0:3}" &> /dev/null; then
            log 2 "Trying method: $method"
            google_ipv6=$($method)
            if [[ -n "$google_ipv6" ]]; then
                log 1 "Google IPv6 address obtained: $google_ipv6"
                echo "$google_ipv6"
                return 0
            fi
        fi
    done

    log 0 "Failed to obtain Google IPv6 address."
    return 1
}

modify_dns_and_hosts() {
    local IPv4_ADDR=$1
    local IPv6_ADDR=$2

    if [[ -z "$IPv4_ADDR" && -n "$IPv6_ADDR" ]]; then
        log 1 "Only IPv6 address exists, modifying DNS to DNS64"
        echo "nameserver 2606:4700:4700::64" | sudo tee /etc/resolv.conf
        echo "nameserver 2001:4860:4860::64" | sudo tee -a /etc/resolv.conf
    fi

    if [[ -n "$IPv6_ADDR" ]]; then
        log 1 "IPv6 address detected, attempting to get Google IPv6 address and add to hosts file"
        
        local google_ipv6=$(get_google_ipv6)
        
        if [[ -n "$google_ipv6" ]]; then
            log 1 "Choose operation:"
            log 1 "1) Add this address to /etc/hosts"
            log 1 "2) Use alternate address: 2607:f8b0:4004:c19::6a www.google.com"
            log 1 "3) Exit script"
            read -p "Enter option (1/2/3): " choice
            
            case $choice in
                1)
                    echo "$google_ipv6 google.com" | sudo tee -a /etc/hosts
                    log 1 "Google IPv6 address added to hosts file"
                    ;;
                2)
                    echo "2607:f8b0:4004:c19::6a www.google.com" | sudo tee -a /etc/hosts
                    log 1 "Alternate address added to hosts file"
                    ;;
                3)
                    log 1 "Exiting script"
                    exit 0
                    ;;
                *)
                    log 0 "Invalid option, exiting script"
                    exit 1
                    ;;
            esac
        else
            log 0 "Failed to obtain Google IPv6 address."
        fi
    fi
}

# 使用示例
IPv4_ADDR=""
IPv6_ADDR="2001:db8::1"
modify_dns_and_hosts "$IPv4_ADDR" "$IPv6_ADDR"
