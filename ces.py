#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import subprocess
import os
import re

def get_gpu_params():
    """更健壮地自动检测 GPU，如果失败则回退到安全的默认值。"""
    print("INFO: 正在配置 GPU 性能参数…")
    default_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    try:
        cmd = [
            'nvidia-smi',
            '--query-gpu=multiprocessor_count',
            '--format=csv,noheader'
        ]
        res = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True,
            env=os.environ
        )
        raw = res.stdout
        print(f"DEBUG: nvidia-smi 原始输出: {repr(raw)}")

        # 使用正则从输出中提取第一个数字
        match = re.search(r"\d+", raw)
        if not match:
            raise ValueError(f"无法从输出中抽取数字: {repr(raw)}")

        sm_count = int(match.group())
        blocks = sm_count * 7
        threads = 256
        points = 1024

        print(f"INFO: 成功检测到 GPU：multiprocessor_count = {sm_count}")
        print(f"INFO: 自动配置参数 → blocks: {blocks}, threads: {threads}, points: {points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}

    except Exception as e:
        print(f"WARN: 自动检测 GPU 失败，使用默认参数。原因: {e}")
        print(f"WARN: 默认参数 → blocks: {default_params['blocks']}, threads: {default_params['threads']}, points: {default_params['points']}")
        return default_params

if __name__ == "__main__":
    params = get_gpu_params()
    print("\n最终返回值:", params)
