#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import re
import csv
import math
import json
import time
import shutil
import platform
import subprocess
import multiprocessing as mp

# ------------------ 通用工具 ------------------
def run_cmd(cmd, timeout=2.0):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout, check=False)
        if p.returncode == 0:
            return p.stdout.strip()
        return None
    except Exception:
        return None

def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip()
    except Exception:
        return None

def human_bytes(n):
    if n is None:
        return "N/A"
    units = ["B","KB","MB","GB","TB","PB"]
    v = float(n)
    for u in units:
        if v < 1024.0 or u == units[-1]:
            return f"{v:.2f} {u}" if u != "B" else f"{int(v)} {u}"
        v /= 1024.0

def parse_cpu_list(s):
    # "0-3,8,10-12" -> [0,1,2,3,8,10,11,12]
    if not s:
        return []
    cpus = set()
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            try:
                a, b = int(a), int(b)
                if a <= b:
                    cpus.update(range(a, b + 1))
            except ValueError:
                continue
        else:
            try:
                cpus.add(int(part))
            except ValueError:
                continue
    return sorted(cpus)

# ------------------ cgroup / CPU 有效核数检测 ------------------
def get_cgroup_version_and_mounts():
    v2_mount = None
    v1_mounts = {}
    try:
        with open("/proc/self/mountinfo", "r") as f:
            for line in f:
                parts = line.strip().split(" - ")
                if len(parts) != 2:
                    continue
                left, right = parts
                fstype = right.split()[0]
                mount_point = left.split()[4]
                super_opts = right.split()[2] if len(right.split()) >= 3 else ""
                if fstype == "cgroup2":
                    v2_mount = mount_point
                elif fstype == "cgroup":
                    ctrls = set(super_opts.split(","))
                    if "cpu" in ctrls:
                        v1_mounts["cpu"] = mount_point
                    if "cpuset" in ctrls:
                        v1_mounts["cpuset"] = mount_point
    except Exception:
        pass
    if v2_mount is None and os.path.isdir("/sys/fs/cgroup") and os.path.exists("/sys/fs/cgroup/cgroup.controllers"):
        v2_mount = "/sys/fs/cgroup"
    if "cpu" not in v1_mounts and os.path.isdir("/sys/fs/cgroup/cpu"):
        v1_mounts["cpu"] = "/sys/fs/cgroup/cpu"
    if "cpuset" not in v1_mounts and os.path.isdir("/sys/fs/cgroup/cpuset"):
        v1_mounts["cpuset"] = "/sys/fs/cgroup/cpuset"
    version = 2 if v2_mount else (1 if v1_mounts else 0)
    return version, v2_mount, v1_mounts

def get_proc_cgroup_paths():
    v2_path = None
    v1_paths = {}
    try:
        with open("/proc/self/cgroup", "r") as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                parts = line.split(":")
                if len(parts) != 3:
                    continue
                _, controllers, path = parts
                if controllers == "":
                    v2_path = path or "/"
                else:
                    for c in controllers.split(","):
                        v1_paths[c] = path or "/"
    except Exception:
        pass
    return v2_path, v1_paths

def read_cgroup_quota_cpu_units():
    # 返回 (quota_cpu_units: float or None, detail: str)
    version, v2_mount, v1_mounts = get_cgroup_version_and_mounts()
    v2_path, v1_paths = get_proc_cgroup_paths()

    if version == 2 and v2_mount:
        cgdir = os.path.join(v2_mount, v2_path.lstrip("/")) if v2_path else v2_mount
        txt = read_text(os.path.join(cgdir, "cpu.max"))
        if txt:
            parts = txt.split()
            if len(parts) >= 2:
                quota, period = parts[0], parts[1]
                if quota != "max":
                    try:
                        q = int(quota); p = int(period)
                        if p > 0:
                            return q / p, f"v2 cpu.max={quota} {period} -> {q/p:.2f}"
                    except Exception:
                        pass
                else:
                    return None, f"v2 cpu.max={txt} (unlimited)"
        return None, "v2 cpu.max unavailable"
    elif version == 1:
        cpu_mount = v1_mounts.get("cpu", "/sys/fs/cgroup/cpu")
        cgpath = v1_paths.get("cpu") or v1_paths.get("cpuacct") or "/"
        cgdir = os.path.join(cpu_mount, cgpath.lstrip("/"))
        qtxt = read_text(os.path.join(cgdir, "cpu.cfs_quota_us"))
        ptxt = read_text(os.path.join(cgdir, "cpu.cfs_period_us"))
        try:
            q = int(qtxt) if qtxt is not None else -1
            p = int(ptxt) if ptxt is not None else -1
            if q > 0 and p > 0:
                return q / p, f"v1 quota/period={q}/{p} -> {q/p:.2f}"
            elif q == -1:
                return None, f"v1 quota=unlimited, period={p}"
        except Exception:
            pass
        return None, "v1 quota/period unavailable"
    else:
        return None, "no cgroup detected"

