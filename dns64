#!/bin/bash

domains=("dldir1.qq.com" "dlied4.csy.tcdnos.com" "vipspeedtest8.wuhan.net.cn")

for domain in "${domains[@]}"; do
  echo "正在查询 $domain 的 IPv6 地址..."

  # 尝试使用 dig 命令查询
  ipv6_addr=$(dig +short "$domain" AAAA 2>/dev/null)
  if [[ -n "$ipv6_addr" ]]; then
    echo "$domain 的 IPv6 地址为：$ipv6_addr"
    continue  # 如果查询成功，则跳过其他方法
  fi

  # 尝试使用 nslookup 命令查询
  ipv6_addr=$(nslookup -querytype=AAAA "$domain" 2>/dev/null | grep -oP '(?<=Address: )\S+')
  if [[ -n "$ipv6_addr" ]]; then
    echo "$domain 的 IPv6 地址为：$ipv6_addr"
    continue
  fi

  # 尝试使用 host 命令查询
  ipv6_addr=$(host -T AAAA "$domain" 2>/dev/null | awk '{print $NF}')
  if [[ -n "$ipv6_addr" ]]; then
    echo "$domain 的 IPv6 地址为：$ipv6_addr"
    continue
  fi

  echo "$domain 没有找到 IPv6 地址"
done
