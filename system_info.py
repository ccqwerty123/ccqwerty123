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
# 使用 os.path.expanduser 来正确处理 '~' 符号，代表用户主目录
OUTPUT_DIR = os.path.expanduser('~/Desktop/bitcrack_output')

# 使用您提供的测试参数
BTC_ADDRESS = '1PWo3JeB9jrGwfHDNpdGK54CRas7fsVzXU'
START_KEY = '0000000000000000000000000000000000000000000000599999aabcacda0001'
END_KEY =   '00000000000000000000000000000000000000000000005e666674ae4bc6aaab'

# --- 2. 全局状态、管道与正则表达式 ---

FOUND_PRIVATE_KEY = None
key_found_event = threading.Event()
processes_to_cleanup = []

PIPE_BC = '/tmp/bitcrack_pipe'

# cuBitCrack 格式: ... Priv:FFFFF...
CUBITCRACK_PRIV_KEY_RE = re.compile(r'Priv:([0-9a-fA-F]{64})')

# --- 3. 进程清理与系统信息 ---

def pre_run_cleanup():
    """在启动前清理任何残留的旧进程"""
    print("--- 启动前清理 ---")
    # 需要被清理的进程名列表 (小写)
    targets = ['cubitcrack', 'xfce4-terminal']
    cleaned_count = 0
    for proc in psutil.process_iter(['pid', 'name']):
        if proc.info['name'].lower() in targets:
            try:
                print(f"[*] 发现残留进程: '{proc.info['name']}' (PID: {proc.pid})。正在结束...")
                p = psutil.Process(proc.pid)
                p.kill() # 强制结束以确保清理
                cleaned_count += 1
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass # 进程可能已经消失
    if cleaned_count == 0:
        print("[*] 系统环境干净，未发现残留进程。")
    print("-" * 20)
    time.sleep(1)

def display_system_info():
    """在主控窗口显示简要的GPU信息"""
    print("--- 系统状态 (BitCrack 测试模式) ---")
    try:
        cmd = ['nvidia-smi', '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total', '--format=csv,noheader,nounits']
        gpu_info = subprocess.check_output(cmd, text=True).strip()
        gpu_data = gpu_info.split(', ')
        print(f"✅ GPU: {gpu_data[0]} | Temp: {gpu_data[1]}°C | Util: {gpu_data[2]}% | Mem: {gpu_data[3]}/{gpu_data[4]} MiB")
    except Exception:
        print("⚠️ GPU: 未检测到 NVIDIA GPU 或 nvidia-smi 不可用。")
    print("-" * 35)

# --- 4. 核心执行逻辑与进程管理 ---

def cleanup():
    """程序退出时，终止所有子进程并删除管道文件。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        if p.poll() is None:
            try:
                p.terminate()
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                p.kill()
            except Exception:
                pass
    
    if os.path.exists(PIPE_BC):
        os.remove(PIPE_BC)
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
                if key_found_event.is_set():
                    break
                
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
    """主函数，负责设置和启动所有任务。"""
    # 检查核心程序是否存在
    if not shutil.which('xfce4-terminal'):
        print("错误: 'xfce4-terminal' 未找到。此脚本专为 Xfce 桌面环境设计。")
        sys.exit(1)
    if not os.path.exists(BITCRACK_PATH):
        print(f"错误: BitCrack 主程序未在 '{BITCRACK_PATH}' 找到。")
        sys.exit(1)

    # 1. 执行启动前清理
    pre_run_cleanup()

    # 2. 显示系统状态
    display_system_info()
    
    try:
        print(f"INFO: 所有输出文件将被保存在: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True) # 如果目录已存在则不报错
        
        # 定义输出文件路径
        bc_found_file = os.path.join(OUTPUT_DIR, 'found.txt')
        bc_progress_file = os.path.join(OUTPUT_DIR, 'progress.dat')

        print("INFO: 使用您提供的静态参数进行测试。")
        print("="*40)
        
        # 使用您提供的命令参数构建命令列表
        bitcrack_command = [
            BITCRACK_PATH,
            '-b', '288',
            '-t', '256',
            '-p', '1024',
            '--keyspace', f'{START_KEY}:{END_KEY}',
            '-o', bc_found_file, 
            '--continue', bc_progress_file,
            BTC_ADDRESS
        ]

        thread_bc = threading.Thread(target=run_bitcrack_and_monitor, args=(bitcrack_command, PIPE_BC))
        thread_bc.start()
        
        # 等待找到密钥的信号
        key_found_event.wait()
        
        print("\n" + "="*50)
        if FOUND_PRIVATE_KEY:
            print("🎉🎉🎉 测试成功！BitCrack 找到了密钥！🎉🎉🎉")
            print(f"\n  私钥 (HEX): {FOUND_PRIVATE_KEY}\n")
            print("所有进程将自动关闭。")
        else:
            print("搜索任务已结束，但未通过监控捕获到密钥。")
        print("="*50)

    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")

if __name__ == '__main__':
    main()
