import subprocess
import os
import threading
import sys
import atexit

# --- 1. 基础配置 (路径是绝对的，无需修改) ---

# 可执行文件的绝对路径
KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'
BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack'

# 文件输出目录 (固定到桌面)
OUTPUT_DIR = '/home/desktop/'

# 搜索的目标比特币地址
BTC_ADDRESS = '1DBaumZxUkM4qMQRt2LVWyFJq5kDtSZQot'

# 密钥搜索范围
START_KEY = '0000000000000000000000000000000000000000000000000000000000000800'
END_KEY = '0000000000000000000000000000000000000000000000000000000000000fff'


# --- 2. 动态参数与环境自适应 (已修复路径问题) ---

# 全局变量，用于存放子进程
processes = []

def get_cpu_threads():
    """自动检测CPU核心数并返回一个合理的线程数。"""
    try:
        cpu_cores = os.cpu_count()
        threads = max(1, cpu_cores - 1 if cpu_cores > 1 else 1)
        print(f"INFO: 检测到 {cpu_cores} 个CPU核心。将为 KeyHunt 分配 {threads} 个线程。")
        return threads
    except Exception as e:
        print(f"WARN: 无法自动检测CPU核心数，将使用默认值 4。错误: {e}")
        return 4

def get_gpu_params():
    """通过nvidia-smi的绝对路径来检测GPU SM数，并返回cuBitCrack的推荐参数。"""
    default_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    NVIDIA_SMI_PATH = '/usr/bin/nvidia-smi'
    try:
        if not os.path.exists(NVIDIA_SMI_PATH):
             raise FileNotFoundError(f"'{NVIDIA_SMI_PATH}' not found.")
        command = [NVIDIA_SMI_PATH, '--query-gpu=multiprocessor_count', '--format=csv,noheader']
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        sm_count = int(result.stdout.strip())
        
        blocks = sm_count * 7 
        threads = 256
        points = 1024
        
        print(f"INFO: 检测到 GPU 有 {sm_count} 个流式多处理器 (SMs)。")
        print(f"INFO: 将为 cuBitCrack 自动配置参数: blocks={blocks}, threads={threads}, points={points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}
        
    except Exception as e:
        print(f"WARN: 无法通过 {NVIDIA_SMI_PATH} 自动检测GPU。将使用默认参数。错误: {e}")
        return default_params

# --- 3. 进程管理与执行逻辑 ---

def cleanup_processes():
    """程序退出时，只终止所有子进程，不删除任何文件。"""
    global processes
    print("INFO: 脚本退出，正在终止所有子进程...")
    for p in processes:
        if p.poll() is None:
            try:
                p.terminate()
                p.wait(timeout=5)
            except:
                p.kill()
    print("INFO: 子进程清理完成。文件已保留。")

atexit.register(cleanup_processes)
key_found_event = threading.Event()

def run_and_monitor(command, tool_name):
    """在线程中运行命令，监控输出，并在找到密钥时触发全局停止事件。"""
    global processes
    print("-" * 60)
    print(f"🚀 正在启动 {tool_name}...")
    print(f"   执行命令: {' '.join(command)}")
    print("-" * 60)
    
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, universal_newlines=True
        )
        processes.append(process)

        while not key_found_event.is_set():
            output = process.stdout.readline()
            if output == '' and process.poll() is not None: break
            if output:
                sys.stdout.write(f"[{tool_name}] {output.strip()}\n")
                sys.stdout.flush()
                if 'KEY FOUND' in output.upper() or 'PRIVATE KEY' in output.upper():
                    print("\n" + "="*80)
                    print(f"🎉🎉🎉 胜利！ {tool_name} 找到了密钥！请立即查看上面的日志！🎉🎉🎉")
                    print(f"🎉🎉🎉 相关文件保存在 '{OUTPUT_DIR}' 目录中。 🎉🎉🎉")
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
    """主函数，用于并行启动搜索任务。"""
    try:
        # --- 创建输出目录 (如果不存在) ---
        print("="*80)
        print(f"INFO: 所有文件将被创建在: {OUTPUT_DIR}")
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        print(f"INFO: 目录 '{OUTPUT_DIR}' 已准备就绪。")
        
        # 定义文件的完整路径
        kh_address_file = os.path.join(OUTPUT_DIR, 'target_address.txt')
        bc_found_file = os.path.join(OUTPUT_DIR, 'found.txt')
        bc_progress_file = os.path.join(OUTPUT_DIR, 'progress.dat')

        # --- 智能参数配置 ---
        print("INFO: 正在根据系统硬件自动配置性能参数...")
        keyhunt_threads = get_cpu_threads()
        cubitcrack_params = get_gpu_params()
        print("="*80)

        # --- 准备工作 ---
        with open(kh_address_file, 'w') as f: f.write(BTC_ADDRESS)
        
        # --- 构建命令 ---
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

        # --- 创建并启动线程 ---
        thread_keyhunt = threading.Thread(target=run_and_monitor, args=(keyhunt_command, "KeyHunt"))
        thread_bitcrack = threading.Thread(target=run_and_monitor, args=(bitcrack_command, "BitCrack"))

        thread_keyhunt.start()
        thread_bitcrack.start()

        thread_keyhunt.join()
        thread_bitcrack.join()
        
        print("\n" + "="*80)
        if key_found_event.is_set():
            print(f"搜索结束！关键信息已打印在上方日志中。")
        else:
            print("所有搜索任务已在指定范围内完成，未找到密钥。")
        print(f"所有相关文件 (如 found.txt, progress.dat) 都保存在 '{OUTPUT_DIR}' 目录中。")
        print("="*80)

    except Exception as e:
        print(f"脚本主程序发生致命错误: {e}")
    finally:
        print("INFO: 脚本执行完毕。")


if __name__ == '__main__':
    main()
