import sys
import subprocess
import platform
import os
import math
import re

# --- 依赖检测 ---
try:
    import psutil
except ImportError:
    print("错误: 缺少 'psutil' 库。")
    print("\n请尝试手动运行以下命令来安装它:")
    print("  `python3 -m pip install psutil --break-system-packages` 或使用虚拟环境。")
    sys.exit(1)

def parse_cpu_set(cpu_set_str):
    """解析 CPU 集合字符串 (例如 '0-3,7') 并返回核心数。"""
    count = 0
    if not cpu_set_str:
        return 0
    # 移除所有空白字符
    cpu_set_str = re.sub(r'\s+', '', cpu_set_str)
    
    parts = cpu_set_str.split(',')
    for part in parts:
        if '-' in part:
            start, end = map(int, part.split('-'))
            count += (end - start + 1)
        else:
            count += 1
    return count

def get_effective_cpu_count():
    """
    通过多种方法检测真实可用的CPU核心数，返回一个整数和检测方法。
    """
    # --- 方法 1: 检查 Cgroup v2 CPU 配额 ---
    try:
        cpu_max_path = "/sys/fs/cgroup/cpu.max"
        if os.path.exists(cpu_max_path):
            with open(cpu_max_path, 'r') as f:
                content = f.read().strip()
            parts = content.split()
            if len(parts) == 2 and parts[0] != 'max':
                quota, period = map(int, parts)
                if quota > 0 and period > 0:
                    return max(1, math.floor(quota / period)), "Cgroup v2 Quota"
    except Exception:
        pass # 忽略错误，继续下一种方法

    # --- 方法 2: 检查 Cgroup v1 CPU 配额 ---
    try:
        cfs_period_path = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
        cfs_quota_path = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
        if os.path.exists(cfs_quota_path) and os.path.exists(cfs_period_path):
            with open(cfs_period_path, 'r') as f:
                period = int(f.read().strip())
            with open(cfs_quota_path, 'r') as f:
                quota = int(f.read().strip())
            if quota > 0 and period > 0:
                return max(1, math.floor(quota / period)), "Cgroup v1 Quota"
    except Exception:
        pass

    # --- 方法 3: 检查 Cgroup cpuset (核心绑定) ---
    try:
        # 适用于 cgroup v1 和 v2 的混合路径检查
        cpuset_paths = [
            "/sys/fs/cgroup/cpuset.cpus.effective", # cgroup v2
            "/sys/fs/cgroup/cpuset/cpuset.cpus"     # cgroup v1
        ]
        for path in cpuset_paths:
            if os.path.exists(path):
                with open(path, 'r') as f:
                    cpu_set_str = f.read().strip()
                if cpu_set_str:
                    core_count = parse_cpu_set(cpu_set_str)
                    return core_count, f"Cgroup cpuset ({path})"
    except Exception:
        pass
        
    # --- 方法 4: 使用 'taskset' 命令作为最后的可靠手段 ---
    try:
        # 获取当前进程的 PID
        pid = os.getpid()
        # 运行 taskset 命令
        result = subprocess.run(
            ['taskset', '-c', '-p', str(pid)],
            capture_output=True, text=True, check=True
        )
        # 输出通常是 "pid <PID>'s current affinity list: <LIST>"
        affinity_list_str = result.stdout.split(':')[-1].strip()
        core_count = parse_cpu_set(affinity_list_str)
        return core_count, "taskset Command"
    except (FileNotFoundError, subprocess.CalledProcessError):
        # FileNotFoundError: taskset 命令不存在
        # CalledProcessError: 命令执行失败
        pass
        
    # --- 最终回退 ---
    return os.cpu_count(), "Fallback (可能不准确)"

def get_system_info():
    """收集并打印系统信息。"""
    
    print("="*40, "物理主机信息", "="*40)
    uname = platform.uname()
    print(f"操作系统: {uname.system} {uname.release}")
    print(f"处理器架构: {uname.machine}")
    print(f"物理/逻辑核心数: {psutil.cpu_count(logical=False)} / {psutil.cpu_count(logical=True)}")
    svmem = psutil.virtual_memory()
    print(f"总内存: {svmem.total / (1024**3):.2f} GB")

    print("\n" + "="*35, "您的环境可用资源分析", "="*35)
    
    usable_cores, method = get_effective_cpu_count()

    print(f"检测方法: {method}")

    if method == "Fallback (可能不准确)":
        print(f"⚠️  警告: 未能通过任何方法检测到CPU限制。")
        print(f"   以下数字代表物理主机，很可能不代表您的真实配额！")
    else:
        print("✅ 成功检测到环境的CPU限制。")

    print(f"推荐的可用核心数 (用于并行计算): {usable_cores}")
    
    print("\n" + "="*90)
    print(f"💡 结论: 在需要并行处理时，建议您使用 **{usable_cores}** 个工作进程。")
    print("="*90)

if __name__ == "__main__":
    get_system_info()
