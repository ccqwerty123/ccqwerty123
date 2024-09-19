#!/bin/bash

# 设置变量
URL="https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
DOMAIN="dldir1.qq.com"
IPV6_ADDRESSES=("64:ff9b::cbcd:89eb" "64:ff9b::cbcd:89ea")
TEST_DURATION=10

# 测试函数
test_download() {
    local method=$1
    local ipv6=$2
    local cmd=$3
    
    echo "使用方法 $method 测试 IPv6 地址: $ipv6"
    eval "$cmd"
    echo "------------------------"
}

# 清理函数
cleanup() {
    rm -f /tmp/test_download
    [ -n "$HOSTS_MODIFIED" ] && sed -i "/$DOMAIN/d" /etc/hosts
}

trap cleanup EXIT

# 测试循环
for ipv6 in "${IPV6_ADDRESSES[@]}"; do
    # 方法1：直接使用 IPv6 地址
    test_download "直接 IPv6" "$ipv6" "curl -6 -m $TEST_DURATION -o /tmp/test_download -w 'Speed: %{speed_download} bytes/sec\n' 'https://[$ipv6]/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe'"

    # 方法2：使用 Host 头
    test_download "Host 头" "$ipv6" "curl -6 -H 'Host: $DOMAIN' -m $TEST_DURATION -o /tmp/test_download -w 'Speed: %{speed_download} bytes/sec\n' 'https://[$ipv6]/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe'"

    # 方法3：修改 /etc/hosts 文件
    echo "$ipv6 $DOMAIN" >> /etc/hosts
    HOSTS_MODIFIED=1
    test_download "hosts 文件" "$ipv6" "curl -6 -m $TEST_DURATION -o /tmp/test_download -w 'Speed: %{speed_download} bytes/sec\n' '$URL'"
    sed -i "/$DOMAIN/d" /etc/hosts
    HOSTS_MODIFIED=

    # 方法4：使用 wget
    test_download "wget" "$ipv6" "wget -6 -O /tmp/test_download '$URL' 2>&1 | grep 'average speed'"

    # 方法5：使用 aria2c
    if command -v aria2c &> /dev/null; then
        test_download "aria2c" "$ipv6" "aria2c -x16 -s16 --summary-interval=1 -d /tmp -o test_download '$URL'"
    else
        echo "aria2c 未安装，跳过此测试"
    fi
done
