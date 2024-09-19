#!/bin/bash

function query_ipv6() {
    local domain="$1"
    local dns64="2001:4860:4860::6464"

    # 先尝试直接查询 IPv6 地址
    ipv6_addr=$(dig +short -@ $dns64 "$domain" AAAA 2>/dev/null)

    # 如果没有找到 IPv6 地址，再尝试使用 DNS64 合成
    if [[ -z "$ipv6_addr" ]]; then
        echo "域名 $domain 没有找到原生 IPv6 地址，尝试使用 DNS64 合成..."
        ipv6_addr=$(dig +short -@ $dns64 "$domain" A | awk '{print "64:ff9b::"$0}')
    fi

    if [[ -z "$ipv6_addr" ]]; then
        echo "域名 $domain 无法解析到 IPv6 地址"
    else
        echo "$domain 的 IPv6 地址为：$ipv6_addr"
    fi
}

# 示例用法
domains=("dldir1.qq.com" "dlied4.csy.tcdnos.com" "vipspeedtest8.wuhan.net.cn")

for domain in "${domains[@]}"; do
    query_ipv6 "$domain"
done
