#!/bin/bash

set -e

LOG_LEVEL=2  # 0=ERROR, 1=INFO, 2=DEBUG

log() {
    local level=$1
    local message=$2
    if [[ $level -le $LOG_LEVEL ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >&2
    fi
}

check_ipv6_support() {
    if [[ -f /proc/net/if_inet6 ]]; then
        log 1 "IPv6 is supported on this system."
        return 0
    else
        log 0 "IPv6 is not supported on this system."
        return 1
    fi
}

get_current_ipv6() {
    local ipv6=$(ip -6 addr show scope global | grep -oP '(?<=inet6\s)[0-9a-fA-F:]+')
    if [[ -n "$ipv6" ]]; then
        log 1 "Current IPv6 address: $ipv6"
        echo "$ipv6"
        return 0
    else
        log 0 "No global IPv6 address found."
        return 1
    fi
}

test_ipv6_connectivity() {
    if ping6 -c 3 google.com &> /dev/null; then
        log 1 "IPv6 connectivity to google.com is working."
        return 0
    else
        log 0 "Cannot reach google.com via IPv6."
        return 1
    fi
}

get_google_ipv6() {
    local google_ipv6=$(dig AAAA google.com +short)
    if [[ -n "$google_ipv6" ]]; then
        log 1 "Google's IPv6 address: $google_ipv6"
        echo "$google_ipv6"
        return 0
    else
        log 0 "Failed to get Google's IPv6 address."
        return 1
    fi
}

modify_dns_and_hosts() {
    log 1 "Modifying DNS to use DNS64"
    echo "nameserver 2606:4700:4700::64" | sudo tee /etc/resolv.conf > /dev/null
    echo "nameserver 2001:4860:4860::64" | sudo tee -a /etc/resolv.conf > /dev/null
    log 1 "DNS modified successfully."

    local google_ipv6=$(get_google_ipv6)
    if [[ -n "$google_ipv6" ]]; then
        log 1 "Adding Google's IPv6 address to /etc/hosts"
        echo "$google_ipv6 google.com" | sudo tee -a /etc/hosts > /dev/null
        log 1 "Hosts file updated successfully."
    else
        log 0 "Failed to add Google's IPv6 to hosts file."
    fi
}

main() {
    log 1 "Starting IPv6 configuration script"

    if ! check_ipv6_support; then
        log 0 "Exiting due to lack of IPv6 support."
        exit 1
    fi

    local current_ipv6=$(get_current_ipv6)
    if [[ -z "$current_ipv6" ]]; then
        log 0 "No IPv6 address available. Please check your network configuration."
        exit 1
    fi

    if ! test_ipv6_connectivity; then
        log 1 "IPv6 connectivity issue detected. Attempting to modify DNS and hosts."
        modify_dns_and_hosts
    else
        log 1 "IPv6 is working correctly. No changes needed."
    fi

    log 1 "Script execution completed."
}

main
