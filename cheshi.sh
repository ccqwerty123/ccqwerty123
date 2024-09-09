#!/bin/bash

get_ipv6_address() {
    local domain=$1
    dig @2001:4860:4860::6464 AAAA $domain +short
}

replace_domain_with_ipv6() {
    local url=$1
    local ipv6=$2
    local protocol=$(echo $url | grep :// | sed -e's,^\(.*://\).*,\1,g')
    local domain=$(echo $url | sed -e s,$protocol,,g | cut -d/ -f1)
    local path=$(echo $url | sed -e s,$protocol,,g | cut -d/ -f2-)
    echo "${protocol}[${ipv6}]/${path}"
}

download_file() {
    local url=$1
    local start=$(date +%s.%N)
    local size=$(curl -s -o /dev/null -w "%{size_download}" "$url")
    local end=$(date +%s.%N)
    local duration=$(echo "$end - $start" | bc)
    local speed=$(echo "scale=2; $size / $duration / 1024 / 1024" | bc)
    echo $speed
}

main() {
    read -p "请输入要测试的URL: " url
    domain=$(echo $url | sed -e 's,^.*://,,g' | cut -d/ -f1 | cut -d: -f1)
    
    ipv6_address=$(get_ipv6_address $domain)
    if [ -z "$ipv6_address" ]; then
        echo "无法获取 $domain 的IPv6地址"
        exit 1
    fi
    
    ipv6_url=$(replace_domain_with_ipv6 $url $ipv6_address)
    echo "IPv6 URL: $ipv6_url"
    
    speed=$(download_file $ipv6_url)
    echo "下载速度: ${speed} MB/s"
}

main
