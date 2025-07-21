#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import subprocess
import shlex
import argparse
from typing import Dict, List

def display_system_info():
    """在主控窗口显示简要的系统信息"""
    print("--- 系统状态 (BitCrack 最终修复版) ---")
    try:
        cmd = [
            'nvidia-smi',
            '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total',
            '--format=csv,noheader,nounits'
        ]
        gpu_info = subprocess.check_output(cmd, text=True).strip()
        # 假设只显示第一块 GPU
        name, temp, util, used, total = map(str.strip, gpu_info.split(',')[0:5])
        print(
            f"✅ GPU: {name} | Temp: {temp}°C | Util: {util}% | "
            f"Mem: {used}/{total} MiB"
        )
    except Exception:
        print("⚠️ GPU: 未检测到 NVIDIA GPU 或 nvidia-smi 不可用。")
    print("-" * 40)

def query_all_gpus() -> List[Dict[str, int]]:
    """
    返回所有 GPU 的指标列表，每个元素为 dict：
      - index, sm_count, temp, util, mem_used, mem_total
    抛出 RuntimeError 表示查询失败。
    """
    cmd = [
        "nvidia-smi",
        "--query-gpu=index,multiprocessor_count,temperature.gpu,utilization.gpu,"
        "memory.used,memory.total",
        "--format=csv,noheader,nounits"
    ]
    try:
        out = subprocess.check_output(cmd, text=True).strip().splitlines()
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"nvidia-smi 调用失败: {e}") from e

    gpus = []
    for line in out:
        idx, sm, temp, util, mu, mt = map(int, map(str.strip, line.split(",")))
        gpus.append({
            "index": idx,
            "sm_count": sm,
            "temp": temp,
            "util": util,
            "mem_used": mu,
            "mem_total": mt
        })
    return gpus

def choose_params(
    info: Dict[str, int],
    mem_thresh: int = 10000,
    temp_thresh: int = 80,
    util_thresh: int = 80,
    base_factor: int = 7,
    safe_factor: int = 5
) -> Dict[str, int]:
    """
    根据单块 GPU 指标选取 blocks/threads/points。
    返回字典：{"blocks":…, "threads":…, "points":…}
    """
    free_mem = info["mem_total"] - info["mem_used"]
    threads = 512 if free_mem >= mem_thresh else 256
    factor = safe_factor if (info["temp"] > temp_thresh or info["util"] > util_thresh) else base_factor
    blocks = info["sm_count"] * factor
    # 假设 1 point 占 1 MiB，用一半 free_mem，再限制范围
    raw_points = free_mem // 2
    points = max(256, min(raw_points, 4096))
    return {"blocks": blocks, "threads": threads, "points": points}

def build_command(
    params: Dict[str, int],
    executable: str,
    keyspace: str,
    password: str,
    output: str,
    cont: str
) -> str:
    """
    用 shlex.join 拼接安全的命令行字符串
    """
    cmd_list = [
        executable,
        "-b", str(params["blocks"]),
        "-t", str(params["threads"]),
        "-p", str(params["points"]),
        "--keyspace", keyspace,
        password,
        "-o", output,
        "--continue", cont
    ]
    return shlex.join(cmd_list)

def main():
    # 先打印系统（GPU）状态
    display_system_info()

    parser = argparse.ArgumentParser(description="自动生成 cuBitCrack 命令行")
    parser.add_argument(
        "--exe",
        default="/workspace/BitCrack/bin/cuBitCrack",
        help="cuBitCrack 可执行文件路径"
    )
    parser.add_argument("--keyspace", required=True, help="指定 keyspace 范围")
    parser.add_argument("--password", required=True, help="指定已知的 password")
    parser.add_argument(
        "--out",
        default="./found_keys.txt",
        help="破解到的 key 输出文件"
    )
    parser.add_argument(
        "--cont",
        default="./progress.txt",
        help="进度记录文件"
    )
    args = parser.parse_args()

    # 尝试查询所有 GPU
    try:
        gpus = query_all_gpus()
    except RuntimeError as e:
        print("⚠️ 获取 GPU 信息失败，使用默认参数:", e)
        # 默认值：blocks=288, threads=256, points=1024
        params = {"blocks": 288, "threads": 256, "points": 1024}
    else:
        # 这里只选第 0 块 GPU，也可以根据 index 选择或遍历
        params = choose_params(gpus[0])

    cmd = build_command(
        params,
        executable=args.exe,
        keyspace=args.keyspace,
        password=args.password,
        output=args.out,
        cont=args.cont
    )

    print("生成的 cuBitCrack 命令：")
    print(cmd)

if __name__ == "__main__":
    main()