def read_cpuset_allowed_cpus():
    version, v2_mount, v1_mounts = get_cgroup_version_and_mounts()
    v2_path, v1_paths = get_proc_cgroup_paths()
    paths_to_try = []
    if version == 2 and v2_mount:
        base = os.path.join(v2_mount, v2_path.lstrip("/")) if v2_path else v2_mount
        paths_to_try += [os.path.join(base, "cpuset.cpus.effective"),
                         os.path.join(base, "cpuset.cpus")]
    if version == 1 and "cpuset" in v1_mounts:
        base = os.path.join(v1_mounts["cpuset"], (v1_paths.get("cpuset") or "/").lstrip("/"))
        paths_to_try += [os.path.join(base, "cpuset.cpus")]
    paths_to_try += ["/sys/fs/cgroup/cpuset.cpus.effective", "/sys/fs/cgroup/cpuset/cpuset.cpus"]
    content = None
    for p in paths_to_try:
        content = read_text(p)
        if content:
            break
    cpus = parse_cpu_list(content or "")
    return (len(cpus) if cpus else None), (content or "N/A")

def read_affinity_cpus():
    try:
        return len(os.sched_getaffinity(0))
    except Exception:
        return None

def analytical_effective_cpus():
    quota_units, quota_detail = read_cgroup_quota_cpu_units()
    cpuset_count, cpuset_str = read_cpuset_allowed_cpus()
    affinity = read_affinity_cpus()
    cands = [v for v in (quota_units, cpuset_count, affinity) if v]
    effective_units = min(cands) if cands else (affinity or os.cpu_count() or 1)
    effective_int = max(1, int(math.floor(effective_units)))
    detail = {
        "quota_units": quota_units,
        "quota_detail": quota_detail,
        "cpuset_count": cpuset_count,
        "cpuset_str": cpuset_str,
        "affinity_count": affinity,
        "logical_cpu": os.cpu_count() or None,
        "effective_units": effective_units,
        "effective_integer": effective_int,
    }
    return effective_units, effective_int, detail

# 实测探针：并行消耗 CPU，估算 sum(cpu_time)/wall_time ≈ 可用 CPU 单位
def _burn_cpu(duration_sec):
    t_end = time.perf_counter() + duration_sec
    c0 = time.process_time()
    x = 0x12345678
    while time.perf_counter() < t_end:
        x = (x * 1664525 + 1013904223) & 0xFFFFFFFF
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= (x >> 17)
        x ^= (x << 5) & 0xFFFFFFFF
    return time.process_time() - c0

def _burn_worker(duration_sec, q):
    try:
        q.put(_burn_cpu(duration_sec))
    except Exception:
        q.put(0.0)

def empirical_cpu_units(max_procs=64, duration_sec=1.0):
    candidates = [1]
    while candidates[-1] < max_procs:
        nxt = candidates[-1] * 2
        candidates.append(nxt if nxt <= max_procs else max_procs)
        if candidates[-1] == max_procs:
            break
    best_units = 0.0
    best_n = 1
    for n in candidates:
        q = mp.Queue()
        procs = [mp.Process(target=_burn_worker, args=(duration_sec, q)) for _ in range(n)]
        t0 = time.perf_counter()
        for p in procs: p.start()
        cpu_sum = 0.0
        for _ in procs: cpu_sum += q.get()
        for p in procs: p.join()
        elapsed = max(1e-6, time.perf_counter() - t0)
        units = cpu_sum / elapsed
        if units > best_units:
            best_units = units; best_n = n
        # 收敛停止条件：提升 <10%
        if best_units > 0 and (units - best_units) / best_units < 0.10 and n > 1:
            break
    return best_units, best_n

