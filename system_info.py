import sys
import subprocess
import platform
from datetime import datetime

# --- 自动安装依赖 ---
try:
    # 尝试导入 psutil 库
    import psutil
except ImportError:
    # 如果导入失败，提示用户并尝试自动安装
    print("未检测到 'psutil' 库，正在尝试自动安装...")
    try:
        # 使用 subprocess 调用 pip 来安装
        # sys.executable 指向当前运行的 Python 解释器，确保 pip 为正确的 Python 版本安装库
        subprocess.check_call([sys.executable, "-m", "pip", "install", "psutil"])
        print("'psutil' 安装成功。")
        # 再次尝试导入
        import psutil
    except Exception as e:
        # 如果安装失败，打印错误信息并退出
        print(f"自动安装 'psutil' 失败: {e}")
        print("请手动在终端运行 'pip install psutil' 或 'python -m pip install psutil' 后再试。")
        sys.exit(1) # 退出脚本

def get_size(bytes, suffix="B"):
    """
    将字节数转换为易读的格式 (KB, MB, GB, TB, PB)。
    """
    factor = 1024
    for unit in ["", "K", "M", "G", "T", "P"]:
        if bytes < factor:
            return f"{bytes:.2f}{unit}{suffix}"
        bytes /= factor

def get_system_info():
    """
    收集并打印详细的系统信息。
    """
    print("="*40, "系统信息", "="*40)
    
    # --- 操作系统信息 ---
    uname = platform.uname()
    print(f"操作系统: {uname.system}")
    print(f"版本: {uname.release}")
    print(f"计算机名称: {uname.node}")
    print(f"处理器架构: {uname.machine}")

    # --- CPU 信息 ---
    print("\n" + "="*40, "CPU 信息", "="*40)
    # 物理核心数
    physical_cores = psutil.cpu_count(logical=False)
    # 逻辑核心数
    logical_cores = psutil.cpu_count(logical=True)
    # CPU使用率
    cpu_usage = psutil.cpu_percent(interval=1)
    
    print(f"物理核心数: {physical_cores}")
    print(f"逻辑核心数 (线程数): {logical_cores}")
    print(f"当前 CPU 总使用率: {cpu_usage}%")
    
    # 各个核心的使用率
    print("各核心使用率:")
    for i, percentage in enumerate(psutil.cpu_percent(percpu=True, interval=1)):
        print(f"  核心 {i}: {percentage}%")

    # --- 内存信息 ---
    print("\n" + "="*40, "内存 (RAM) 信息", "="*40)
    svmem = psutil.virtual_memory() # 获取虚拟内存信息 [1]
    print(f"总大小: {get_size(svmem.total)}")
    print(f"可用空间: {get_size(svmem.available)}")
    print(f"已用空间: {get_size(svmem.used)}")
    print(f"使用率: {svmem.percent}%")

    # --- 磁盘信息 ---
    print("\n" + "="*40, "磁盘信息", "="*40)
    # 获取根分区（'/' for Linux/macOS, 'C:\' for Windows）的使用情况
    partition_path = "C:\\" if platform.system() == "Windows" else "/"
    disk_usage = psutil.disk_usage(partition_path)
    print(f"信息来源分区: {partition_path}")
    print(f"总大小: {get_size(disk_usage.total)}")
    print(f"已用空间: {get_size(disk_usage.used)}")
    print(f"可用空间: {get_size(disk_usage.free)}")
    print(f"使用率: {disk_usage.percent}%")
    
    print("\n" + "="*90)

if __name__ == "__main__":
    get_system_info()
