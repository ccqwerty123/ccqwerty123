#!/bin/bash

# 检查是否为有效的IPv6地址
is_valid_ipv6() {
    local ip=$1
    if [[ $ip =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$ ]] || 
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,7}:$ ]] || 
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}$ ]] || 
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}$ ]] || 
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}$ ]] || 
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}$ ]] || 
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}$ ]] || 
       [[ $ip =~ ^[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})$ ]] || 
       [[ $ip =~ ^:((:[0-9a-fA-F]{1,4}){1,7}|:)$ ]] || 
       [[ $ip =~ ^fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}$ ]] || 
       [[ $ip =~ ^::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$ ]] || 
       [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$ ]]; then
        return 0
    else
        return 1
    fi
}

# 获取域名的IPv6地址
# 获取域名的IPv6地址
get_ipv6_address() {
    local domain=$1
    local dns_server="2001:4860:4860::6464"  # 默认使用Google的DNS64服务器
    echo "使用的DNS服务器: $dns_server"
    local result=$(dig AAAA +short @$dns_server $domain)
    echo "DNS查询返回的结果: $result"
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
# 下载文件并计算下载速度
download_file() {
    local url=$1
    local start=$(date +%s.%N)
    local size=$(curl -s -o /dev/null -w "%{size_download}" "$url")
    local end=$(date +%s.%N)
    local duration=$(echo "$end - $start" | bc)
    if [ -z "$size" ] || [ -z "$duration" ] || [ $(echo "$duration == 0" | bc) -eq 1 ]; then
        echo "error"
    else
        echo "scale=2; $size / $duration / 1024 / 1024" | bc
    fi
}

main() {
    read -p "请输入要测试的URL: " url
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