# ------------------ GPU 检测 ------------------
def nvidia_via_smi(timeout=2.0):
    if not shutil.which("nvidia-smi"):
        return []
    out = run_cmd(["nvidia-smi", "--query-gpu=index,pci.bus_id,name,memory.total,driver_version",
                   "--format=csv,noheader,nounits"], timeout=timeout)
    if not out:
        return []
    gpus = []
    try:
        reader = csv.reader(out.splitlines())
        for row in reader:
            if len(row) < 5:
                continue
            idx, bus_id, name, mem_mib, drv = [c.strip() for c in row[:5]]
            try:
                mem_bytes = int(float(mem_mib)) * 1024 * 1024
            except Exception:
                mem_bytes = None
            gpus.append({
                "vendor": "NVIDIA",
                "model": name,
                "bus_id": bus_id,
                "driver": f"nvidia {drv}",
                "vram_bytes": mem_bytes,
                "source": "nvidia-smi"
            })
    except Exception:
        return []
    return gpus

def nvidia_via_proc():
    base = "/proc/driver/nvidia/gpus"
    if not os.path.isdir(base):
        return []
    gpus = []
    for entry in sorted(os.listdir(base)):
        gdir = os.path.join(base, entry)
        info = read_text(os.path.join(gdir, "information")) or ""
        fb = read_text(os.path.join(gdir, "fb_memory_usage")) or read_text(os.path.join(gdir, "mem_info")) or ""
        model = None
        m = re.search(r"Model\s*:\s*(.+)", info)
        if m: model = m.group(1).strip()
        mem_bytes = None
        m2 = re.search(r"Total\s*:\s*(\d+)\s*MiB", fb, re.IGNORECASE)
        if m2:
            try:
                mem_bytes = int(m2.group(1)) * 1024 * 1024
            except Exception:
                pass
        gpus.append({
            "vendor": "NVIDIA",
            "model": model or "NVIDIA GPU",
            "bus_id": entry,  # 形如 0000:65:00.0
            "driver": "nvidia",
            "vram_bytes": mem_bytes,
            "source": "procfs"
        })
    return gpus

def list_drm_cards():
    cards = []
    base = "/sys/class/drm"
    if not os.path.isdir(base):
        return cards
    for name in sorted(os.listdir(base)):
        if not name.startswith("card") or "-" in name:
            continue
        card_dir = os.path.join(base, name)
        dev_link = os.path.join(card_dir, "device")
        if not os.path.islink(dev_link) and not os.path.isdir(dev_link):
            continue
        dev_path = os.path.realpath(dev_link)
        bus_id = dev_path.split("/")[-1]  # 0000:65:00.0
        vendor_id = read_text(os.path.join(dev_path, "vendor")) or ""
        device_id = read_text(os.path.join(dev_path, "device")) or ""
        vendor_id = vendor_id.lower()
        driver = None
        uevent = read_text(os.path.join(dev_path, "uevent")) or ""
        m = re.search(r"DRIVER=(.+)", uevent)
        if m: driver = m.group(1).strip()
        cards.append({
            "card": name,
            "dev_path": dev_path,
            "bus_id": bus_id,
            "vendor_id": vendor_id,
            "device_id": device_id,
            "driver": driver
        })
    return cards

def decode_vendor(vendor_id):
    v = vendor_id.lower()
    if v == "0x10de": return "NVIDIA"
    if v == "0x1002" or v == "0x1022": return "AMD"  # 0x1022 为 AMD（CPU/bridge），但 DRM GPU 多为 0x1002
    if v == "0x8086": return "Intel"
    return vendor_id

def lspci_name_for_bus(bus_id, timeout=2.0):
    if not shutil.which("lspci"):
        return None
    out = run_cmd(["lspci", "-s", bus_id], timeout=timeout)
    if not out:
        return None
    # 示例: "65:00.0 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)"
    # 去掉前缀地址
    try:
        return out.split(":", 1)[1].strip()
    except Exception:
        return out.strip()

def amd_vram_from_sysfs(dev_path):
    # amdgpu 驱动提供以下文件（字节）
    for fn in ["mem_info_vram_total", "mem_info_vis_vram_total"]:
        p = os.path.join(dev_path, fn)
        t = read_text(p)
        if t and t.isdigit():
            try:
                return int(t)
            except Exception:
                pass
    return None

