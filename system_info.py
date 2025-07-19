import sys
import subprocess
import platform
import os
import math

# --- 依赖检测 ---
try:
    import psutil
except ImportError:
    print("错误: 缺少 'psutil' 库。")
    print("\n请尝试手动运行以下命令来安装它:")
    print("  `python3 -m pip install psutil --break-system-packages` 或使用虚拟环境。")
    sys.exit(1)

def get_cgroup_cpu_limit():
    """
    在 Linux 环境中检测 cgroup CPU 限制，计算出可用的核心数。
    这是在容器化环境（如 Docker, Cloud Studio）中获取真实 CPU 配额的关键。
    返回一个浮点数表示的核心数，如果未检测到限制则返回 None。
    """
    # 仅在 Linux 系统上执行
    if not platform.system() == "Linux":
        return None

    try:
        # cgroup v1 的路径
        cfs_period_us_path = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
        cfs_quota_us_path = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"

        # cgroup v2 的路径
        cpu_max_path = "/sys/fs/cgroup/cpu.max"

        # 优先检查 cgroup v2
        if os.path.exists(cpu_max_path):
            with open(cpu_max_path, 'r') as f:
                content = f.read().strip()
            
            parts = content.split()
            if len(parts) == 2 and parts[0] != 'max':
                quota, period = map(int, parts)
                return quota / period

        # 如果 v2 不存在或无限制，检查 cgroup v1
        elif os.path.exists(cfs_period_us_path) and os.path.exists(cfs_quota_us_path):
            with open(cfs_period_us_path, 'r') as f:
                period = int(f.read().strip())
            with open(cfs_quota_us_path, 'r') as f:
                quota = int(f.read().strip())

            # quota 为 -1 表示没有限制
            if quota > 0 and period > 0:
                return quota / period
                
    except Exception:
        # 如果发生任何错误（如权限问题），则假定无限制
        return None
    
    # 如果所有检查都未发现限制
    return None


def get_usable_cores():
    """
    获取推荐用于并行处理的工作进程数。
    优先使用 cgroup 限制，如果无限制则回退到系统的逻辑核心数。
    """
    # 尝试从 cgroup 获取精确的 CPU 配额
    core_limit = get_cgroup_cpu_limit()
    
    if core_limit is not None:
        # 如果有配额，即使是小数（如0.5），也至少保证1个工作进程。
        # 使用 math.floor 可以确保不超过配额，但至少为1。
        return max(1, math.floor(core_limit))
    else:
        # 如果没有 cgroup 限制，则使用系统的全部逻辑核心
        # os.cpu_count() 是获取逻辑核心数的推荐方法
        return os.cpu_count() or 1


def get_size(bytes_val, suffix="B"):
    """将字节数转换为易读的格式。"""
    factor = 1024
    for unit in ["", "K", "M", "G", "T", "P"]:
        if bytes_val < factor:
            return f"{bytes_val:.2f}{unit}{suffix}"
        bytes_val /= factor

def get_system_info():
    """收集并打印详细的系统信息，包括真实的可用资源。"""
    print("="*40, "物理主机信息", "="*40)
    
    # --- 操作系统信息 ---
    uname = platform.uname()
    print(f"操作系统: {uname.system}")
    print(f"版本: {uname.release}")
    print(f"处理器架构: {uname.machine}")

    # --- 物理 CPU 信息 ---
    print("\n" + "="*40, "物理 CPU 信息 (主机)", "="*40)
    print(f"物理核心数: {psutil.cpu_count(logical=False)}")
    print(f"逻辑核心数 (总线程数): {psutil.cpu_count(logical=True)}")

    # --- 物理内存信息 ---
    print("\n" + "="*40, "物理内存 (RAM) 信息 (主机)", "="*40)
    svmem = psutil.virtual_memory()
    print(f"总大小: {get_size(svmem.total)}")
    print(f"可用空间: {get_size(svmem.available)}")
    print(f"使用率: {svmem.percent}%")

    # --- 关键部分：可用资源 ---
    print("\n" + "="*35, "您的环境可用/受限资源", "="*35)
    
    # 获取精确的 cgroup 配额 (可能是小数)
    core_limit_float = get_cgroup_cpu_limit()
    # 获取推荐的、用于创建进程池的整数核心数
    usable_cores = get_usable_cores()

    if core_limit_float is not None:
        print(f"检测到 Cgroup CPU 限制，精确配额: {core_limit_float:.2f} 核")
        print(f"✅ 推荐的可用核心数 (用于并行计算): {usable_cores}")
    else:
        print("未检测到 Cgroup CPU 限制。")
        print(f"✅ 可用核心数 (与主机逻辑核心数相同): {usable_cores}")

    print("\n" + "="*90)
    print(f"💡 提示: 当您需要并行处理任务时（例如使用 `multiprocessing.Pool`），")
    print(f"   建议您使用 **{usable_cores}** 作为工作进程数，而不是 {psutil.cpu_count(logical=True)}。")
    print("="*90)


if __name__ == "__main__":
    get_system_info()
