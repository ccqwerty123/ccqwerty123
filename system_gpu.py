#!/usr/bin/env python3
import subprocess
import os
import threading
import sys
import atexit
import re
import shlex
import time

# --- 1. 基础配置 (无修改) ---

BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack'
OUTPUT_DIR = '/tmp/bitcrack_test_output'
FOUND_FILE_PATH = os.path.join(OUTPUT_DIR, 'found_keys_test.txt')

# 测试用的地址和范围
BTC_ADDRESS = '19ZewH8Kk1PDbSNdJ97FP4EiCjTRaZMZQA'
KEYSPACE = '0000000000000000000000000000000000000000000000000000000000000001:000000000000000000000000000000000000000000000000000000000000FFFF'


# --- 2. 全局状态、管道与正则表达式 ---

processes_to_cleanup = []
PIPE_BC = '/tmp/bitcrack_pipe'

# 正则表达式 (仅用于屏幕实时捕获)
STDOUT_PRIV_KEY_RE = re.compile(r'Priv:([0-9a-fA-F]{64})')

# --- 3. 系统信息与硬件检测 ---

def display_system_info():
    """在主控窗口显示简要的系统信息"""
    print("--- 系统状态 (BitCrack 最终修复版) ---")
    try:
        cmd = ['nvidia-smi', '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total', '--format=csv,noheader,nounits']
        gpu_info = subprocess.check_output(cmd, text=True).strip()
        gpu_data = gpu_info.split(', ')
        print(f"✅ GPU: {gpu_data[0]} | Temp: {gpu_data[1]}°C | Util: {gpu_data[2]}% | Mem: {gpu_data[3]}/{gpu_data[4]} MiB")
    except Exception:
        print("⚠️ GPU: 未检测到 NVIDIA GPU 或 nvidia-smi 不可用。")
    print("-" * 40)

def get_gpu_params():
    """【已修复】更健壮地自动检测GPU，如果失败则回退到安全的默认值。"""
    print("INFO: 正在配置 GPU 性能参数...")
    default_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    try:
        # 这个命令的输出有时不稳定，需要做更严格的检查
        cmd = ['nvidia-smi', '--query-gpu=multiprocessor_count', '--format=csv,noheader']
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, env=os.environ)
        sm_count_str = result.stdout.strip()

        # 【核心修复】检查返回的是否为纯数字，防止int()转换失败
        if not sm_count_str.isdigit():
            raise ValueError(f"nvidia-smi 返回了非预期的内容: '{sm_count_str}'")

        sm_count = int(sm_count_str)
        blocks, threads, points = sm_count * 7, 256, 1024
        print(f"INFO: 成功检测到 GPU。自动配置: -b {blocks} -t {threads} -p {points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}
    except Exception as e:
        print(f"WARN: 自动检测GPU失败，将使用已知可行的默认参数。原因: {e}")
        return default_params

# --- 4. 核心执行逻辑与最终报告 ---

def cleanup():
    """程序退出时，仅负责清理子进程和管道。"""
    print("\n[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        if p.poll() is None:
            try: p.terminate(); p.wait(timeout=2)
            except: p.kill()
    if os.path.exists(PIPE_BC): os.remove(PIPE_BC)
    print("[CLEANUP] 清理完成。")

atexit.register(cleanup)

def generate_final_report():
    """【已修复】读取文件并按新格式生成最终报告。"""
    print("="*60)
    print(f"INFO: 正在读取最终结果文件: {FOUND_FILE_PATH}")

    found_entries = []
    if os.path.exists(FOUND_FILE_PATH):
        with open(FOUND_FILE_PATH, 'r') as f:
            for line in f:
                line = line.strip()
                if not line: continue
                # 按空格分割每一行
                parts = line.split()
                if len(parts) >= 3:
                    # 至少需要3部分: 地址, 私钥, 公钥
                    found_entries.append({
                        'address': parts[0],
                        'priv_key': parts[1],
                        'pub_key': parts[2]
                    })

    if found_entries:
        print(f"🎉🎉🎉 任务结束！共在文件中找到 {len(found_entries)} 条有效记录！🎉🎉🎉")
        print("-" * 60)
        # 格式化输出
        print(f"{'地址':<36} {'私钥 (HEX)':<66} {'公钥':<66}")
        print(f"{'-'*36:<36} {'-'*66:<66} {'-'*66:<66}")
        for entry in found_entries:
            print(f"{entry['address']:<36} {entry['priv_key'].lower():<66} {entry['pub_key']:<66}")
    else:
        print("🔴 任务结束，但在输出文件中未找到任何有效格式的密钥记录。")
    print("="*60)

def unified_monitor(pipe_path):
    """持续监控屏幕输出，BitCrack结束后此线程会自动退出。"""
    print("✅ [统一监控] 线程已启动，等待 BitCrack 进程输出...")
    try:
        with open(pipe_path, 'r') as fifo:
            # 持续从管道读取，当BitCrack和tee结束后，管道关闭，循环会自动结束
            for line in fifo:
                # 实时打印BitCrack的输出到主控台
                sys.stdout.write(line)
                sys.stdout.flush()
    except Exception:
        pass
    print("\n[统一监控] 检测到 BitCrack 进程已退出。监控线程结束。")

def main():
    """主函数，负责设置和启动任务。"""
    display_system_info()
    time.sleep(1)

    try:
        print(f"INFO: 所有输出文件将被保存在: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        progress_file = os.path.join(OUTPUT_DIR, 'progress.dat')

        gpu_params = get_gpu_params()
        print("="*40)

        bitcrack_command = [
            BITCRACK_PATH, '-b', str(gpu_params['blocks']), '-t', str(gpu_params['threads']),
            '-p', str(gpu_params['points']), '--keyspace', KEYSPACE, '-o', FOUND_FILE_PATH,
            '--continue', progress_file, BTC_ADDRESS
        ]

        pipe_path = PIPE_BC
        if os.path.exists(pipe_path): os.remove(pipe_path)
        os.mkfifo(pipe_path)

        command_str = ' '.join(shlex.quote(arg) for arg in bitcrack_command)
        # 使用 exec bash 确保窗口在任务结束后不会立即关闭，方便查看
        terminal_command_str = f"bash -c \"{command_str} | tee {pipe_path}; echo '--- BitCrack 已结束，此窗口可关闭 ---'; exec bash\""
        terminal_process = subprocess.Popen(['xfce4-terminal', '--title', '实时监控: BitCrack (GPU)', '-e', terminal_command_str])
        processes_to_cleanup.append(terminal_process)
        print(f"✅ BitCrack 已在新窗口启动...")

        monitor_thread = threading.Thread(target=unified_monitor, args=(pipe_path,))
        monitor_thread.start()

        # 主线程等待监控线程结束（即BitCrack进程结束）
        monitor_thread.join()

        # 【新功能】BitCrack结束后，延迟并生成报告
        print(f"\nINFO: BitCrack 任务已完成。等待 5 秒后生成最终报告...")
        time.sleep(5)
        generate_final_report()
        print("\nINFO: 脚本执行完毕。")

    except KeyboardInterrupt:
        print("\n[INFO] 检测到用户中断 (Ctrl+C)，准备退出并生成最终报告...")
        time.sleep(1)
        generate_final_report()
    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")
        import traceback
        traceback.print_exc()

if __name__ == '__main__':
    main()