def rocm_smi_parse(timeout=2.0):
    if not shutil.which("rocm-smi"):
        return []
    # 优先 JSON 输出（不同版本格式差异较大）
    out = run_cmd(["rocm-smi", "--showmeminfo", "vram", "--json"], timeout=timeout)
    gpus = []
    if out:
        try:
            data = json.loads(out)
            # 兼容不同层级
            for k, v in (data.items() if isinstance(data, dict) else []):
                # 寻找 "VRAM Total" 或 "Total Memory (B)"
                vram_bytes = None
                model = None
                bus = None
                # rocm-smi 也有 --showid/--showbus，但为简化只解析 meminfo
                for kk, vv in (v.items() if isinstance(v, dict) else []):
                    if isinstance(vv, dict):
                        # 可能是 {"VRAM Total": "16368 MiB", ...}
                        for k2, v2 in vv.items():
                            if "total" in k2.lower():
                                m = re.search(r"(\d+)\s*MiB", str(v2), re.IGNORECASE)
                                if m:
                                    vram_bytes = int(m.group(1)) * 1024 * 1024
                                else:
                                    m2 = re.search(r"(\d+)", str(v2))
                                    if m2 and "B" in str(v2):
                                        vram_bytes = int(m2.group(1))
                gpus.append({
                    "vendor": "AMD",
                    "model": model or "AMD GPU",
                    "bus_id": bus or None,
                    "driver": "amdgpu",
                    "vram_bytes": vram_bytes,
                    "source": "rocm-smi"
                })
            return gpus
        except Exception:
            pass
    # 退回文本解析
    out = run_cmd(["rocm-smi", "--showmeminfo", "vram"], timeout=timeout)
    if not out:
        return []
    total_mib = None
    m = re.findall(r"Total.*?(\d+)\s*MiB", out, re.IGNORECASE)
    if m:
        try:
            total_mib = max(int(x) for x in m)
        except Exception:
            total_mib = None
    g = {
        "vendor": "AMD",
        "model": "AMD GPU",
        "bus_id": None,
        "driver": "amdgpu",
        "vram_bytes": (total_mib * 1024 * 1024) if total_mib else None,
        "source": "rocm-smi"
    }
    return [g]

def detect_gpus(timeout=2.0):
    result = {}

    # 1) NVIDIA 优先通过 nvidia-smi
    for gpu in nvidia_via_smi(timeout=timeout):
        key = ("NVIDIA", gpu.get("bus_id"))
        result[key] = gpu

    # NV fallback: /proc/driver/nvidia
    for gpu in nvidia_via_proc():
        key = ("NVIDIA", gpu.get("bus_id"))
        if key not in result or result[key].get("vram_bytes") is None:
            result[key] = gpu

    # 2) 遍历 DRM 设备，补全 AMD/Intel 等
    for card in list_drm_cards():
        vendor = decode_vendor(card["vendor_id"])
        bus = card["bus_id"]
        key = (vendor, bus)
        if vendor == "AMD":
            vram = amd_vram_from_sysfs(card["dev_path"])
            model = None
            ls = lspci_name_for_bus(bus, timeout=timeout)
            if ls:
                model = ls
            gpu = {
                "vendor": "AMD",
                "model": model or "AMD GPU",
                "bus_id": bus,
                "driver": card.get("driver") or "amdgpu",
                "vram_bytes": vram,
                "source": "sysfs/drm"
            }
            # 若 rocm-smi 有更详细信息也可融合
            if key not in result or (result[key].get("vram_bytes") is None and vram is not None):
                result[key] = gpu
        elif vendor == "Intel":
            model = lspci_name_for_bus(bus, timeout=timeout) or "Intel GPU"
            # 一般为集显，共享内存，无专用 VRAM
            gpu = {
                "vendor": "Intel",
                "model": model,
                "bus_id": bus,
                "driver": card.get("driver") or "i915",
                "vram_bytes": None,
                "source": "sysfs/drm"
            }
            if key not in result:
                result[key] = gpu
        elif vendor == "NVIDIA":
            # 如果没有被 nvidia-smi 捕获到，至少补上基础信息
            if key not in result:
                model = lspci_name_for_bus(bus, timeout=timeout) or "NVIDIA GPU"
                result[key] = {
                    "vendor": "NVIDIA",
                    "model": model,
                    "bus_id": bus,
                    "driver": card.get("driver") or "nvidia",
                    "vram_bytes": None,
                    "source": "sysfs/drm"
                }
        else:
            # 其他厂商/虚拟 GPU
            model = lspci_name_for_bus(bus, timeout=timeout) or vendor
            if key not in result:
                result[key] = {
                    "vendor": vendor,
                    "model": model,
                    "bus_id": bus,
                    "driver": card.get("driver") or None,
                    "vram_bytes": None,
                    "source": "sysfs/drm"
                }

    # 3) 尝试 rocm-smi 补充（如果尚无 AMD 或 VRAM 为空）
    have_amd = any(v == "AMD" for v, _ in result.keys())
    if not have_amd:
        for gpu in rocm_smi_parse(timeout=timeout):
            key = (gpu["vendor"], gpu.get("bus_id"))
            if key not in result or result[key].get("vram_bytes") is None:
                result[key] = gpu

    # 输出列表
    devices = list(result.values())
    # 尝试给没有 bus_id 的设备指定 "unknown-N"
    unknown_idx = 0
    for d in devices:
        if not d.get("bus_id"):
            d["bus_id"] = f"unknown-{unknown_idx}"
            unknown_idx += 1
    # 排序：按 vendor、bus_id
    devices.sort(key=lambda x: (x.get("vendor") or "", x.get("bus_id") or ""))
    return devices

