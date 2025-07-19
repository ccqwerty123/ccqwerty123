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

# --- 1. 基础配置 (用于 BitCrack 快速测试) ---

BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack'

# 【已修复】直接在当前工作区创建输出目录，彻底避免权限问题
OUTPUT_DIR = '/workspace/bitcrack_test_output'

# 用于快速找到密钥的测试地址和范围
BTC_ADDRESS = '19ZewH8Kk1PDbSNdJ97FP4EiCjTRaZMZQA'
KEYSPACE = '0000000000000000000000000000000000000000000000000000000000000001:000000000000000000000000000000000000000000000000000000000000FFFF'


# --- 2. 全局状态、管道与正则表达式 ---

FOUND_PRIVATE_KEY = None
key_found_event = threading.Event()
processes_to_cleanup = []

PIPE_BC = '/tmp/bitcrack_pipe' # 临时管道文件

# cuBitCrack 的私钥正则表达式
CUBITCRACK_PRIV_KEY_RE = re.compile(r'Priv:([0-9a-fA-F]{64})')

# --- 3. 系统信息与硬件检测 ---

def display_system_info():
    """在主控窗口显示简要的系统信息"""
    print("--- 系统状态 (BitCrack 测试模式) ---")
    try:
        cmd = ['nvidia-smi', '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total', '--format=csv,noheader,nounits']
        gpu_info = subprocess.check_output(cmd, text=True).strip()
        gpu_data = gpu_info.split(', ')
        print(f"✅ GPU: {gpu_data[0]} | Temp: {gpu_data[1]}°C | Util: {gpu_data[2]}% | Mem: {gpu_data[3]}/{gpu_data[4]} MiB")
    except Exception:
        print("⚠️ GPU: 未检测到 NVIDIA GPU 或 nvidia-smi 不可用。")
    print("-" * 35)

def get_gpu_params():
    """尝试自动检测GPU，如果失败则回退到安全的默认值。"""
    print("INFO: 正在配置 GPU 性能参数...")
    default_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    try:
        result = subprocess.run(
            ['nvidia-smi', '--query-gpu=multiprocessor_count', '--format=csv,noheader'],
            capture_output=True, text=True, check=True, env=os.environ
        )
        sm_count = int(result.stdout.strip())
        blocks, threads, points = sm_count * 7, 256, 1024
        print(f"INFO: 成功检测到 GPU。自动配置: -b {blocks} -t {threads} -p {points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}
    except Exception:
        print(f"WARN: 自动检测GPU失败，将使用已知可行的默认参数。")
        return default_params

# --- 4. 核心执行逻辑与进程管理 ---

def cleanup():
    """程序退出时，终止所有子进程并删除管道文件。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        if p.poll() is None:
            try: p.terminate(); p.wait(timeout=2)
            except: p.kill()
    if os.path.exists(PIPE_BC): os.remove(PIPE_BC)
    print("[CLEANUP] 清理完成。")

atexit.register(cleanup)

def run_bitcrack_and_monitor(command, pipe_path):
    """在新终端中运行BitCrack，并通过命名管道进行监控。"""
    global FOUND_PRIVATE_KEY
    
    if os.path.exists(pipe_path): os.remove(pipe_path)
    os.mkfifo(pipe_path)

    command_str = ' '.join(shlex.quote(arg) for arg in command)
    terminal_command_str = f"bash -c \"{command_str} | tee {pipe_path}; exec bash\""

    terminal_process = subprocess.Popen([
        'xfce4-terminal', '--title', '实时监控: BitCrack (GPU)', '-e', terminal_command_str
    ])
    processes_to_cleanup.append(terminal_process)

    print(f"✅ BitCrack 已在新窗口启动，主控台正在监控结果...")
    try:
        with open(pipe_path, 'r') as fifo:
            for line in fifo:
                if key_found_event.is_set(): break
                match = CUBITCRACK_PRIV_KEY_RE.search(line)
                if match:
                    FOUND_PRIVATE_KEY = match.group(1).lower()
                    key_found_event.set()
                    break
    except Exception as e:
        if not key_found_event.is_set(): print(f"ERROR: 监控管道时出错: {e}")
    finally:
        print("[BitCrack] 监控线程结束。")

def main():
    """主函数，负责设置和启动测试任务。"""
    if not shutil.which('xfce4-terminal'):
        print("错误: 'xfce4-terminal' 未找到。此脚本专为 Xfce 桌面环境设计。")
        sys.exit(1)

    display_system_info()
    time.sleep(1)

    try:
        # 【已修复】使用 exist_ok=True，如果目录已存在，则不会报错
        print(f"INFO: 所有输出文件将被保存在: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        
        found_file = os.path.join(OUTPUT_DIR, 'found_keys_test.txt')
        progress_file = os.path.join(OUTPUT_DIR, 'progress_test.dat')

        gpu_params = get_gpu_params()
        print("="*40)
        
        bitcrack_command = [
            BITCRACK_PATH,
            '-b', str(gpu_params['blocks']),
            '-t', str(gpu_params['threads']),
            '-p', str(gpu_params['points']),
            '--keyspace', KEYSPACE,
            '-o', found_file,
            '--continue', progress_file,
            BTC_ADDRESS
        ]

        thread_bc = threading.Thread(target=run_bitcrack_and_monitor, args=(bitcrack_command, PIPE_BC))
        thread_bc.start()
        key_found_event.wait()
        
        print("\n" + "="*50)
        if FOUND_PRIVATE_KEY:
            print("🎉🎉🎉 测试成功！BitCrack 找到了密钥！🎉🎉🎉")
            print(f"\n  完整私钥 (HEX): {FOUND_PRIVATE_KEY}\n")
            print(f"  相关文件已保存至: {OUTPUT_DIR}")
            print("所有进程将自动关闭。")
        else:
            print("搜索任务已结束，但未通过监控捕获到密钥。")
        print("="*50)

    except FileNotFoundError as e:
        print(f"\n[致命错误] 文件未找到: {e}。请检查 BITCRACK_PATH 是否正确。")
    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")

if __name__ == '__main__':
    main()
