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
# 【注意】为了演示，这个范围很小，会很快跑完
KEYSPACE = '0000000000000000000000000000000000000000000000000000000000000001:00000000000000000000000000000000000000000000000000000000000FFFFF'


# --- 2. 全局状态与正则表达式 ---

# 【修复】使用集合和字典来存储所有发现的密钥及其来源
FOUND_KEYS = set()
FOUND_METHODS = {}
processes_to_cleanup = []

# 正则表达式
STDOUT_KEY_RE = re.compile(r'Key: ([0-9a-fA-F]{64})')
FILE_PRIV_KEY_RE = re.compile(r'([0-9a-fA-F]{64})')

# --- 3. 系统信息与硬件检测 (与上一版相同，保持不变) ---

def display_system_info():
    """在主控窗口显示简要的系统信息"""
    print("--- 系统状态 (BitCrack 最终修复版 v3) ---")
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

# --- 4. 核心执行逻辑与【持续监控】 ---

def cleanup():
    """程序退出时，清理所有子进程。"""
    print("\n[CLEANUP] 正在终止所有子进程...")
    for p in processes_to_cleanup:
        try:
            if p.poll() is None:
                parent = psutil.Process(p.pid)
                for child in parent.children(recursive=True):
                    child.terminate()
                parent.terminate()
                p.wait(timeout=3)
        except psutil.NoSuchProcess:
            pass
        except Exception as e:
            if p.poll() is None: p.kill()
            print(f"[CLEANUP] 清理进程时出错: {e}")
    print(f"[CLEANUP] 清理完成。")

atexit.register(cleanup)

def add_key(key, method):
    """【新】统一添加密钥的函数，避免重复并打印实时通知。"""
    if key not in FOUND_KEYS:
        FOUND_KEYS.add(key)
        FOUND_METHODS[key] = method
        print(f"\n🔔🔔🔔 [实时发现] 通过<{method}>捕获到新密钥: {key[:16]}... 🔔🔔🔔\n")

def file_monitor(file_path, process):
    """【文件监控线程】只要主进程在运行，就周期性检查文件。"""
    print("✅ [文件监控] 线程已启动...")
    while process.poll() is None:
        if os.path.exists(file_path) and os.path.getsize(file_path) > 0:
            try:
                with open(file_path, 'r') as f_check:
                    # 使用 findall 查找文件中所有的 key
                    matches = FILE_PRIV_KEY_RE.findall(f_check.read())
                for match in matches:
                    add_key(match.lower(), "文件监控")
            except IOError:
                pass
        # 【修复】即使找到密钥也继续监控，直到主进程结束
        time.sleep(2)
    print("[文件监控] 主进程已结束，监控循环停止。")

def stream_monitor(process):
    """【输出流监控线程】实时读取和解析cuBitCrack的标准输出。"""
    print("✅ [输出流监控] 线程已启动，实时解析屏幕输出...")
    for line in iter(process.stdout.readline, ''):
        sys.stdout.write(line)
        sys.stdout.flush()
        match = STDOUT_KEY_RE.search(line)
        if match:
            add_key(match.group(1).lower(), "屏幕输出")
        # 当主进程结束后，这个循环会自动退出
    print("[输出流监控] 主进程已结束，监控循环停止。")

def main():
    """主函数，负责设置和启动测试任务。"""
    global FOUND_KEYS, FOUND_METHODS

    display_system_info()
    time.sleep(1)

    try:
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        found_file = os.path.join(OUTPUT_DIR, 'found_keys_test.txt')

        # --- 【修复】启动前检查文件，但不退出 ---
        print(f"INFO: 检查已存在的文件: {found_file}")
        if os.path.exists(found_file) and os.path.getsize(found_file) > 0:
            with open(found_file, 'r') as f:
                matches = FILE_PRIV_KEY_RE.findall(f.read())
            if matches:
                print("-" * 20)
                print("⚠️  启动前警告：输出文件已包含密钥！")
                for match in matches:
                    add_key(match.lower(), "启动前文件检查")
                print("-" * 20)
            else:
                 print("INFO: 文件存在但为空，将在本次运行中被覆盖。")
        else:
            print("INFO: 未发现已存在的密钥文件，将创建新文件。")


        gpu_params = get_gpu_params()
        print("="*45)

        bitcrack_command = [
            BITCRACK_PATH, '-b', str(gpu_params['blocks']), '-t', str(gpu_params['threads']),
            '-p', str(gpu_params['points']), '--keyspace', KEYSPACE, '-c', '-o', found_file,
            BTC_ADDRESS
        ]

        print(f"INFO: 即将执行命令: {' '.join(bitcrack_command)}")
        print("INFO: 任务启动中，请稍候...")
        time.sleep(2)

        bitcrack_process = subprocess.Popen(
            bitcrack_command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding='utf-8', errors='replace', bufsize=1
        )
        processes_to_cleanup.append(bitcrack_process)
        print(f"✅ BitCrack 进程已直接启动 (PID: {bitcrack_process.pid})。现在开始持续监控...")

        # 启动监控线程，【修复】将 bitcrack_process 传递给 file_monitor
        monitor_file_thread = threading.Thread(target=file_monitor, args=(found_file, bitcrack_process))
        monitor_stream_thread = threading.Thread(target=stream_monitor, args=(bitcrack_process,))

        monitor_file_thread.start()
        monitor_stream_thread.start()

        # 【修复】等待 BitCrack 进程自己运行结束，而不是等找到密钥
        bitcrack_process.wait()

        print("\nINFO: BitCrack 主进程已完成其搜索范围。")
        print("INFO: 等待监控线程完成最后的检查...")

        # 等待监控线程优雅地退出
        monitor_stream_thread.join(timeout=5)
        monitor_file_thread.join(timeout=5)

        # --- 最终总结报告 ---
        print("\n" + "="*60)
        print("🎉🎉🎉  任务执行完毕 - 最终密钥报告  🎉🎉🎉")
        print("="*60)

        if FOUND_KEYS:
            print(f"在本次运行中，共发现 {len(FOUND_KEYS)} 个唯一密钥：\n")
            i = 1
            for key in sorted(list(FOUND_KEYS)): # 排序后输出
                method = FOUND_METHODS.get(key, "未知来源")
                print(f"  {i}. 密钥 (HEX): {key}")
                print(f"     捕获方式: 【{method}】\n")
                i += 1
            print(f"所有相关文件均已保存在: {OUTPUT_DIR}")
        else:
            print("本次任务已结束，但在整个过程中未发现任何密钥。")
        print("="*60)

    except FileNotFoundError:
        print(f"\n[致命错误] BitCrack 执行文件未找到: '{BITCRACK_PATH}'。请检查路径是否正确。")
    except Exception as e:
        print(f"\n[致命错误] 脚本主程序发生错误: {e}")
        import traceback
        traceback.print_exc()

if __name__ == '__main__':
    main()
