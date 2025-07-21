#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import subprocess
import re
import shlex

def query_gpu():
    """
    返回一个 dict，包括
      - sm_count    : multiprocessor_count
      - temp        : temperature.gpu (°C)
      - util        : utilization.gpu (%)
      - mem_used    : memory.used (MiB)
      - mem_total   : memory.total (MiB)
    """
    cmd = [
        "nvidia-smi",
        "--query-gpu=multiprocessor_count,temperature.gpu,utilization.gpu,memory.used,memory.total",
        "--format=csv,noheader,nounits"
    ]
    out = subprocess.check_output(cmd, text=True).strip()
    # 例如 out = "16, 65, 10, 2048, 8192"
    parts = [p.strip() for p in out.split(",")]
    sm_count, temp, util, mem_used, mem_total = map(int, parts)
    return {
        "sm_count": sm_count,
        "temp":     temp,
        "util":     util,
        "mem_used": mem_used,
        "mem_total": mem_total
    }

def choose_params(info):
    """
    根据 info 来选择 -b, -t, -p 参数。
    这里仅给出一个示例策略，你可以自由修改。
    """
    sm = info["sm_count"]
    free_mem = info["mem_total"] - info["mem_used"]

    # 基础 thread 数通常是 128/256/512，看显存和 SM 数来选
    if free_mem >= 10000:
        threads = 512
    else:
        threads = 256

    # blocks 用 SM 数 * factor
    # 如果 GPU 温度过高或利用率已高，就用保守点的 factor
    if info["temp"] > 80 or info["util"] > 80:
        factor = 5
    else:
        factor = 7
    blocks = sm * factor

    # points 数量取决于可用显存：
    # 假设每 point 占用 1KB，我们给它 50% 的 free_mem
    # （这里只是举例）
    points = int((free_mem * 1024 // 2) / 1024)  # MiB -> KB, 然后 /1KB
    # 再确保在一个合理区间
    points = max(256, min(points, 4096))

    return blocks, threads, points

def build_command(blocks, threads, points):
    """
    拼接最后要输出的 cuBitCrack 命令行。
    """
    base = "/workspace/BitCrack/bin/cuBitCrack"
    keyspace = ("0000000000000000000000000000000000000000000000599999aabcacda0001:"
                "00000000000000000000000000000000000000000000005e666674ae4bc6aaab")
    password = "1PWo3JeB9jrGwfHDNpdGK54CRas7fsVzXU"
    out_file = "/workspace/BitCrack/found_keys_server2.txt"
    cont_file = "/workspace/BitCrack/progress_server2.txt"

    cmd = (
        f"{base} "
        f"-b {blocks} -t {threads} -p {points} "
        f"--keyspace {keyspace} {password} "
        f"-o {out_file} "
        f"--continue {cont_file}"
    )
    return cmd

def main():
    try:
        info = query_gpu()
    except Exception as e:
        print("⚠️ 读取 GPU 信息失败，使用默认参数。", e)
        blocks, threads, points = 288, 256, 1024
    else:
        blocks, threads, points = choose_params(info)

    cmd = build_command(blocks, threads, points)
    # 最终只 print，不执行
    print("生成的 cuBitCrack 命令：")
    print(cmd)

if __name__ == "__main__":
    main()
