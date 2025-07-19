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

# --- 1. 基础配置 ---

# 【重要】请确保此路径正确
BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack'
OUTPUT_DIR = '/tmp/bitcrack_test_output'

# 测试用的地址和范围
BTC_ADDRESS = '19ZewH8Kk1PDbSNdJ97FP4EiCjTRaZMZQA'
KEYSPACE = '0000000000000000000000000000000000000000000000000000000000000001:000000000000000000000000000000000000000000000000000000000000FFFF'


# --- 2. 全局状态与正则表达式 ---

FOUND_PRIVATE_KEY = None
FOUND_METHOD = "未找到"
key_found_event = threading.Event()
processes_to_cleanup = []

# 正则表达式 (保持不变)
STDOUT_KEY_RE = re.compile(r'Key: ([0-9a-fA-F]{64})') # cuBitCrack 的输出格式是 "Key: ..."
FILE_PRIV_KEY_RE = re.compile(r'([0-9a-fA-F]{64})')

# --- 3. 系统信息与硬件检测 ---

def display_system_info():
    """在主控窗口显示简要的系统信息"""
    print("--- 系统状态 (BitCrack 最终修复版 v2) ---")
    try:
        cmd = ['nvidia-smi', '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total', '--format=csv,noheader,nounits']
        gpu_info = subprocess.check_output(cmd, text=True).strip()
        gpu_data = gpu_info.split(', ')
        print(f"✅ GPU: {gpu_data[0]} | Temp: {gpu_data[1]}°C | Util: {gpu_data[2]}% | Mem: {gpu_data[3]}/{gpu_data[4]} MiB")
    except Exception as e:
        print(f"⚠️ GPU: 未检测到 NVIDIA GPU 或 nvidia-smi 不可用。错误: {e}")
    print("-" * 45)