# ------------------ 打印报告 ------------------
def print_cpu_report(run_empirical=True):
    print("===== 系统/CPU 信息 =====")
    print(f"- 操作系统: {platform.platform()}")
    print(f"- Python: {platform.python_version()} ({platform.python_implementation()})")
    print(f"- 架构: {platform.machine()}")
    print(f"- 逻辑 CPU (os.cpu_count): {os.cpu_count()}")
    print("========================\n")

    eff_units, eff_int, detail = analytical_effective_cpus()
    print("----- cgroup/亲和性分析 -----")
    print(f"cgroup 配额换算 CPU 单位: {('%.2f' % detail['quota_units']) if detail['quota_units'] else 'N/A'}  ({detail['quota_detail']})")
    print(f"cpuset 允许的 CPU 数量: {detail['cpuset_count']}  (cpus='{detail['cpuset_str']}')")
    print(f"进程亲和性可用 CPU 数: {detail['affinity_count']}")
    print(f"解析得到的有效 CPU 单位: {('%.2f' % detail['effective_units']) if detail['effective_units'] else 'N/A'}")
    print(f"解析得到的有效 CPU（整数并发）: {detail['effective_integer']}")
    print("----------------------------\n")

    final_units = eff_units
    final_int = eff_int
    if run_empirical:
        print("开始 1 秒实测，用于验证可用 CPU 单位...")
        max_hint = detail["affinity_count"] or detail["cpuset_count"] or (os.cpu_count() or 8)
        max_hint = max(1, min(int(max_hint), 64))
        mp.freeze_support()
        try:
            emp_units, at_n = empirical_cpu_units(max_procs=max_hint, duration_sec=1.0)
            print(f"实测峰值 CPU 单位 ≈ {emp_units:.2f} （在并发={at_n} 时）")
            final_units = min(final_units, emp_units)
            final_int = max(1, int(math.floor(final_units)))
        except Exception as e:
            print(f"实测失败：{e}")

    print("===== 最终 CPU 结论 =====")
    print(f"- 推荐可用 CPU 单位（浮点）: {final_units:.2f}")
    print(f"- 推荐可用 CPU（整数并发）: {final_int}")
    print("========================\n")

def print_gpu_report(timeout_cmd=2.0):
    print("===== GPU 检测 =====")
    gpus = detect_gpus(timeout=timeout_cmd)
    if not gpus:
        print("未检测到 GPU 或驱动不可用。")
        print("====================\n")
        return
    for i, g in enumerate(gpus):
        print(f"[GPU {i}]")
        print(f"- 厂商: {g.get('vendor')}")
        print(f"- 型号: {g.get('model')}")
        print(f"- 总线ID: {g.get('bus_id')}")
        print(f"- 驱动: {g.get('driver')}")
        print(f"- 显存: {human_bytes(g.get('vram_bytes'))}")
        print(f"- 信息来源: {g.get('source')}")
        print("")
    print("====================\n")

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Linux 硬件检测：有效 CPU 数量 + GPU/显存")
    parser.add_argument("--no-empirical", action="store_true", help="跳过 1 秒 CPU 实测探针（仅静态分析）")
    parser.add_argument("--gpu-timeout", type=float, default=2.0, help="外部命令超时（秒），默认 2")
    args = parser.parse_args()

    print_cpu_report(run_empirical=not args.no_empirical)
    print_gpu_report(timeout_cmd=args.gpu_timeout)

if __name__ == "__main__":
    main()
