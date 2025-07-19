#!/usr/bin/env python3
import subprocess
import os
import threading
import sys
import atexit
import re
import shlex
import psutil
import time
import shutil

# --- 1. 基础配置 ---

BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack'
OUTPUT_DIR = '/tmp/bitcrack_test_output'

# 测试用的地址和范围
BTC_ADDRESS = '19ZewH8Kk1PDbSNdJ97FP4EiCjTRaZMZQA'
KEYSPACE = '0000000000000000000000000000000000000000000000000000000000000001:000000000000000000000000000000000000000000000000000000000000FFFF'


# --- 2. 全局状态、管道与正则表达式 ---

FOUND_PRIVATE_KEY = None
FOUND_METHOD = "未找到"
key_found_event = threading.Event()
processes_to_cleanup = []

PIPE_BC = '/tmp/bitcrack_pipe' # 临时管道文件

# 正则表达式
STDOUT_PRIV_KEY_RE = re.compile(r'Priv:([0-9a-fA-F]{64})')
FILE_PRIV_KEY_RE = re.compile(r'([0-9a-fA-F]{64})')

# --- 3. 系统信息与硬件检测 ---

def display_system_info():
    """在主控窗口显示简要的系统信息"""
    print("--- 系统状态 (BitCrack 最终修复版) ---")
    try:
        # 【已修复】将 'total' 改回正确的 'memory.total'
        cmd = ['nvidia-smi', '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total', '--format=csv,noheader,nounits']
        gpu_info = subprocess.check_output(cmd, text=True).strip()
        gpu_data = gpu_info.split(', ')
        print(f"✅ GPU: {gpu_data[0]} | Temp: {gpu_data[1]}°C | Util: {gpu_data[2]}% | Mem: {gpu_data[3]}/{gpu_data[4]} MiB")
    except Exception:
        print("⚠️ GPU: 未检测到 NVIDIA GPU 或 nvidia-smi 不可用。")
    print("-" * 40)

def get_gpu_params():
    """尝试自动检测GPU，如果失败则回退到安全的默认值。"""
    print("INFO: 正在配置 GPU 性能参数...")
    default_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    try:
        result = subprocess.run(['nvidia-smi', '--query-gpu=multiprocessor_count', '--format=csv,noheader'], capture_output=True, text=True, check=True, env=os.environ)
        sm_count = int(result.stdout.strip())
        blocks, threads, points = sm_count * 7, 256, 1024
        print(f"INFO: 成功检测到 GPU。自动配置: -b {blocks} -t {threads} -p {points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}
    except Exception:
        print(f"WARN: 自动检测GPU失败，将使用已知可行的默认参数。")
        return default_params

# --- 4. 核心执行逻辑与【统一监控】 ---

def cleanup():
    """程序退出时，清理所有子进程。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        if p.poll() is None:
            try: p.terminate(); p.wait(timeout=2)
            except: p.kill()
    if os.path.exists(PIPE_BC): os.remove(PIPE_BC)
    print(f"[CLEANUP] 清理完成。")

atexit.register(cleanup)

def unified_monitor(file_path, pipe_path, bitcrack_process):
    """【统一监控循环】在一个线程里同时检查文件和屏幕输出。"""
    global FOUND_PRIVATE_KEY, FOUND_METHOD
    print("✅ [统一监控] 线程已启动，同时监控文件和屏幕...")
    try:
        with open(pipe_path, 'r') as fifo:
            os.set_blocking(fifo.fileno(), False)
            while not key_found_event.is_set():
                if os.path.exists(file_path) and os.path.getsize(file_path) > 0:
                    try:
                        with open(file_path, 'r') as f_check: match = FILE_PRIV_KEY_RE.search(f_check.read())
                        if match:
                            FOUND_PRIVATE_KEY, FOUND_METHOD = match.group(1).lower(), "文件读取"
                            key_found_event.set()
                            break
                    except IOError: pass
                try:
                    line = fifo.read()
                    if line:
                        match = STDOUT_PRIV_KEY_RE.search(line)
                        if match:
                            FOUND_PRIVATE_KEY, FOUND_METHOD = match.group(1).lower(), "屏幕输出"
                            key_found_event.set()
                            break
                except Exception: pass
                if bitcrack_process.poll() is not None:
                    print("[统一监控] 检测到 BitCrack 进程已结束。")
                    break
                time.sleep(0.3)
    except Exception: pass
    print("[统一监控] 监控循环结束。")

def main():
    """主函数，负责设置和启动测试任务。"""
    # 【已修复】在函数开头声明 global，解决 UnboundLocalError
    global FOUND_PRIVATE_KEY, FOUND_METHOD

    if not shutil.which('xfce4-terminal'):
        print("错误: 'xfce4-terminal' 未找到。"); sys.exit(1)

    display_system_info()
    time.sleep(1)

    try:
        print(f"INFO: 所有输出文件将被保存在: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        found_file, progress_file = os.path.join(OUTPUT_DIR, 'found_keys_test.txt'), os.path.join(OUTPUT_DIR, 'progress.dat')
        if os.path.exists(found_file): os.remove(found_file)

        gpu_params = get_gpu_params()
        print("="*40)
        
        bitcrack_command = [
            BITCRACK_PATH, '-b', str(gpu_params['blocks']), '-t', str(gpu_params['threads']),
            '-p', str(gpu_params['points']), '--keyspace', KEYSPACE, '-o', found_file,
            '--continue', progress_file, BTC_ADDRESS
        ]
        
        pipe_path = PIPE_BC
        if os.path.exists(pipe_path): os.remove(pipe_path)
        os.mkfifo(pipe_path)
        command_str = ' '.join(shlex.quote(arg) for arg in bitcrack_command)
        terminal_command_str = f"bash -c \"{command_str} | tee {pipe_path}; exec bash\""
        terminal_process = subprocess.Popen(['xfce4-terminal', '--title', '实时监控: BitCrack (GPU)', '-e', terminal_command_str])
        processes_to_cleanup.append(terminal_process)
        print(f"✅ BitCrack 已在新窗口启动...")
        
        monitor_thread = threading.Thread(target=unified_monitor, args=(found_file, pipe_path, terminal_process))
        monitor_thread.start()
        monitor_thread.join()
        
        if not FOUND_PRIVATE_KEY:
            print("INFO: 正在进行最终文件检查...")
            if os.path.exists(found_file) and os.path.getsize(found_file) > 0:
                with open(found_file, 'r') as f: match = FILE_PRIV_KEY_RE.search(f.read())
                if match:
                    FOUND_PRIVATE_KEY, FOUND_METHOD = match.group(1).lower(), "最终文件检查"
        
        print("\n" + "="*50)
        if FOUND_PRIVATE_KEY:
            print(f"🎉🎉🎉 测试成功！通过【{FOUND_METHOD}】捕获到密钥！🎉🎉🎉")
            print(f"\n  完整私钥 (HEX): {FOUND_PRIVATE_KEY}\n")
            print(f"  相关文件已保存至: {OUTPUT_DIR}")
        else:
            print("搜索任务已结束，但所有检查均未捕获到密钥。")
        print("="*50)

    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")

if __name__ == '__main__':
    main()
