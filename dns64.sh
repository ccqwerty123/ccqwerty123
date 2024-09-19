#!/bin/bash

# 指定要查询的域名和 DNS 服务器
domains=("dldir1.qq.com" "dlied4.csy.tcdnos.com" "vipspeedtest8.wuhan.net.cn")
dns_server="8.8.8.8"  # 默认使用 Google 的 DNS 服务器

# 如果要指定其他 DNS 服务器，可以修改上面的 dns_server 变量

for domain in "${domains[@]}"; do
  echo "正在查询 $domain 的 IPv6 地址..."

  # 尝试使用 dig 命令查询，设置 5 秒超时
  ipv6_addr=$(timeout 5 dig +short -@ $dns_server "$domain" AAAA 2>/dev/null)
  if [[ -n "$ipv6_addr" ]]; then
    echo "$domain 的 IPv6 地址为：$ipv6_addr"
    continue
  fi

  # 尝试使用 nslookup 命令查询，设置 DNS 服务器
  ipv6_addr=$(nslookup -querytype=AAAA "$domain" $dns_server 2>/dev/null | grep -oP '(?<=Address: )\S+')
  if [[ -n "$ipv6_addr" ]]; then
    echo "$domain 的 IPv6 地址为：$ipv6_addr"
    continue
  fi

  # 尝试使用 host 命令查询，设置 DNS 服务器
  ipv6_addr=$(host -T AAAA "$domain" $dns_server 2>/dev/null | awk '{print $NF}')
  if [[ -n "$ipv6_addr" ]]; then
    echo "$domain 的 IPv6 地址为：$ipv6_addr"
    continue
  fi

  echo "查询 $domain 失败" >> error.log
done
