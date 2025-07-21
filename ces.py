#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import subprocess
import os

def display_gpu_info():
    """
    调用 nvidia-smi，显示 GPU 的名称、温度、利用率和显存使用情况。
    """
    try:
        cmd = [
            'nvidia-smi',
            '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total',
            '--format=csv,noheader,nounits'
        ]
        output = subprocess.check_output(cmd, text=True).strip()
        name, temp, util, mem_used, mem_total = [x.strip() for x in output.split(',')]
        print(f"✅ GPU: {name}")
        print(f"   - 温度:    {temp} °C")
        print(f"   - 利用率:  {util} %")
        print(f"   - 显存:    {mem_used} / {mem_total} MiB")
    except Exception as e:
        print("⚠️ 无法获取 GPU 信息，请检查是否安装了 NVIDIA 驱动及 nvidia-smi 是否可用。")
        print(f"   详细错误: {e}")

def get_gpu_params():
    """
    根据多处理器数量 (SM count) 计算参数 blocks、threads、points。
    如果检测失败，则返回默认值。
    """
    default = {'blocks': 288, 'threads': 256, 'points': 1024}
    try:
        cmd = [
            'nvidia-smi',
            '--query-gpu=multiprocessor_count',
            '--format=csv,noheader,nounits'
        ]
        sm_str = subprocess.check_output(cmd, text=True).strip()
        if not sm_str.isdigit():
            raise ValueError(f"返回值非整数: '{sm_str}'")
        sm = int(sm_str)
        # 假设每个 SM 启用 7 个 block
        blocks = sm * 7
        threads = 256
        points  = 1024
        print("✅ 自动检测到 GPU 多处理器数量 (SM count):", sm)
        print("   -> 自动配置参数:")
        print(f"      blocks = {blocks}")
        print(f"      threads = {threads}")
        print(f"      points  = {points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}
    except Exception as e:
        print("⚠️ GPU 参数自动检测失败，将使用默认参数。")
        print(f"   详细错误: {e}")
        print("   默认配置:")
        print(f"      blocks = {default['blocks']}")
        print(f"      threads = {default['threads']}")
        print(f"      points  = {default['points']}")
        return default

def main():
    print("-" * 40)
    print("          GPU 参数检测脚本")
    print("-" * 40)
    display_gpu_info()
    print("-" * 40)
    get_gpu_params()
    print("-" * 40)

if __name__ == "__main__":
    main()
