#!/bin/bash

# 检查是否有 IPv4 地址
ipv4_address=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# 检查是否有 IPv6 地址
ipv6_address=$(ip -6 addr show | grep -oP '(?<=inet6\s)[\da-f:]+')

# 检查网络环境并输出结果
if [[ -n "$ipv4_address" && -n "$ipv6_address" ]]; then
    echo "此服务器是双栈服务器 (IPv4 和 IPv6)。"
    echo "IPv4 地址: $ipv4_address"
    echo "IPv6 地址: $ipv6_address"
elif [[ -n "$ipv4_address" ]]; then
    echo "此服务器是纯 IPv4 服务器。"
    echo "IPv4 地址: $ipv4_address"
elif [[ -n "$ipv6_address" ]]; then
    echo "此服务器是纯 IPv6 服务器。"
    echo "IPv6 地址: $ipv6_address"
else
    echo "此服务器没有配置 IPv4 或 IPv6 地址。"
fi