def get_gpu_params():
    """尝试自动检测GPU，如果失败则回退到安全的默认值。"""
    print("INFO: 正在配置 GPU 性能参数...")
    default_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    try:
        result = subprocess.run(['nvidia-smi', '--query-gpu=multiprocessor_count', '--format=csv,noheader'], capture_output=True, text=True, check=True, env=os.environ)
        sm_count_str = result.stdout.strip()
        if not sm_count_str.isdigit():
             raise ValueError(f"nvidia-smi 返回了非数字内容: '{sm_count_str}'")
        sm_count = int(sm_count_str)
        blocks, threads, points = sm_count * 7, 256, 1024
        print(f"INFO: 成功检测到 GPU。自动配置: -b {blocks} -t {threads} -p {points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}
    except Exception as e:
        print(f"WARN: 自动检测GPU失败，将使用已知可行的默认参数。原因: {e}")
        return default_params

# --- 4. 核心执行逻辑与【分离式监控】 ---

def cleanup():
    """程序退出时，清理所有子进程。"""
    print("\n[CLEANUP] 正在终止所有子进程...")
    # 设置事件，通知所有线程退出
    key_found_event.set()
    for p in processes_to_cleanup:
        try:
            # 使用psutil更可靠地终止进程及其子进程
            parent = psutil.Process(p.pid)
            for child in parent.children(recursive=True):
                child.terminate()
            parent.terminate()
            p.wait(timeout=3)
        except psutil.NoSuchProcess:
            pass # 进程已经不存在
        except Exception as e:
            if p.poll() is None: p.kill() # 最后的保障
            print(f"[CLEANUP] 清理进程时出错: {e}")
    print(f"[CLEANUP] 清理完成。")

atexit.register(cleanup)

def file_monitor(file_path):
    """【文件监控线程】仅负责周期性检查文件。"""
    global FOUND_PRIVATE_KEY, FOUND_METHOD
    print("✅ [文件监控] 线程已启动...")
    while not key_found_event.is_set():
        if os.path.exists(file_path) and os.path.getsize(file_path) > 0:
            try:
                with open(file_path, 'r') as f_check:
                    content = f_check.read()
                    match = FILE_PRIV_KEY_RE.search(content)
                if match:
                    print("\n[文件监控] 在文件中检测到密钥！")
                    FOUND_PRIVATE_KEY, FOUND_METHOD = match.group(1).lower(), "文件监控"
                    key_found_event.set() # 发送信号，通知其他线程停止
                    break
            except IOError as e:
                print(f"WARN: [文件监控] 读取文件时发生IO错误: {e}")
                pass
        time.sleep(2) # 每2秒检查一次文件
    print("[文件监控] 监控循环结束。")

def stream_monitor(process):
    """【输出流监控线程】实时读取和解析cuBitCrack的标准输出。"""
    global FOUND_PRIVATE_KEY, FOUND_METHOD
    print("✅ [输出流监控] 线程已启动，实时解析屏幕输出...")
    # 使用 iter 和 readline 避免阻塞
    for line in iter(process.stdout.readline, ''):
        if key_found_event.is_set():
            break
        sys.stdout.write(line) # 实时打印到主控台
        sys.stdout.flush()
        match = STDOUT_KEY_RE.search(line)
        if match:
            print("\n[输出流监控] 在屏幕输出中检测到密钥！")
            # cuBitCrack 找到密钥会同时打印到屏幕并写入文件
            FOUND_PRIVATE_KEY, FOUND_METHOD = match.group(1).lower(), "屏幕输出"
            key_found_event.set() # 发送信号
            break
    print("[输出流监控] 监控循环结束。")

def main():
    """主函数，负责设置和启动测试任务。"""
    global FOUND_PRIVATE_KEY, FOUND_METHOD

    display_system_info()
    time.sleep(1)

    try:
        print(f"INFO: 所有输出文件将被保存在: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        found_file = os.path.join(OUTPUT_DIR, 'found_keys_test.txt')

        # 【修复】在启动前先检查一次文件
        if os.path.exists(found_file) and os.path.getsize(found_file) > 0:
            with open(found_file, 'r') as f: match = FILE_PRIV_KEY_RE.search(f.read())
            if match:
                FOUND_PRIVATE_KEY, FOUND_METHOD = match.group(1).lower(), "启动前文件检查"
                print("\n" + "="*50)
                print(f"🎉🎉🎉 任务未开始即发现密钥！通过【{FOUND_METHOD}】捕获！🎉🎉🎉")
                print(f"\n  完整私钥 (HEX): {FOUND_PRIVATE_KEY}\n")
                print("="*50)
                return # 直接退出

        # 如果之前有文件但没有内容，或者为了确保干净的测试，可以选择删除
        if os.path.exists(found_file): os.remove(found_file)

        gpu_params = get_gpu_params()
        print("="*45)

        # 【核心修复】直接构建并启动 cuBitCrack 命令
        bitcrack_command = [
            BITCRACK_PATH,
            '-b', str(gpu_params['blocks']),
            '-t', str(gpu_params['threads']),
            '-p', str(gpu_params['points']),
            '--keyspace', KEYSPACE,
            '-c', # 使用压缩公钥
            '-o', found_file,
            BTC_ADDRESS
        ]

        print(f"INFO: 即将执行命令: {' '.join(bitcrack_command)}")
        print("INFO: 任务启动中...")

        # 【核心修复】直接启动 cuBitCrack 并捕获其标准输出
        bitcrack_process = subprocess.Popen(
            bitcrack_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, # 将错误输出也重定向到标准输出
            text=True,
            encoding='utf-8',
            errors='replace', # 避免解码错误
            bufsize=1 # 行缓冲
        )
        processes_to_cleanup.append(bitcrack_process)
        print(f"✅ BitCrack 进程已直接启动 (PID: {bitcrack_process.pid})。")

        # 启动分离的监控线程
        monitor_file_thread = threading.Thread(target=file_monitor, args=(found_file,))
        monitor_stream_thread = threading.Thread(target=stream_monitor, args=(bitcrack_process,))

        monitor_file_thread.start()
        monitor_stream_thread.start()

        # 等待任一线程找到密钥或进程自己结束
        monitor_stream_thread.join()
        monitor_file_thread.join()

        # 等待 BitCrack 进程完全结束
        bitcrack_process.wait()

        print("\n" + "="*50)
        if FOUND_PRIVATE_KEY:
            print(f"🎉🎉🎉 测试成功！通过【{FOUND_METHOD}】捕获到密钥！🎉🎉🎉")
            print(f"\n  完整私钥 (HEX): {FOUND_PRIVATE_KEY}\n")
            print(f"  相关文件已保存至: {OUTPUT_DIR}")
        else:
            print("搜索任务已结束，但所有检查均未捕获到密钥。")
        print("="*50)

    except FileNotFoundError:
        print(f"\n[致命错误] BitCrack 执行文件未找到: '{BITCRACK_PATH}'。请检查路径是否正确。")
    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")
        import traceback
        traceback.print_exc()

if __name__ == '__main__':
    main()
