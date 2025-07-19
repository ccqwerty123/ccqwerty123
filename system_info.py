#!/usr/bin/env python3
import subprocess
import psutil
import os

def get_system_info():
    """
    获取并简略输出 GPU 和 CPU 的核心信息。
    """
    print("--- 系统核心信息 ---")
    
    # 1. 获取 GPU 信息
    try:
        # 定义要查询的GPU属性
        query_args = [
            'index',
            'name',
            'temperature.gpu',
            'utilization.gpu',
            'memory.used',
            'memory.total'
        ]
        # 构建并执行 nvidia-smi 命令
        command = [
            'nvidia-smi',
            f'--query-gpu={",".join(query_args)}',
            '--format=csv,noheader,nounits'
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        gpu_info_list = result.stdout.strip().split('\n')
        
        # 格式化输出
        for gpu_info_str in gpu_info_list:
            if not gpu_info_str: continue
            gpu_data = gpu_info_str.split(', ')
            print(f"  - GPU {gpu_data[0]}: {gpu_data[1]}, Temp: {gpu_data[2]}°C, Util: {gpu_data[3]}%, Mem: {gpu_data[4]}/{gpu_data[5]} MiB")

    except (FileNotFoundError, subprocess.CalledProcessError):
        print("  - GPU: 未能获取到 NVIDIA GPU 信息。")
    
    # 2. 获取 CPU 信息
    try:
        cpu_usage = psutil.cpu_percent(interval=0.5)
        cpu_cores = psutil.cpu_count(logical=False) # 物理核心数
        cpu_threads = psutil.cpu_count(logical=True) # 逻辑核心数 (线程)
        print(f"  - CPU: {cpu_cores}核 {cpu_threads}线程, 使用率: {cpu_usage}%")
    except Exception as e:
        print(f"  - CPU: 未能获取到 CPU 信息: {e}")


def find_and_terminate_processes():
    """
    通过进程名查找并结束指定的进程，不关心其完整路径。
    """
    print("\n--- 正在结束指定进程 ---")
    
    # 需要被结束的进程名列表 (统一使用小写，以便进行不区分大小写的比较)
    processes_to_kill = ['keyhunt', 'bitcrack', 'cubitcrack']
    
    terminated_count = 0
    
    # 遍历所有正在运行的进程
    for proc in psutil.process_iter(['pid', 'name']):
        try:
            # 检查进程名 (转为小写后) 是否在我们的目标列表中
            proc_name_lower = proc.info['name'].lower()
            if proc_name_lower in processes_to_kill:
                pid = proc.info['pid']
                print(f"  - 发现目标进程: '{proc.info['name']}' (PID: {pid})。正在尝试结束...")
                
                # 获取进程对象并结束它
                p = psutil.Process(pid)
                p.terminate() # 发送 SIGTERM 信号，请求进程优雅退出
                
                # 等待一小段时间，然后检查进程是否真的被终止了
                gone, alive = psutil.wait_procs([p], timeout=1)
                if alive:
                    p.kill() # 如果优雅退出失败，则强制结束 (SIGKILL)
                    print(f"  - 进程 (PID: {pid}) 未能优雅退出，已强制结束。")
                else:
                    print(f"  - 进程 (PID: {pid}) 已成功结束。")
                
                terminated_count += 1
                
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            # 进程可能在我们操作时已经消失，或者我们没有权限
            pass
        except Exception as e:
            print(f"  - 错误: 结束进程时发生意外: {e}")

    if terminated_count == 0:
        print("  - 未找到任何正在运行的 'KeyHunt' 或 'BitCrack' 进程。")


if __name__ == "__main__":
    # 检查是否以root权限运行
    if os.geteuid() != 0:
        print("警告: 脚本未使用root权限运行，可能无法结束所有目标进程。\n")

    # 1. 获取并显示系统信息
    get_system_info()
    
    # 2. 查找并结束指定进程
    find_and_terminate_processes()
