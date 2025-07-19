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

# --- 1. 基础配置 (用于快速测试) ---

KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'
# 修正: 输出到桌面上的一个新文件夹，确保权限正确
DESKTOP_PATH = os.path.expanduser("~/Desktop")
OUTPUT_DIR = os.path.join(DESKTOP_PATH, 'keyhunt_output')

# 测试用的地址和范围，应该会很快找到密钥
BTC_ADDRESS = '1DBaumZxUkM4qMQRt2LVWyFJq5kDtSZQot'
START_KEY = '0000000000000000000000000000000000000000000000000000000000000800'
END_KEY =   '0000000000000000000000000000000000000000000000000000000000000fff'

# --- 2. 全局状态、管道与正则表达式 ---

FOUND_PRIVATE_KEY = None
key_found_event = threading.Event()
processes_to_cleanup = []

PIPE_KH = '/tmp/keyhunt_pipe'

# 正则表达式，可以匹配 "Private key (hex): ..." 或 "Hit! Private Key: ..."
KEYHUNT_PRIV_KEY_RE = re.compile(r'(?:Private key \(hex\)|Hit! Private Key):\s*([0-9a-fA-F]+)')

# --- 3. 系统信息与硬件检测 ---

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
        threads = max(1, cpu_cores or 1) # 确保至少有1个线程
        print(f"INFO: 检测到 {cpu_cores} 个CPU核心。将为 KeyHunt 分配 {threads} 个线程。")
        return threads
    except Exception as e:
        print(f"WARN: 无法自动检测CPU核心数，使用默认值 4。错误: {e}")
        return 4

# --- 4. 核心执行逻辑与进程管理 ---

def cleanup():
    """程序退出时，终止所有子进程并删除管道文件。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        # 检查进程是否存在
        if p and p.poll() is None:
            try:
                # 终止整个进程组
                os.killpg(os.getpgid(p.pid), 15) # SIGTERM
                p.wait(timeout=2)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(os.getpgid(p.pid), 9) # SIGKILL
                except Exception:
                    pass # 忽略错误
            except Exception:
                pass
    
    if os.path.exists(PIPE_KH):
        try:
            os.remove(PIPE_KH)
        except OSError:
            pass
    print("[CLEANUP] 清理完成。")

atexit.register(cleanup)

def run_keyhunt_and_monitor(command, pipe_path):
    """在新终端中运行KeyHunt，并通过命名管道进行监控。"""
    global FOUND_PRIVATE_KEY
    
    if os.path.exists(pipe_path): os.remove(pipe_path)
    os.mkfifo(pipe_path)

    # 构造在新终端中执行的命令
    command_str = ' '.join(shlex.quote(arg) for arg in command)
    terminal_command_str = f"bash -c \"{command_str} | tee {pipe_path}; exec bash\""

    # 关键：使用 preexec_fn=os.setsid 来创建一个新的会话，这样可以可靠地杀死所有子进程
    terminal_process = subprocess.Popen(
        ['xfce4-terminal', '--title', '实时监控: KeyHunt (CPU)', '-e', terminal_command_str],
        preexec_fn=os.setsid
    )
    processes_to_cleanup.append(terminal_process)

    print(f"✅ KeyHunt 已在新窗口启动，主控台正在监控结果...")
    try:
        with open(pipe_path, 'r') as fifo:
            for line in fifo:
                if key_found_event.is_set():
                    break
                
                # 在主控台打印，方便调试
                sys.stdout.write(f"[KeyHunt Log] {line.strip()}\n")
                sys.stdout.flush()

                match = KEYHUNT_PRIV_KEY_RE.search(line)
                if match:
                    FOUND_PRIVATE_KEY = match.group(1).lower()
                    key_found_event.set() # 发送信号：已找到！
                    break
    except Exception as e:
        if not key_found_event.is_set():
            print(f"ERROR: 监控 KeyHunt 的管道时出错: {e}")
    finally:
        print("[KeyHunt] 监控线程结束。")

def main():
    """主函数，负责设置和启动所有任务。"""
    if not shutil.which('xfce4-terminal'):
        print("错误: 'xfce4-terminal' 未找到。此脚本专为 Xfce 桌面环境设计。")
        sys.exit(1)

    display_system_info()
    time.sleep(1)

    try:
        # 修正: 安全地创建目录，如果不存在的话
        if not os.path.exists(OUTPUT_DIR):
            print(f"INFO: 正在创建输出目录: {OUTPUT_DIR}")
            os.makedirs(OUTPUT_DIR)
        else:
            print(f"INFO: 所有输出文件将被保存在: {OUTPUT_DIR}")

        kh_address_file = os.path.join(OUTPUT_DIR, 'target_address.txt')

        print("INFO: 正在根据系统硬件自动配置性能参数...")
        keyhunt_threads = get_cpu_threads()
        print("="*40)

        with open(kh_address_file, 'w') as f: f.write(BTC_ADDRESS)
        
        # 关键修正: 在命令中加入 '-R' 标志，强制在指定范围内搜索！
        keyhunt_command = [
            KEYHUNT_PATH,
            '-m', 'address',
            '-f', kh_address_file,
            '-l', 'both',
            '-t', str(keyhunt_threads),
            '-R',  # <--- 这是让范围搜索生效的关键！
            '-r', f'{START_KEY}:{END_KEY}'
        ]

        # 启动监控线程
        thread_kh = threading.Thread(target=run_keyhunt_and_monitor, args=(keyhunt_command, PIPE_KH))
        thread_kh.start()
        
        # 等待找到密钥的信号
        key_found_event.wait()
        
        # --- 结果处理 ---
        print("\n" + "="*50)
        if FOUND_PRIVATE_KEY:
            # 将可能不完整的密钥补全为64位
            full_key = FOUND_PRIVATE_KEY.zfill(64)
            print("🎉🎉🎉 测试成功！KeyHunt 找到了密钥！🎉🎉🎉")
            print(f"\n  捕获值: {FOUND_PRIVATE_KEY}")
            print(f"  完整私钥 (HEX): {full_key}\n")
            print("所有进程将自动关闭。")
        else:
            print("搜索任务已结束，但未通过监控捕获到密钥。请检查新开的终端窗口是否有错误信息。")
        print("="*50)

    except FileNotFoundError as e:
        print(f"\n[致命错误] 文件未找到: {e}。请检查 KEYHUNT_PATH 是否正确。")
    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")

if __name__ == '__main__':
    main()
