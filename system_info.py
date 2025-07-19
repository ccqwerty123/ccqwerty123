import subprocess
import os
import threading
import sys
import atexit
import re

# --- 1. 基础配置 ---

KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'
BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack'
OUTPUT_DIR = '/home/desktop/'
BTC_ADDRESS = '1DBaumZxUkM4qMQRt2LVWyFJq5kDtSZQot'
START_KEY = '0000000000000000000000000000000000000000000000000000000000000800'
END_KEY = '0000000000000000000000000000000000000000000000000000000000000fff'

# --- 2. 全局状态与精确的正则表达式 ---

FOUND_PRIVATE_KEY = None
key_found_event = threading.Event()
processes = []

# 为每个工具定义精确的正则表达式
# KeyHunt 格式: Private key (hex): FFFFF...
KEYHUNT_PRIV_KEY_RE = re.compile(r'Private key \(hex\):\s*([0-9a-fA-F]{64})')
# cuBitCrack 格式: ... Priv:FFFFF...
CUBITCRACK_PRIV_KEY_RE = re.compile(r'Priv:([0-9a-fA-F]{64})')

# --- 3. 硬件检测与参数配置 (更稳健) ---

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

def get_gpu_params():
    """通过nvidia-smi检测GPU，并传递完整环境变量以提高成功率。"""
    default_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    NVIDIA_SMI_PATH = '/usr/bin/nvidia-smi'
    try:
        if not os.path.exists(NVIDIA_SMI_PATH):
             raise FileNotFoundError(f"'{NVIDIA_SMI_PATH}' not found.")
        command = [NVIDIA_SMI_PATH, '--query-gpu=multiprocessor_count', '--format=csv,noheader']
        # 传递当前环境变量给子进程，这可能解决驱动通信问题
        result = subprocess.run(
            command, capture_output=True, text=True, check=True, env=os.environ
        )
        sm_count = int(result.stdout.strip())
        
        blocks, threads, points = sm_count * 7, 256, 1024
        print(f"INFO: 成功检测到 GPU 有 {sm_count} SMs。自动配置参数: -b {blocks} -t {threads} -p {points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}
        
    except Exception as e:
        print(f"WARN: 自动检测GPU失败。这在某些容器环境中是正常的。错误: {e}")
        print("WARN: 将为 cuBitCrack 使用默认的高性能参数。")
        return default_params

# --- 4. 进程管理与核心执行逻辑 ---

def cleanup_processes():
    """程序退出时，只终止所有子进程，不删除文件。"""
    for p in processes:
        if p.poll() is None:
            try: p.terminate()
            except: pass

atexit.register(cleanup_processes)

def run_and_monitor(command, tool_name, regex_pattern):
    """运行命令，使用指定的正则表达式监控输出，并解析私钥。"""
    global processes, FOUND_PRIVATE_KEY
    print(f"🚀 正在启动 {tool_name}...\n   执行: {' '.join(command)}")
    
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1
        )
        processes.append(process)

        for line in iter(process.stdout.readline, ''):
            if key_found_event.is_set(): break
            
            sys.stdout.write(f"[{tool_name}] {line.strip()}\n")
            sys.stdout.flush()

            match = regex_pattern.search(line)
            if match:
                FOUND_PRIVATE_KEY = match.group(1).lower() # 统一转为小写
                print("\n" + "="*80)
                print(f"🎉🎉🎉 胜利！ {tool_name} 找到了密钥！正在停止所有搜索... 🎉🎉🎉")
                print("="*80 + "\n")
                key_found_event.set()
                break
        
        if process.poll() is None: process.terminate()
        process.wait()
        print(f"[{tool_name}] 进程已停止。")

    except Exception as e:
        print(f"[{tool_name}] 发生严重错误: {e}")
        key_found_event.set()

def main():
    """主函数，负责设置和启动所有任务。"""
    try:
        print("="*80)
        print("INFO: 永久文件将被保存在: " + OUTPUT_DIR)
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        
        # 确保所有文件路径都正确
        kh_address_file = os.path.join(OUTPUT_DIR, 'target_address.txt')
        bc_found_file = os.path.join(OUTPUT_DIR, 'found.txt')
        bc_progress_file = os.path.join(OUTPUT_DIR, 'progress.dat')

        print("INFO: 正在根据系统硬件自动配置性能参数...")
        keyhunt_threads = get_cpu_threads()
        cubitcrack_params = get_gpu_params()
        print("="*80)

        with open(kh_address_file, 'w') as f: f.write(BTC_ADDRESS)
        
        keyhunt_command = [
            KEYHUNT_PATH, '-m', 'address', '-f', kh_address_file,
            '-l', 'both', '-t', str(keyhunt_threads),
            '-r', f'{START_KEY}:{END_KEY}'
        ]

        bitcrack_command = [
            BITCRACK_PATH,
            '-b', str(cubitcrack_params['blocks']),
            '-t', str(cubitcrack_params['threads']),
            '-p', str(cubitcrack_params['points']),
            '--keyspace', f'{START_KEY}:{END_KEY}',
            '-o', bc_found_file, '--continue', bc_progress_file,
            BTC_ADDRESS
        ]

        # 为每个工具启动一个线程，并传入其专属的正则表达式
        thread_keyhunt = threading.Thread(target=run_and_monitor, args=(keyhunt_command, "KeyHunt", KEYHUNT_PRIV_KEY_RE))
        thread_bitcrack = threading.Thread(target=run_and_monitor, args=(bitcrack_command, "BitCrack", CUBITCRACK_PRIV_KEY_RE))

        thread_keyhunt.start()
        thread_bitcrack.start()
        thread_keyhunt.join()
        thread_bitcrack.join()
        
        print("\n" + "="*80)
        if FOUND_PRIVATE_KEY:
            print("🎉🎉🎉 最终结果：私钥已找到并提取！ 🎉🎉🎉")
            print(f"\n  私钥 (HEX): {FOUND_PRIVATE_KEY}\n")
            print("您可以复制上面的私钥用于后续操作。")
        else:
            print("所有搜索任务已在指定范围内完成，未找到密钥。")
        print(f"所有相关文件 (如 found.txt, progress.dat) 都保留在 '{OUTPUT_DIR}' 目录中。")
        print("="*80)

    except Exception as e:
        print(f"脚本主程序发生致命错误: {e}")

if __name__ == '__main__':
    main()
