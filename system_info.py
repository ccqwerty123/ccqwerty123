import subprocess
import os
import threading
import sys
import atexit

# --- 1. 基础配置 (可按需修改) ---

# 可执行文件的路径
KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'
BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack'

# 搜索的目标比特币地址
BTC_ADDRESS = '1DBaumZxUkM4qMQRt2LVWyFJq5kDtSZQot'

# 密钥搜索范围
START_KEY = '0000000000000000000000000000000000000000000000000000000000000800'
END_KEY = '0000000000000000000000000000000000000000000000000000000000000fff'

# 文件路径
KH_ADDRESS_FILE = '/workspace/target_address.txt'
BC_FOUND_FILE = '/workspace/found.txt'
BC_PROGRESS_FILE = '/workspace/progress.dat'

# --- 2. 智能硬件检测与参数调整 ---

def get_cpu_threads():
    """自动检测CPU核心数并返回一个合理的线程数。"""
    try:
        cpu_cores = os.cpu_count()
        # 使用 总核心数-1，但最少保留1个核心给KeyHunt
        threads = max(1, cpu_cores - 1)
        print(f"INFO: 检测到 {cpu_cores} 个CPU核心。将为 KeyHunt 分配 {threads} 个线程。")
        return threads
    except Exception as e:
        print(f"WARN: 无法自动检测CPU核心数，将使用默认值 15。错误: {e}")
        return 15 # 如果检测失败，回退到默认值

def get_gpu_params():
    """通过nvidia-smi自动检测GPU SM数，并返回cuBitCrack的推荐参数。"""
    default_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    try:
        # 查询GPU的流式多处理器(SM)数量
        command = ['nvidia-smi', '--query-gpu=multiprocessor_count', '--format=csv,noheader']
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        sm_count = int(result.stdout.strip())
        
        # 基于SM数计算参数
        # 策略: block数设置为SM数的倍数以充分利用GPU
        blocks = sm_count * 7 
        threads = 256 # 通用高效值
        points = 1024 # 高性能值
        
        print(f"INFO: 检测到 GPU 有 {sm_count} 个流式多处理器 (SMs)。")
        print(f"INFO: 将为 cuBitCrack 自动配置参数: blocks={blocks}, threads={threads}, points={points}")
        return {'blocks': blocks, 'threads': threads, 'points': points}
        
    except (FileNotFoundError, subprocess.CalledProcessError, ValueError) as e:
        print(f"WARN: 无法通过 nvidia-smi 自动检测GPU。将使用默认参数。错误: {e}")
        return default_params # 如果检测失败，回退到默认值

# --- 3. 进程管理与执行逻辑 (无需修改) ---

key_found_event = threading.Event()
processes = []

def cleanup():
    """程序退出时，确保所有子进程都被终止。"""
    for p in processes:
        if p.poll() is None:
            p.terminate()
            p.wait()

atexit.register(cleanup)

def run_and_monitor(command, tool_name):
    """在线程中运行命令，监控输出，并在找到密钥时触发全局停止事件。"""
    global processes
    print("-" * 60)
    print(f"🚀 正在启动 {tool_name}...")
    print(f"   执行命令: {' '.join(command)}")
    print("-" * 60)
    
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1
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
    """主函数，用于并行启动搜索任务。"""
    print("="*80)
    print("正在根据系统硬件自动配置性能参数...")
    
    # 获取动态参数
    keyhunt_threads = get_cpu_threads()
    cubitcrack_params = get_gpu_params()
    
    print("="*80)

    # 准备文件
    with open(KH_ADDRESS_FILE, 'w') as f: f.write(BTC_ADDRESS)
    
    # 构建命令
    keyhunt_command = [
        KEYHUNT_PATH, '-m', 'address', '-f', KH_ADDRESS_FILE,
        '-l', 'both', '-t', str(keyhunt_threads),
        '-r', f'{START_KEY}:{END_KEY}'
    ]

    bitcrack_command = [
        BITCRACK_PATH,
        '-b', str(cubitcrack_params['blocks']),
        '-t', str(cubitcrack_params['threads']),
        '-p', str(cubitcrack_params['points']),
        '--keyspace', f'{START_KEY}:{END_KEY}',
        '-o', BC_FOUND_FILE, '--continue', BC_PROGRESS_FILE,
        BTC_ADDRESS
    ]

    # 创建并启动线程
    thread_keyhunt = threading.Thread(target=run_and_monitor, args=(keyhunt_command, "KeyHunt"))
    thread_bitcrack = threading.Thread(target=run_and_monitor, args=(bitcrack_command, "BitCrack"))

    thread_keyhunt.start()
    thread_bitcrack.start()

    thread_keyhunt.join()
    thread_bitcrack.join()
    
    print("\n" + "="*80)
    if key_found_event.is_set():
        print(f"搜索结束！请检查上方日志和输出文件 '{BC_FOUND_FILE}'。")
    else:
        print("所有搜索任务已在指定范围内完成，未找到密钥。")
    print("="*80)

if __name__ == '__main__':
    main()
