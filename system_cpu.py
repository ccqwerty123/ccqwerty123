#!/usr/bin/env python3
import subprocess
import os
import threading
import sys
import atexit
import re
import shlex
import time
import shutil

# --- 1. 基础配置 ---

KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'
# 【已修改】临时目录仅用于存放输入文件
OUTPUT_DIR = '/tmp/keyhunt_run_temp'

BTC_ADDRESS = '1DBaumZxUkM4qMQRt2LVWyFJq5kDtSZQot'
START_KEY = '0000000000000000000000000000000000000000000000000000000000000800'
END_KEY =   '0000000000000000000000000000000000000000000000000000000000000fff'


# --- 2. 全局状态、管道与正则表达式 ---

processes_to_cleanup = []
PIPE_KH = '/tmp/keyhunt_pipe'

# 【新】使用列表来存储所有从屏幕捕获的密钥
ALL_FOUND_KEYS = []

# 匹配屏幕输出中的私钥
KEYHUNT_PRIV_KEY_RE = re.compile(r'(?:Private key \(hex\)|Hit! Private Key|Priv):\s*([0-9a-fA-F]+)')


# --- 3. 系统信息与硬件检测 (无修改) ---

def display_system_info():
    """在主控窗口显示简要的系统信息"""
    print("--- 系统状态 (KeyHunt 最终修复版) ---")
    try:
        cpu_usage = psutil.cpu_percent(interval=0.2)
        cpu_cores = psutil.cpu_count(logical=True)
        print(f"✅ CPU: {cpu_cores} 线程 | 使用率: {cpu_usage}%")
    except Exception:
        print("⚠️ CPU: 无法获取CPU信息。")
    print("-" * 35)

def get_cpu_threads():
    """自动检测CPU核心数并返回合理的线程数。"""
    try:
        cpu_cores = os.cpu_count()
        threads = max(1, cpu_cores - 1 if cpu_cores > 1 else 1)
        print(f"INFO: 检测到 {cpu_cores} 个CPU核心。将为 KeyHunt 分配 {threads} 个线程。")
        return threads
    except Exception as e:
        print(f"WARN: 无法自动检测CPU核心数，使用默认值 15。错误: {e}")
        return 15


# --- 4. 核心执行逻辑与最终报告 ---

def cleanup():
    """程序退出时，清理子进程和管道文件。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        if p.poll() is None:
            try: p.terminate(); p.wait(timeout=2)
            except: p.kill()
    if os.path.exists(PIPE_KH): os.remove(PIPE_KH)
    # 同时清理临时目录
    if os.path.exists(OUTPUT_DIR): shutil.rmtree(OUTPUT_DIR)
    print("[CLEANUP] 清理完成。")

atexit.register(cleanup)

def generate_final_report():
    """【已修复】从内存中的列表生成最终报告。"""
    print("="*60)
    print("INFO: 正在整理所有从屏幕捕获到的密钥...")
    
    if ALL_FOUND_KEYS:
        print(f"🎉🎉🎉 任务结束！共捕获到 {len(ALL_FOUND_KEYS)} 个密钥！🎉🎉🎉")
        print("-" * 60)
        for i, key in enumerate(ALL_FOUND_KEYS):
            # 将不足64位的密钥在左侧补0
            full_key = key.lower().zfill(64)
            print(f"  密钥 #{i+1}: {full_key}")
    else:
        print("🔴 任务结束，但在整个运行期间未从屏幕输出中捕获到任何密钥。")
    print("="*60)

def keyhunt_monitor(pipe_path):
    """【已修复】从管道读取所有输出，匹配并保存所有找到的密钥到列表中。"""
    global ALL_FOUND_KEYS
    print("✅ [监控线程] 已启动，实时捕获 KeyHunt 的屏幕输出...")
    try:
        with open(pipe_path, 'r') as fifo:
            for line in fifo:
                # 实时打印到主控台，方便观察进度
                sys.stdout.write(line)
                sys.stdout.flush()
                
                match = KEYHUNT_PRIV_KEY_RE.search(line)
                if match:
                    found_key = match.group(1)
                    # 将找到的密钥存入全局列表
                    ALL_FOUND_KEYS.append(found_key)
                    # 也可以在这里加一个实时提醒
                    print(f"\n🔔 [实时捕获] 发现一个密钥: {found_key} 🔔\n")
    except Exception:
        pass
    print("\n[监控线程] 检测到 KeyHunt 进程已退出。")

def main():
    """主函数，负责设置和启动任务。"""
    if not shutil.which('xfce4-terminal'):
        print("错误: 'xfce4-terminal' 未找到。")
        sys.exit(1)

    display_system_info()
    time.sleep(1)

    try:
        # 【说明】此目录仅用于存放 KeyHunt 需要的输入地址文件
        print(f"INFO: 将在临时目录中创建输入文件: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        
        kh_address_file = os.path.join(OUTPUT_DIR, 'target_address.txt')
        with open(kh_address_file, 'w') as f: f.write(BTC_ADDRESS)

        keyhunt_threads = get_cpu_threads()
        print("="*40)
        
        # 【已修复】构建正确的 KeyHunt 命令，不使用 -o 参数
        keyhunt_command = [
            KEYHUNT_PATH,
            '-m', 'address',
            '-f', kh_address_file,
            '-l', 'both',
            '-t', str(keyhunt_threads),
            '-R',
            '-r', f'{START_KEY}:{END_KEY}'
        ]

        pipe_path = PIPE_KH
        if os.path.exists(pipe_path): os.remove(pipe_path)
        os.mkfifo(pipe_path)

        command_str = ' '.join(shlex.quote(arg) for arg in keyhunt_command)
        terminal_command_str = f"bash -c \"{command_str} | tee {pipe_path}; echo '--- KeyHunt 已结束，此窗口可关闭 ---'; exec bash\""

        terminal_process = subprocess.Popen(['xfce4-terminal', '--title', '实时监控: KeyHunt (CPU)', '-e', terminal_command_str])
        processes_to_cleanup.append(terminal_process)
        print(f"✅ KeyHunt 已在新窗口启动...")

        monitor_thread = threading.Thread(target=keyhunt_monitor, args=(pipe_path,))
        monitor_thread.start()

        # 等待监控线程结束（意味着keyhunt进程已退出）
        monitor_thread.join()

        # KeyHunt结束后，直接生成报告（无需延迟，因为所有数据已在内存中）
        generate_final_report()
        print("\nINFO: 脚本执行完毕。")

    except KeyboardInterrupt:
        print("\n[INFO] 检测到用户中断 (Ctrl+C)，准备退出并生成最终报告...")
        generate_final_report()
    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")
        import traceback
        traceback.print_exc()

if __name__ == '__main__':
    main()
