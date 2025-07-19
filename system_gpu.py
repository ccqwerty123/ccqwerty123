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

BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack'
OUTPUT_DIR = '/tmp/bitcrack_test_output'
FOUND_FILE_PATH = os.path.join(OUTPUT_DIR, 'found_keys_test.txt') # 将路径定义为常量

# 测试用的地址和范围
BTC_ADDRESS = '19ZewH8Kk1PDbSNdJ97FP4EiCjTRaZMZQA'
KEYSPACE = '0000000000000000000000000000000000000000000000000000000000000001:000000000000000000000000000000000000000000000000000000000000FFFF'


# --- 2. 全局状态、管道与正则表达式 (无修改) ---

processes_to_cleanup = []
PIPE_BC = '/tmp/bitcrack_pipe' # 临时管道文件

# 正则表达式
# 【修复】使用 findall 来查找所有匹配项
FILE_PRIV_KEY_RE = re.compile(r'([0-9a-fA-F]{64})')
STDOUT_PRIV_KEY_RE = re.compile(r'Priv:([0-9a-fA-F]{64})')

# --- 3. 系统信息与硬件检测 (无修改，使用您的版本) ---

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
    """尝试自动检测GPU，如果失败则回退到安全的默认值。 (您的版本)"""
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

# --- 4. 核心执行逻辑与【已修复的监控】 ---

def final_report_and_cleanup():
    """【修复】在退出前执行最终报告，然后清理。"""
    print("\n" + "="*50)
    print("INFO: 脚本即将退出，正在执行最终密钥报告...")
    time.sleep(1) # 等待文件系统同步

    found_keys = []
    if os.path.exists(FOUND_FILE_PATH) and os.path.getsize(FOUND_FILE_PATH) > 0:
        with open(FOUND_FILE_PATH, 'r') as f:
            content = f.read()
            found_keys = FILE_PRIV_KEY_RE.findall(content)

    if found_keys:
        print(f"🎉🎉🎉 最终报告：在文件 [{FOUND_FILE_PATH}] 中找到 {len(found_keys)} 个密钥！🎉🎉🎉")
        for i, key in enumerate(found_keys):
            print(f"  密钥 #{i+1}: {key.lower()}")
    else:
        print("最终报告：未在输出文件中找到任何密钥。")
    print("="*50 + "\n")

    print("[CLEANUP] 正在清理所有子进程和管道...")
    for p in processes_to_cleanup:
        if p.poll() is None:
            try: p.terminate(); p.wait(timeout=2)
            except: p.kill()
    if os.path.exists(PIPE_BC): os.remove(PIPE_BC)
    print("[CLEANUP] 清理完成。")

atexit.register(final_report_and_cleanup)

def unified_monitor(pipe_path):
    """【已修复的统一监控】只报告，不停止。"""
    print("✅ [统一监控] 线程已启动，持续监控屏幕输出...")
    try:
        with open(pipe_path, 'r') as fifo:
            # 持续读取管道，直到程序退出
            for line in fifo:
                match = STDOUT_PRIV_KEY_RE.search(line)
                if match:
                    # 找到后只打印实时消息，不设置事件或退出
                    found_key = match.group(1).lower()
                    print(f"\n🔔 [实时捕获] 监控到屏幕输出密钥: {found_key} 🔔\n")
    except Exception as e:
        # fifo被删除或程序结束时，这里可能会出错，可以安全忽略
        pass
    print("[统一监控] 监控循环结束。")

def main():
    """主函数，负责设置和启动任务。"""
    display_system_info()
    time.sleep(1)

    try:
        print(f"INFO: 所有输出文件将被保存在: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        # progress_file 用于断点续传，这里保留
        progress_file = os.path.join(OUTPUT_DIR, 'progress.dat')

        # --- 【修复】启动前检查逻辑 ---
        print("-" * 40)
        if os.path.exists(FOUND_FILE_PATH) and os.path.getsize(FOUND_FILE_PATH) > 0:
            with open(FOUND_FILE_PATH, 'r') as f:
                pre_existing_keys = FILE_PRIV_KEY_RE.findall(f.read())
            if pre_existing_keys:
                print(f"⚠️  启动前警告：输出文件 [{FOUND_FILE_PATH}] 中已存在 {len(pre_existing_keys)} 个密钥。")
                for i, key in enumerate(pre_existing_keys):
                    print(f"   -> 已有密钥 #{i+1}: {key.lower()}")
                print("INFO: 脚本将继续执行新的搜索任务。")
            else:
                # 文件存在但为空
                os.remove(FOUND_FILE_PATH)
        print("-" * 40)

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

        # 保留您原有的新窗口启动方式
        command_str = ' '.join(shlex.quote(arg) for arg in bitcrack_command)
        terminal_command_str = f"bash -c \"{command_str} | tee {pipe_path}; exec bash\""
        terminal_process = subprocess.Popen(['xfce4-terminal', '--title', '实时监控: BitCrack (GPU)', '-e', terminal_command_str])
        processes_to_cleanup.append(terminal_process)
        print(f"✅ BitCrack 已在新窗口启动...")

        # 启动一个不会自行退出的监控线程
        monitor_thread = threading.Thread(target=unified_monitor, args=(pipe_path,))
        monitor_thread.daemon = True # 设置为守护线程，主程序退出时它也会退出
        monitor_thread.start()

        print("\nINFO: 监控脚本正在后台运行。您可以观察新开的终端窗口。")
        print("INFO: 关闭 '实时监控: BitCrack (GPU)' 窗口或在此处按 Ctrl+C 来结束任务并查看最终报告。")

        # 让主线程在这里永远等待，直到被用户中断 (Ctrl+C)
        while True:
            time.sleep(3600)

    except KeyboardInterrupt:
        print("\n[INFO] 检测到用户中断 (Ctrl+C)，准备退出...")
    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")

if __name__ == '__main__':
    main()
