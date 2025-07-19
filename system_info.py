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

# --- 1. 基础配置 (测试专用) ---

KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'
OUTPUT_DIR = '/workspace/found_data' 

# 特殊的地址和范围，用于快速找到私钥以进行测试
BTC_ADDRESS = '1DBaumZxUkM4qMQRt2LVWyFJq5kDtSZQot'
START_KEY = '0000000000000000000000000000000000000000000000000000000000000800'
END_KEY =   '0000000000000000000000000000000000000000000000000000000000000fff'

# --- 2. 全局状态、管道与正则表达式 ---

FOUND_PRIVATE_KEY = None
key_found_event = threading.Event()
processes_to_cleanup = []

# 只为 KeyHunt 定义管道和正则表达式
PIPE_KH = '/tmp/keyhunt_pipe'
KEYHUNT_PRIV_KEY_RE = re.compile(r'Private key \(hex\):\s*([0-9a-fA-F]{64})')

# --- 3. 系统信息与硬件检测 ---

def display_system_info():
    """在主控窗口显示简要的系统信息"""
    print("--- 系统状态 (KeyHunt 测试模式) ---")
    try:
        # CPU Info
        cpu_usage = psutil.cpu_percent(interval=0.2)
        cpu_cores = psutil.cpu_count(logical=True)
        print(f"✅ CPU: {cpu_cores} 线程 | 使用率: {cpu_usage}%")
    except Exception:
        print("⚠️ CPU: 无法获取CPU信息。")
    
    # 在这个测试模式中，GPU信息不是必需的，但可以显示一下
    try:
        cmd = ['nvidia-smi', '--query-gpu=name', '--format=csv,noheader,nounits']
        gpu_name = subprocess.check_output(cmd, text=True).strip()
        print(f"ℹ️  GPU: {gpu_name} (在此测试中未使用)")
    except Exception:
        # 如果没有GPU或nvidia-smi，这不会影响测试
        pass
    print("-" * 35)

def get_cpu_threads():
    """自动检测CPU核心数。"""
    try:
        cpu_cores = os.cpu_count()
        threads = max(1, cpu_cores) # 在测试中，可以使用所有核心
        print(f"INFO: 检测到 {cpu_cores} 个CPU核心。将为 KeyHunt 分配 {threads} 个线程。")
        return threads
    except Exception as e:
        print(f"WARN: 无法自动检测CPU核心数，使用默认值 2。错误: {e}")
        return 2

# --- 4. 核心执行逻辑与进程管理 ---

def cleanup():
    """程序退出时，终止所有子进程并删除管道文件。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    # 终止所有记录的进程 (包括 xfce4-terminal)
    for p in processes_to_cleanup:
        if p.poll() is None:
            try:
                p.terminate()
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                p.kill()
            except Exception:
                pass
    
    # 删除 KeyHunt 的命名管道
    if os.path.exists(PIPE_KH):
        os.remove(PIPE_KH)
    print("[CLEANUP] 清理完成。")

# 注册清理函数，确保在任何情况下退出时都会执行
atexit.register(cleanup)

def run_and_monitor_in_new_terminal(command, tool_name, regex_pattern, pipe_path):
    """在新终端中运行命令，并通过命名管道进行监控。"""
    global FOUND_PRIVATE_KEY
    
    if os.path.exists(pipe_path): os.remove(pipe_path)
    os.mkfifo(pipe_path)

    # 构造在新终端中执行的命令
    command_str = ' '.join(shlex.quote(arg) for arg in command)
    terminal_command_str = f"bash -c \"{command_str} | tee {pipe_path}; echo '--- 任务已结束，按回车键关闭窗口 ---'; read\""

    # 启动 xfce4-terminal 进程
    terminal_process = subprocess.Popen([
        'xfce4-terminal',
        '--title', f'实时监控: {tool_name}',
        '-e', terminal_command_str
    ])
    processes_to_cleanup.append(terminal_process)

    print(f"✅ {tool_name} 已在新窗口启动，主控台正在监控结果...")
    try:
        with open(pipe_path, 'r') as fifo:
            for line in fifo:
                if key_found_event.is_set():
                    break
                
                # 在主控台静默处理
                match = regex_pattern.search(line)
                if match:
                    FOUND_PRIVATE_KEY = match.group(1).lower()
                    key_found_event.set() # 发送信号：已找到！
                    break
    except Exception as e:
        if not key_found_event.is_set():
            print(f"ERROR: 监控 {tool_name} 的管道时出错: {e}")
    finally:
        print(f"[{tool_name}] 监控线程结束。")

def main():
    """主函数，负责设置和启动 KeyHunt 测试任务。"""
    if not shutil.which('xfce4-terminal'):
        print("错误: 'xfce4-terminal' 未找到。此脚本专为 Xfce 桌面环境设计。")
        sys.exit(1)

    display_system_info()
    time.sleep(1)

    try:
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        kh_address_file = os.path.join(OUTPUT_DIR, 'target_address.txt')
        with open(kh_address_file, 'w') as f: f.write(BTC_ADDRESS)

        print("INFO: 正在根据系统硬件自动配置性能参数...")
        keyhunt_threads = get_cpu_threads()
        print("="*40)
        
        # 定义 KeyHunt 的启动命令
        keyhunt_command = [
            KEYHUNT_PATH, '-m', 'address', '-f', kh_address_file,
            '-l', 'both', '-t', str(keyhunt_threads),
            '-r', f'{START_KEY}:{END_KEY}'
        ]

        # 启动 KeyHunt 的监控线程
        thread_kh = threading.Thread(target=run_and_monitor_in_new_terminal, args=(keyhunt_command, "KeyHunt (CPU)", KEYHUNT_PRIV_KEY_RE, PIPE_KH))
        thread_kh.start()

        # 等待找到密钥的信号
        print("⏳ 主控台等待结果... 找到私钥后将在此处显示。")
        key_found_event.wait()
        
        # --- 结果处理 ---
        print("\n" + "="*50)
        if FOUND_PRIVATE_KEY:
            print("✅✅✅ 测试成功！私钥已找到！✅✅✅")
            print(f"\n  私钥 (HEX): {FOUND_PRIVATE_KEY}\n")
            print("脚本将自动清理并退出。")
        else:
            print("❓ 任务已结束，但未通过管道捕获到私钥。")
        print("="*50)

    except FileNotFoundError as e:
        print(f"\n[致命错误] 文件未找到: {e}。请检查 KEYHUNT_PATH 是否正确。")
    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")

if __name__ == '__main__':
    main()
