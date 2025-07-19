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

# --- 1. 基础配置 (用于 BitCrack 测试) ---

BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack'
# 将在桌面创建输出目录
OUTPUT_DIR = os.path.expanduser('~/Desktop/bitcrack_output')

# 使用您提供的命令中的地址和范围作为测试目标
BTC_ADDRESS = '1PWo3JeB9jrGwfHDNpdGK54CRas7fsVzXU'
KEYSPACE = '0000000000000000000000000000000000000000000000599999aabcacda0001:00000000000000000000000000000000000000000000005e666674ae4bc6aaab'

# --- 2. 全局状态、管道与正则表达式 ---

FOUND_PRIVATE_KEY = None
key_found_event = threading.Event()
processes_to_cleanup = []

PIPE_BC = '/tmp/bitcrack_pipe' # 命名管道

# cuBitCrack 的私钥格式: ... Priv:FFFFF...
CUBITCRACK_PRIV_KEY_RE = re.compile(r'Priv:([0-9a-fA-F]{64})')

# --- 3. 系统信息与硬件自动配置 ---

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
    """通过 nvidia-smi 自动检测GPU并返回推荐的性能参数。"""
    default_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    try:
        result = subprocess.run(
            ['nvidia-smi', '--query-gpu=multiprocessor_count', '--format=csv,noheader'],
            capture_output=True, text=True, check=True, env=os.environ
        )
        sm_count = int(result.stdout.strip())
        # 根据经验公式计算参数
        blocks = sm_count * 7
        threads = 256
        points = 1024
        print(f"INFO: 检测到 GPU 有 {sm_count} SMs。自动配置参数: -b {blocks} -t {threads} -p {points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}
    except Exception as e:
        print(f"WARN: 自动检测GPU失败，将为 cuBitCrack 使用默认的高性能参数。错误: {e}")
        return default_params

# --- 4. 核心执行逻辑与进程管理 ---

def cleanup():
    """程序退出时，终止所有子进程并删除管道文件。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        if p.poll() is None:
            try: p.terminate(); p.wait(timeout=2)
            except subprocess.TimeoutExpired: p.kill()
            except Exception: pass
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
                    key_found_event.set() # 发送信号：已找到！
                    break
    except Exception as e:
        if not key_found_event.is_set():
            print(f"ERROR: 监控 BitCrack 的管道时出错: {e}")
    finally:
        print("[BitCrack] 监控线程结束。")

def main():
    """主函数，负责设置和启动BitCrack测试任务。"""
    if not shutil.which('xfce4-terminal'):
        print("错误: 'xfce4-terminal' 未找到。此脚本专为 Xfce 桌面环境设计。")
        sys.exit(1)

    display_system_info()
    time.sleep(1)

    try:
        print(f"INFO: 所有输出文件将被保存在: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True) # 安全地创建目录
        
        found_file = os.path.join(OUTPUT_DIR, 'found.txt')
        progress_file = os.path.join(OUTPUT_DIR, 'progress.dat')

        print("INFO: 正在根据 GPU 硬件自动配置性能参数...")
        gpu_params = get_gpu_params()
        print("="*40)

        # 构建 BitCrack 启动命令
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

        # 启动监控线程
        thread_bc = threading.Thread(target=run_bitcrack_and_monitor, args=(bitcrack_command, PIPE_BC))
        thread_bc.start()
        
        # 等待找到密钥的信号
        key_found_event.wait()
        
        # 显示最终结果
        print("\n" + "="*50)
        if FOUND_PRIVATE_KEY:
            print("🎉🎉🎉 测试成功！BitCrack 找到了密钥！🎉🎉🎉")
            print(f"\n  私钥 (HEX): {FOUND_PRIVATE_KEY}\n")
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
