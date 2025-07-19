import subprocess
import psutil
import shlex

def get_gpu_info():
    """
    通过直接执行 nvidia-smi 命令来获取 GPU 信息 (推荐方式)。
    我们请求CSV格式的输出以便于解析。
    """
    print("--- 正在获取 GPU 信息 (推荐方式) ---")
    try:
        # 定义要查询的GPU属性
        query_args = [
            'index',
            'name',
            'temperature.gpu',
            'utilization.gpu',
            'memory.total',
            'memory.used',
            'memory.free'
        ]
        # 构建 nvidia-smi 命令
        command = [
            'nvidia-smi',
            f'--query-gpu={",".join(query_args)}',
            '--format=csv,noheader,nounits'
        ]
        
        # 执行命令并捕获输出
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        gpu_info_list = result.stdout.strip().split('\n')
        
        print("成功获取到 GPU 信息:")
        for i, gpu_info_str in enumerate(gpu_info_list):
            gpu_data = gpu_info_str.split(', ')
            print(f"\nGPU {gpu_data[0]}:")
            print(f"  产品名称: {gpu_data[1]}")
            print(f"  温度: {gpu_data[2]}°C")
            print(f"  GPU 使用率: {gpu_data[3]} %")
            print(f"  总显存: {gpu_data[4]} MiB")
            print(f"  已用显存: {gpu_data[5]} MiB")
            print(f"  剩余显存: {gpu_data[6]} MiB")

    except FileNotFoundError:
        print("错误: 'nvidia-smi' 命令未找到。请确保 NVIDIA 驱动已正确安装并且 'nvidia-smi' 在您的 PATH 中。")
    except subprocess.CalledProcessError as e:
        print(f"执行 nvidia-smi 时出错: {e}")
        print(f"错误输出:\n{e.stderr}")
    except Exception as e:
        print(f"发生未知错误: {e}")

def execute_wget_pipe_simulation():
    """
    模拟执行 'wget -qO- | command' 这种管道操作。
    这是一个处理您特殊需求的示例。在实际情况中，您需要将URL替换为真实的地址。
    """
    print("\n--- 模拟执行 'wget -qO- | grep' 管道命令 ---")
    try:
        # 这是一个示例命令。在真实场景中，URL应该是提供nvidia-smi输出的地址
        # 我们在这里用 'echo' 来模拟 wget 的输出
        cmd1 = "echo 'GPU 0: NVIDIA GeForce RTX 3080'"
        cmd2 = "grep 'RTX'"

        # 使用 shell=True 来执行管道命令
        # 安全警告: 当使用 shell=True 时，请确保命令内容是可信的，以避免安全风险。
        pipe_command = f"{cmd1} | {cmd2}"
        print(f"执行管道命令: {pipe_command}")
        
        result = subprocess.run(pipe_command, shell=True, capture_output=True, text=True, check=True)
        
        print("管道命令输出:")
        print(result.stdout.strip())
        
    except subprocess.CalledProcessError as e:
        print(f"执行管道命令时出错: {e}")
        print(f"错误输出:\n{e.stderr}")
    except Exception as e:
        print(f"发生未知错误: {e}")


def find_specific_processes():
    """
    在Linux环境中寻找指定的进程。
    """
    print("\n--- 正在寻找指定进程 ---")
    
    processes_to_find = {
        "KeyHunt": "/workspace/keyhunt/keyhunt",
        "BitCrack": "/workspace/BitCrack/bin/cuBitCrack"
    }
    
    found_processes = {name: [] for name in processes_to_find}
    
    # 遍历所有正在运行的进程
    for proc in psutil.process_iter(['pid', 'name', 'exe', 'cmdline']):
        try:
            for name, path in processes_to_find.items():
                # 检查进程的可执行文件路径是否匹配
                if proc.info['exe'] and proc.info['exe'] == path:
                    found_processes[name].append({
                        'pid': proc.info['pid'],
                        'name': proc.info['name'],
                        'cmdline': ' '.join(proc.info['cmdline']) if proc.info['cmdline'] else ''
                    })
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass # 某些进程可能在迭代时已经结束或无法访问

    # 打印结果
    for name, procs in found_processes.items():
        if procs:
            print(f"\n找到正在运行的 '{name}' 进程:")
            for p_info in procs:
                print(f"  - PID: {p_info['pid']}, 名称: {p_info['name']}, 命令行: {p_info['cmdline']}")
        else:
            print(f"\n未找到正在运行的 '{name}' 进程 (路径: {processes_to_find[name]})")

if __name__ == "__main__":
    # 1. 获取并显示 GPU 信息
    get_gpu_info()
    
    # 2. 演示如何执行管道命令
    execute_wget_pipe_simulation()
    
    # 3. 寻找指定的进程
    find_specific_processes()
