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

# 下载文件并实时显示下载速度，限制下载时间
download_file() {
    local url=$1
    local duration=60  # 下载时间限制为60秒
    local temp_file=$(mktemp)
    local start=$(date +%s.%N)

    # 使用 timeout 限制下载时间
    timeout $duration curl -L -o "$temp_file" --progress-bar "$url" &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        sleep 1
        local current_size=$(stat -c%s "$temp_file")
        local current_time=$(date +%s.%N)
        local elapsed=$(echo "$current_time - $start" | bc)
        local speed=$(echo "scale=2; $current_size / $elapsed / 1024 / 1024" | bc)
        echo -ne "下载速度: ${speed} MB/s\r"
    done

    wait $pid
    local final_size=$(stat -c%s "$temp_file")
    local end=$(date +%s.%N)
    local total_time=$(echo "$end - $start" | bc)
    local final_speed=$(echo "scale=2; $final_size / $total_time / 1024 / 1024" | bc)
    echo -e "\n下载完成，平均速度: ${final_speed} MB/s"

    rm -f "$temp_file"
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
    
    download_file $ipv6_url
}

main
