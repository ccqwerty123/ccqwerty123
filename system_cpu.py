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

# --- 1. 基础配置 (无修改) ---

KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'
OUTPUT_DIR = '/tmp/keyhunt_output' 

BTC_ADDRESS = '1DBaumZxUkM4qMQRt2LVWyFJq5kDtSZQot'
START_KEY = '0000000000000000000000000000000000000000000000000000000000000800'
END_KEY =   '0000000000000000000000000000000000000000000000000000000000000fff'

# --- 2. 全局状态、管道与正则表达式 (无修改) ---

ALL_FOUND_KEYS = []
processes_to_cleanup = []

PIPE_KH = '/tmp/keyhunt_pipe'

KEYHUNT_PRIV_KEY_RE = re.compile(r'(?:Private key \(hex\)|Hit! Private Key):\s*([0-9a-fA-F]+)')


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
        threads = max(1, cpu_cores - 1 if cpu_cores > 1 else 1)
        print(f"INFO: 检测到 {cpu_cores} 个CPU核心。将为 KeyHunt 分配 {threads} 个线程。")
        return threads
    except Exception as e:
        print(f"WARN: 无法自动检测CPU核心数，使用默认值 15。错误: {e}")
        return 15


# --- 4. 核心执行逻辑与最终报告 (无修改) ---

def cleanup():
    """程序退出时，终止所有子进程并删除管道文件。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        if p.poll() is None:
            try: p.terminate(); p.wait(timeout=2)
            except: p.kill()
    
    if os.path.exists(PIPE_KH):
        os.remove(PIPE_KH)
    print("[CLEANUP] 清理完成。")

atexit.register(cleanup)

def generate_final_report():
    """根据内存中收集到的密钥生成最终报告。"""
    print("="*60)
    if ALL_FOUND_KEYS:
        print(f"🎉🎉🎉 任务结束！共捕获到 {len(ALL_FOUND_KEYS)} 个密钥！🎉🎉🎉")
        print("-" * 60)
        for i, key in enumerate(ALL_FOUND_KEYS):
            full_key = key.lower().zfill(64)
            print(f"  密钥 #{i+1}: {full_key}")
    else:
        print("🔴 任务结束，但在运行期间未通过屏幕输出捕获到任何密钥。")
    print("="*60)

def run_keyhunt_and_monitor(command, pipe_path):
    """在新终端中运行KeyHunt，并持续监控和收集所有找到的密钥。"""
    global ALL_FOUND_KEYS
    
    if os.path.exists(pipe_path): os.remove(pipe_path)
    os.mkfifo(pipe_path)

    command_str = ' '.join(shlex.quote(arg) for arg in command)
    terminal_command_str = f"bash -c \"{command_str} | tee {pipe_path}; echo '--- KeyHunt 已结束，此窗口可关闭 ---'; exec bash\""

    terminal_process = subprocess.Popen(['xfce4-terminal', '--title', '实时监控: KeyHunt (CPU)', '-e', terminal_command_str])
    processes_to_cleanup.append(terminal_process)

    print(f"\n✅ KeyHunt 已在新窗口启动，主控台正在监控结果...")
    try:
        with open(pipe_path, 'r') as fifo:
            for line in fifo:
                match = KEYHUNT_PRIV_KEY_RE.search(line)
                if match:
                    found_key = match.group(1).lower()
                    print(f"\n🔔 [实时捕获] 监控到密钥: {found_key} 🔔")
                    ALL_FOUND_KEYS.append(found_key)
    except Exception as e:
        print(f"ERROR: 监控 KeyHunt 的管道时出错: {e}")
    finally:
        print("[监控线程] 检测到 KeyHunt 进程已退出。")


def main():
    """主函数，增加了N值计算和命令输出，并修复了命令本身。"""
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
        
        # ====================================================================
        # --- [VULNERABILITY FIX & ENHANCED OUTPUT] - 漏洞修复与输出增强 ---
        # ====================================================================
        print("\n" + "="*50)
        print("--- 任务参数详情 ---")
        
        # 1. 计算确保完整扫描所需的 -n 参数值
        start_int = int(START_KEY, 16)
        end_int = int(END_KEY, 16)
        keys_to_search = end_int - start_int + 1
        # 向上取整到最接近的 1024 的倍数，以优化性能
        n_value_dec = (keys_to_search + 1023) // 1024 * 1024
        n_value_hex = hex(n_value_dec)

        # 2. 打印所有关键信息
        print(f"  -> 目标地址: {BTC_ADDRESS}")
        print(f"  -> 搜索范围 (HEX): {START_KEY} -> {END_KEY}")
        print(f"  -> 范围密钥总数: {keys_to_search}")
        print(f"  -> 计算出的N值 (DEC): {n_value_dec}")
        print(f"  -> 计算出的N值 (HEX): {n_value_hex}")
        print("="*50)

        # 3. 构建修复后的命令
        #    - 增加了 -n 参数以确保进行精确的、完整的范围扫描。
        #    - 移除了 -R 参数，因为它会强制随机搜索，与我们的目标冲突。
        keyhunt_command = [
            KEYHUNT_PATH, '-m', 'address', '-f', kh_address_file,
            '-l', 'both', '-t', str(keyhunt_threads),
            '-r', f'{START_KEY}:{END_KEY}',
            '-n', n_value_hex  # <-- 关键修复
        ]
        
        # 4. 打印最终执行的命令
        command_str_for_display = shlex.join(keyhunt_command)
        print(f"\n[INFO] 准备执行的最终命令:\n{command_str_for_display}")
        # ====================================================================

        # 启动监控线程
        monitor_thread = threading.Thread(target=run_keyhunt_and_monitor, args=(keyhunt_command, PIPE_KH))
        monitor_thread.start()
        
        monitor_thread.join()
        
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

if __name__ == '__main__':
    main()
