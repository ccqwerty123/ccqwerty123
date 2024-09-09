#!/bin/bash

# 检查是否为有效的IPv6地址
is_valid_ipv6() {
    local ip=$1
    if [[ $ip =~ : ]]; then
        ip -6 addr add $ip/128 dev lo 2>/dev/null
        if [ $? -eq 0 ]; then
            ip -6 addr del $ip/128 dev lo
            return 0
        fi
    fi
    return 1
}

# 获取域名的IPv6地址
get_ipv6_address() {
    local domain=$1
    local dns_server="2001:4860:4860::6464"  # 默认使用Google的DNS64服务器
    local result=$(dig AAAA +short @$dns_server $domain +timeout=5)
    for ip in $result; do
        if is_valid_ipv6 "$ip"; then
            echo "$ip"
            return
        fi
    done
    echo ""
}

# 将URL中的域名替换为IPv6地址
replace_domain_with_ipv6() {
    local url=$1
    local ipv6=$2
    local protocol=$(echo $url | grep :// | sed -e 's,^\(.*://\).*,\1,g')
    local domain=$(echo $url | sed -e "s,$protocol,,g" | cut -d/ -f1)
    local path=$(echo $url | sed -e "s,$protocol,,g" | cut -d/ -f2-)
    echo "${protocol}[${ipv6}]/${path}"
}

# 下载文件并计算下载速度
download_file() {
    local url=$1
    local start=$(date +%s.%N)
    local size=$(curl -s -L -o /dev/null -w "%{size_download}" "$url")
    local end=$(date +%s.%N)
    local duration=$(echo "$end - $start" | bc)
    if [ -z "$size" ] || [ -z "$duration" ] || [ $(echo "$duration == 0" | bc) -eq 1 ]; then
        echo "error"
    else
        echo "scale=2; $size / $duration / 1024 / 1024" | bc
    fi
}

main() {
    local default_url="https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
    
    read -p "请输入要测试的URL (按Enter使用默认地址): " url
    url=${url:-$default_url}
    
    domain=$(echo $url | sed -e 's,^.*://,,g' | cut -d/ -f1 | cut -d: -f1)
    
    ipv6_address=$(get_ipv6_address $domain)
    if [ -z "$ipv6_address" ]; then
        echo "无法获取 $domain 的有效IPv6地址"
        exit 1
    fi
    
    echo "$domain 的 IPv6 地址是: $ipv6_address"
    
    ipv6_url=$(replace_domain_with_ipv6 $url $ipv6_address)
    echo "IPv6 URL: $ipv6_url"
    
    speed=$(download_file $ipv6_url)
    if [ "$speed" = "error" ]; then
        echo "下载测试失败"
    else
        echo "下载速度: ${speed} MB/s"
    fi
}

main
