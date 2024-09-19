#!/bin/bash

# 设置变量
DOMAIN="dldir1.qq.com"
FILE_PATH="/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
DOWNLOAD_TIME=10  # 指定下载时间（秒）
MAX_RETRIES=3
RETRY_DELAY=5

# 测试下载的函数
test_download() {
    local ipv6=$1
    local url="https://[$ipv6]$FILE_PATH"
    echo "测试下载：$url"

    for ((i=1; i<=MAX_RETRIES; i++)); do
        echo "下载尝试 $i/$MAX_RETRIES"
        
        # 下载指定时间
        response=$(curl -6 -o QQ9.7.17.29225.exe -H "Host: $DOMAIN" --max-time $DOWNLOAD_TIME "$url")

        if [ $? -eq 0 ]; then
            # 计算下载文件大小
            downloaded_size=$(stat -c%s "QQ9.7.17.29225.exe")
            echo "下载成功: $downloaded_size 字节"
            speed=$(echo "scale=2; $downloaded_size / $DOWNLOAD_TIME" | bc)
            echo "下载时间: $DOWNLOAD_TIME 秒, 速度: $speed 字节/秒"
            return 0
        else
            echo "下载失败，错误: $?"
            [ $i -lt $MAX_RETRIES ] && sleep $RETRY_DELAY
        fi
    done

    echo "下载在 $MAX_RETRIES 次尝试后仍失败"
    return 1
}

# 主函数
main() {
    local ipv6_addresses=("64:ff9b::cbcd:89eb" "64:ff9b::cbcd:89ea")

    for ipv6 in "${ipv6_addresses[@]}"; do
        echo "测试 IPv6 地址: $ipv6"
        test_download "$ipv6"
    done
}

# 调用主函数
main
