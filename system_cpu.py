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

# --- 1. 基础配置 (已按要求修改) ---

KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'
# 【已修改】输出目录改为临时目录
OUTPUT_DIR = '/tmp/keyhunt_test_output'
# 【已增加】定义找到的密钥的输出文件路径
FOUND_FILE_PATH = os.path.join(OUTPUT_DIR, 'found_keys.txt')

BTC_ADDRESS = '1DBaumZxUkM4qMQRt2LVWyFJq5kDtSZQot'
START_KEY = '0000000000000000000000000000000000000000000000000000000000000800'
END_KEY =   '0000000000000000000000000000000000000000000000000000000000000fff'


# --- 2. 全局状态、管道与正则表达式 ---

processes_to_cleanup = []
PIPE_KH = '/tmp/keyhunt_pipe'

# 匹配屏幕或文件输出中的私钥
# 支持 "Private key (hex): ...", "Hit! Private Key: ...", "Priv: ..." 等多种格式
KEYHUNT_PRIV_KEY_RE = re.compile(r'(?:Private key \(hex\)|Hit! Private Key|Priv):\s*([0-9a-fA-F]+)')


# --- 3. 系统信息与硬件检测 (无修改) ---

def display_system_info():
    """在主控窗口显示简要的系统信息"""
    print("--- 系统状态 (KeyHunt 测试模式) ---")
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
        # 在多核CPU上保留一个核心给系统，避免卡顿
        threads = max(1, cpu_cores - 1 if cpu_cores > 1 else 1)
        print(f"INFO: 检测到 {cpu_cores} 个CPU核心。将为 KeyHunt 分配 {threads} 个线程。")
        return threads
    except Exception as e:
        print(f"WARN: 无法自动检测CPU核心数，使用默认值 15。错误: {e}")
        return 15


# --- 4. 核心执行逻辑与最终报告 ---

def cleanup():
    """程序退出时，仅负责清理子进程和管道。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        if p.poll() is None:
            try: p.terminate(); p.wait(timeout=2)
            except: p.kill()
    if os.path.exists(PIPE_KH): os.remove(PIPE_KH)
    print("[CLEANUP] 清理完成。")

atexit.register(cleanup)

def generate_final_report():
    """【新功能】读取文件并生成最终的密钥报告。"""
    print("="*60)
    print(f"INFO: 正在读取最终结果文件: {FOUND_FILE_PATH}")

    found_keys = []
    if os.path.exists(FOUND_FILE_PATH):
        with open(FOUND_FILE_PATH, 'r') as f:
            content = f.read()
            # 使用正则表达式查找所有匹配的密钥
            found_keys = KEYHUNT_PRIV_KEY_RE.findall(content)

    if found_keys:
        print(f"🎉🎉🎉 任务结束！共在文件中找到 {len(found_keys)} 个密钥！🎉🎉🎉")
        print("-" * 60)
        for i, key in enumerate(found_keys):
            # 将不足64位的密钥在左侧补0
            full_key = key.lower().zfill(64)
            print(f"  密钥 #{i+1}: {full_key}")
    else:
        print("🔴 任务结束，但在输出文件中未找到任何密钥。")
    print("="*60)

def keyhunt_monitor(pipe_path):
    """【已修改】持续监控屏幕输出，keyhunt结束后此线程会自动退出。"""
    print("✅ [监控线程] 已启动，等待 KeyHunt 进程输出...")
    try:
        with open(pipe_path, 'r') as fifo:
            for line in fifo:
                # 实时打印KeyHunt的输出到主控台
                sys.stdout.write(line)
                sys.stdout.flush()
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
        print(f"INFO: 所有输出文件将被保存在: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        # 确保开始前输出文件是干净的
        if os.path.exists(FOUND_FILE_PATH):
            os.remove(FOUND_FILE_PATH)
        
        kh_address_file = os.path.join(OUTPUT_DIR, 'target_address.txt')
        with open(kh_address_file, 'w') as f: f.write(BTC_ADDRESS)

        print("INFO: 正在根据系统硬件自动配置性能参数...")
        keyhunt_threads = get_cpu_threads()
        print("="*40)
        
        # 【已修改】在命令中加入 '-o' (输出文件) 和 '-R' (范围搜索) 标志
        keyhunt_command = [
            KEYHUNT_PATH,
            '-m', 'address',
            '-f', kh_address_file,
            '-o', FOUND_FILE_PATH, # <--【增加】指定输出文件
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

        # 【新功能】keyhunt结束后，延迟并生成报告
        print(f"\nINFO: KeyHunt 任务已完成。等待 5 秒后生成最终报告...")
        time.sleep(5)
        generate_final_report()
        print("\nINFO: 脚本执行完毕。")

    except KeyboardInterrupt:
        print("\n[INFO] 检测到用户中断 (Ctrl+C)，准备退出并生成最终报告...")
        time.sleep(1)
        generate_final_report()
    except FileNotFoundError as e:
        print(f"\n[致命错误] 文件未找到: {e}。请检查 KEYHUNT_PATH 是否正确。")
    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")
        import traceback
        traceback.print_exc()

if __name__ == '__main__':
    main()
