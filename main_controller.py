#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
BTC 自动化挖矿总控制器 (V8 - 智能 VRAM 恢复版)

该脚本整合了 API通信、CPU(KeyHunt)挖矿 和 GPU(BitCrack)挖矿三大功能，实现全自动、高容错的工作流程。

新特性:
- [V8] 智能 VRAM 恢复系统：
    - 在分配 GPU 任务前主动监测剩余显存。
    - 当显存低于阈值时，自动触发一个分级恢复流程：
        1. 强制杀死残留进程 (等同 kill -9)。
        2. 若无效，则尝试重置 GPU (nvidia-smi --gpu-reset)。
        3. 若仍然无效，则进入“冷却期”，暂停 GPU 任务并持续监测，直到显存恢复。
- [V7] 修复与服务器的 JobKey 集成：客户端现在会正确接收、处理并提交 JobKey。
- [V7] 增加任务重试次数显示。
- [V6] 智能范围转换、健壮的显存清理（通过子进程）、增强诊断日志。
- [V5] 改进了GPU检测逻辑，即使自动参数调整失败，也会回退到使用安全的默认参数。
- 引入智能错误处理机制，区分“瞬时错误”和“致命错误”。
- 对任务执行失败引入重试计数器，达到上限或遇到致命错误将自动禁用该计算单元(CPU/GPU)。
- 对API工作获取失败，采取无限延迟重试策略。
- 完全并行：CPU和GPU同时处理不同的工作单元。
"""

import subprocess
import os
import threading
import multiprocessing # <-- [V6] 引入 multiprocessing
import sys
import atexit
import re
import shlex
import psutil
import time
import shutil
import requests
import uuid
import json
import logging 
from queue import Queue, Empty 

# ==============================================================================
# --- 1. 全局配置 (请根据您的环境修改) ---
# ==============================================================================

# --- API 服务器配置 ---
BASE_URL = "https://cc2010.serv00.net/" # 【配置】请根据您的服务器地址修改此URL

# --- 挖矿程序路径配置 ---
KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'    # 【配置】KeyHunt 程序的可执行文件路径
BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack' # 【配置】cuBitCrack 程序的可执行文件路径

# --- 工作目录配置 ---
BASE_WORK_DIR = '/tmp/btc_controller_work'

# --- 容错策略配置 ---
# 任务执行失败的最大连续重试次数
MAX_CONSECUTIVE_ERRORS = 3
# API 请求失败或服务器无工作时的重试延迟（秒）
API_RETRY_DELAY = 60 

# --- [V8 新增] VRAM 恢复策略配置 ---
# 要监控和管理的 GPU ID
GPU_ID_TO_MONITOR = 0
# 当可用 VRAM 百分比低于此值时，触发清理程序 (%)
VRAM_CLEANUP_THRESHOLD_PERCENT = 20.0
# 当所有恢复手段都失败后，GPU 工作单元的冷却时间（秒）
VRAM_COOLDOWN_PERIOD = 300 # 5分钟

# ==============================================================================
# --- 2. 全局常量与状态 (通常无需修改) ---
# ==============================================================================

# --- API 端点 ---
WORK_URL = f"{BASE_URL}/btc/work"
SUBMIT_URL = f"{BASE_URL}/btc/submit"
STATUS_URL = f"{BASE_URL}/btc/status"

# --- 全局进程列表 ---
processes_to_cleanup = []

# --- 正则表达式 ---
KEYHUNT_PRIV_KEY_RE = re.compile(r'(?:Private key \(hex\)|Hit! Private Key):\s*([0-9a-fA-F]+)')

# --- 模拟浏览器头信息 ---
BROWSER_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36',
    'Content-Type': 'application/json'
}

# ==============================================================================
# --- 3. 核心工具、清理与错误分类函数 ---
# ==============================================================================

def cleanup_all_processes():
    """
    全局清理函数，由 atexit 注册，在脚本退出时自动调用。
    终止在 `processes_to_cleanup` 列表中注册的所有子进程。
    """
    print("\n[CONTROLLER CLEANUP] 检测到程序退出，正在清理所有已注册的子进程...")
    for p_info in list(processes_to_cleanup):
        p = p_info['process']
        if p.poll() is None and psutil.pid_exists(p.pid):
            print(f"  -> 正在终止进程 PID: {p.pid} ({p_info['name']})...")
            try:
                parent = psutil.Process(p.pid)
                for child in parent.children(recursive=True):
                    child.kill()
                parent.kill()
            except psutil.NoSuchProcess:
                pass # Process already terminated
            except Exception as e:
                print(f"  -> 终止 PID: {p.pid} 时发生意外错误: {e}")
    print("[CONTROLLER CLEANUP] 清理完成。")

atexit.register(cleanup_all_processes)

def print_header(title):
    """打印一个格式化的标题。"""
    bar = "=" * 80
    print(f"\n{bar}\n===== {title} =====\n{bar}")

def classify_task_error(returncode, stderr_output):
    """
    错误分类器：分析错误输出，判断是瞬时还是致命错误。
    """
    stderr_lower = stderr_output.lower()
    
    if returncode == 127 or "command not found" in stderr_lower or "no such file" in stderr_lower:
        return 'FATAL', "程序可执行文件未找到或路径错误"
    if "cuda" in stderr_lower and ("error" in stderr_lower or "failed" in stderr_lower):
        if "cuda_error_no_device" in stderr_lower or "no device found" in stderr_lower:
            return 'FATAL', "未检测到NVIDIA GPU或驱动有问题"
        return 'FATAL', f"发生致命CUDA错误，可能是驱动或硬件问题"
    if "out of memory" in stderr_lower:
        return 'FATAL', "GPU显存不足，请降低-b/-p参数或使用显存更大的GPU"

    if "key" in stderr_lower and ("must be greater than" in stderr_lower or "invalid range" in stderr_lower):
        return 'TRANSIENT', "服务器分配的密钥范围无效"
    if "cannot open file" in stderr_lower and ".txt" in stderr_lower:
        return 'TRANSIENT', "无法读取地址文件，可能是临时的文件系统或权限问题"

    return 'TRANSIENT', f"发生未知错误 (返回码: {returncode})，将尝试重试"

# --- [V8 新增] VRAM 管理和恢复函数 ---

def get_gpu_vram_status(gpu_id):
    """查询指定GPU的VRAM状态，返回 (总大小 MiB, 剩余大小 MiB)。"""
    try:
        command = [
            'nvidia-smi', f'--id={gpu_id}',
            '--query-gpu=memory.total,memory.free',
            '--format=csv,noheader,nounits'
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=5)
        total_mem_str, free_mem_str = result.stdout.strip().split(', ')
        return int(total_mem_str), int(free_mem_str)
    except (FileNotFoundError, subprocess.CalledProcessError, ValueError, IndexError) as e:
        print(f"⚠️ [VRAM] 查询GPU {gpu_id} 显存失败: {e}")
        return None, None

def attempt_gpu_reset(gpu_id):
    """尝试通过 nvidia-smi 重置GPU。需要 sudo 权限。"""
    print(f"  -> [VRAM RECOVERY] 正在尝试重置 GPU {gpu_id} (需要免密sudo权限)...")
    try:
        command = ['sudo', 'nvidia-smi', '--gpu-reset', f'-i', str(gpu_id)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            print(f"  -> ✅ GPU {gpu_id} 重置成功!")
            time.sleep(3) # 等待驱动稳定
            return True
        else:
            print(f"  -> ❌ GPU {gpu_id} 重置失败。原因: {result.stderr.strip()}")
            return False
    except FileNotFoundError:
        print("  -> ❌ 'sudo' 或 'nvidia-smi' 命令未找到，无法重置 GPU。")
        return False
    except Exception as e:
        print(f"  -> ❌ 执行 GPU 重置时发生异常: {e}")
        return False

def force_kill_process_tree(pid):
    """使用 psutil 强制杀死一个进程及其所有子进程（等同 kill -9）。"""
    try:
        parent = psutil.Process(pid)
        children = parent.children(recursive=True)
        # 先杀掉所有子进程
        for child in children:
            print(f"  -> [FORCE KILL] 正在强制终止子进程 PID: {child.pid}...")
            child.kill()
        # 最后杀掉父进程
        print(f"  -> [FORCE KILL] 正在强制终止主进程 PID: {parent.pid}...")
        parent.kill()
    except psutil.NoSuchProcess:
        pass # 进程已不存在
    except Exception as e:
        print(f"  -> [FORCE KILL] 强制清理进程 (PID: {pid}) 时发生错误: {e}")

# ==============================================================================
# --- 4. API 通信模块 (无修改) ---
# ==============================================================================

def get_work_with_retry(session, client_id):
    """[V7 修改] 请求新工作。如果失败（网络/服务器问题），将无限期延迟重试。"""
    print(f"\n[*] 客户端 '{client_id}' 正在向服务器请求新的工作...")
    while True: 
        try:
            response = session.post(WORK_URL, json={'client_id': client_id}, timeout=30)
            if response.status_code == 200:
                work_data = response.json()
                if work_data.get('address') and work_data.get('range') and work_data.get('job_key'):
                    retries = work_data.get('retries', 0)
                    print(f"[+] 成功获取工作! 地址: {work_data['address']}, 范围: {work_data['range']['start']} - {work_data['range']['end']}")
                    print(f"  -> JobKey: {work_data['job_key']}, 重试次数: {retries}")
                    return work_data
                else:
                    print(f"[!] 获取工作成功(200)，但响应格式不正确或缺少job_key: {response.text}。将在 {API_RETRY_DELAY} 秒后重试...")
            elif response.status_code == 503:
                error_message = response.json().get("error", "未知503错误")
                print(f"[!] 服务器当前无工作可分发 (原因: {error_message})。将在 {API_RETRY_DELAY} 秒后重试...")
            else:
                print(f"[!] 获取工作时遇到意外的HTTP状态码: {response.status_code}, 响应: {response.text}。将在 {API_RETRY_DELAY} 秒后重试...")
        except requests.exceptions.RequestException as e:
            print(f"[!] 请求工作时发生网络错误: {e}。将在 {API_RETRY_DELAY} 秒后重试...")
        time.sleep(API_RETRY_DELAY)

def submit_result(session, work_unit, found, private_key=None):
    """[V7 修复] 向服务器提交工作结果。"""
    address = work_unit.get('address')
    job_key = work_unit.get('job_key')
    payload = {'address': address, 'found': found, 'job_key': job_key}
    if found:
        print(f"[*] 准备向服务器提交为地址 {address} 找到的私钥 (JobKey: {job_key})...")
        payload['private_key'] = private_key
    else:
        print(f"[*] 准备向服务器报告地址 {address} 的范围已搜索完毕 (未找到) (JobKey: {job_key})...")
    try:
        response = session.post(SUBMIT_URL, json=payload, headers=BROWSER_HEADERS, timeout=30)
        if response.status_code == 200:
            print("[+] 结果提交成功!")
            return True
        else:
            print(f"[!] 提交失败! 状态码: {response.status_code}, 响应: {response.text}")
            return False
    except requests.exceptions.RequestException as e:
        print(f"[!] 提交结果时发生网络错误: {e}")
        return False

# ==============================================================================
# --- 5. 硬件检测与挖矿任务执行模块 (少量修改) ---
# ==============================================================================

def heavy_calculation(n):
    """
    一个简单的计算密集型任务，用于消耗CPU时间。
    它的作用是模拟真实的工作负载。
    """
    return sum(i * i for i in range(n))

def _test_cpu_performance(max_cores_to_test=16, calculation_intensity=200000, num_tasks_multiplier=4):
    """
    [V7 新增] 通过运行一个计算密集型基准测试来探测最佳的CPU线程数。
    
    返回性能最佳时的核心数。如果测试失败，则返回 None。
    """
    print("   → 开始CPU性能基准测试以确定最佳线程数...")
    
    try:
        # 1. 使用标准库获取CPU逻辑核心数
        logical_cores = os.cpu_count()
        if not logical_cores:
            print("   ⚠️ 无法自动检测CPU核心数。")
            return None
    except NotImplementedError:
        print("   ⚠️ os.cpu_count() 在此系统上不受支持。")
        return None

    # 限制测试的核心数，避免在拥有超多核心的服务器上花费过长时间
    cores_to_test = min(logical_cores, max_cores_to_test)
    if cores_to_test <= 0:
        return 1 # 如果检测结果异常，安全回退到1

    print(f"   → 检测到 {logical_cores} 个逻辑核心。将测试 1 到 {cores_to_test} 个核心的性能。")

    # 2. 准备一个任务列表。任务总工作量是固定的，以确保比较的公平性。
    # 任务数量应该是核心数的几倍，以确保所有核心都能被充分利用。
    num_tasks = cores_to_test * num_tasks_multiplier
    data = [calculation_intensity] * num_tasks
    
    results = []

    # 3. 循环测试不同数量的进程
    for i in range(1, cores_to_test + 1):
        start_time = time.perf_counter()
        try:
            # 使用 multiprocessing.Pool 创建一个拥有 i 个进程的进程池来并行执行任务
            with multiprocessing.Pool(processes=i) as pool:
                pool.map(heavy_calculation, data)
        except Exception as e:
            # 在某些受限环境（如特定的Docker容器）中，创建进程可能会失败
            print(f"\n   ⚠️ 在测试 {i} 个核心时出错: {e}")
            if i == 1: return None # 如果连单进程都失败，说明多进程模块完全不可用
            break # 如果在多于1个进程时失败，则停止测试

        end_time = time.perf_counter()
        execution_time = end_time - start_time
        
        # 使用更美观的方式在同一行更新进度
        progress_bar = '█' * i + ' ' * (cores_to_test - i)
        sys.stdout.write(f"\r   → 测试中 [{progress_bar}] {i}/{cores_to_test} 核心... | 用时: {execution_time:.4f}s")
        sys.stdout.flush()
        
        results.append({'cores': i, 'time': execution_time})
        
        # 启发式停止：如果增加核心后性能反而显著变差，说明已达到物理核心瓶颈，可以提前停止
        if i > 4 and len(results) > 1:
            # 如果当前时间比上一个结果差15%以上，则停止
            if execution_time > results[-2]['time'] * 1.15:
                print("\n   → 性能出现下降，提前停止测试以节省时间。")
                break

    print() # 测试结束后换行

    if not results:
        print("   ⚠️ 基准测试未能产生任何结果。")
        return None

    # 4. 分析结果，找到用时最短（性能最好）的配置
    fastest_run = min(results, key=lambda x: x['time'])
    recommended_cores = fastest_run['cores']
    
    print(f"   → 测试完成。最快的结果是使用 {recommended_cores} 个核心 (用时 {fastest_run['time']:.4f}s)。")

    return recommended_cores


# --- CPU 任务执行函数 (无修改) ---
def setup_task_logger(name, log_file):
    logger = logging.getLogger(name)
    if logger.hasHandlers(): logger.handlers.clear()
    logger.setLevel(logging.DEBUG)
    formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    fh = logging.FileHandler(log_file, encoding='utf-8')
    fh.setFormatter(formatter)
    logger.addHandler(fh)
    return logger

def reader_thread(pipe, queue):
    try:
        with pipe:
            for line in iter(pipe.readline, ''): queue.put(line)
    except Exception: pass

def run_cpu_task(work_unit, num_threads, result_container):
    address, start_key_dec, end_key_dec = work_unit['address'], work_unit['range']['start'], work_unit['range']['end']
    task_id = f"kh_{address[:10]}_{uuid.uuid4().hex[:6]}"
    task_work_dir = os.path.join(BASE_WORK_DIR, task_id)
    os.makedirs(task_work_dir, exist_ok=True)
    log_file_path = os.path.join(task_work_dir, 'task_run.log')
    logger = setup_task_logger(task_id, log_file_path)
    logger.info(f"===== CPU 任务启动: {task_id} =====")
    logger.info(f"目标地址: {address}")
    logger.info(f"JobKey: {work_unit.get('job_key')}, 重试次数: {work_unit.get('retries')}")
    print(f"[CPU-WORKER] 开始处理地址: {address[:12]}... 日志: {log_file_path}")
    try:
        start_key_int, end_key_int = int(start_key_dec), int(end_key_dec)
        start_key_hex, end_key_hex = hex(start_key_int)[2:], hex(end_key_int)[2:]
        logger.info(f"API 范围 (10进制): {start_key_dec} - {end_key_dec}")
        logger.info(f"程序范围 (16进制): {start_key_hex} - {end_key_hex}")
        keys_to_search = end_key_int - start_key_int + 1
        if keys_to_search <= 0: raise ValueError("密钥范围无效")
        n_value_hex = hex((keys_to_search + 1023) // 1024 * 1024)
    except (ValueError, TypeError) as e:
        msg = f"API返回的范围值或计算-n参数时无效: {e}"
        logger.error(msg)
        result_container['result'] = {'error': True, 'error_type': 'TRANSIENT', 'error_message': msg}
        return
    kh_address_file = os.path.join(task_work_dir, 'target_address.txt')
    with open(kh_address_file, 'w') as f: f.write(address)
    command = [KEYHUNT_PATH, '-m', 'address', '-f', kh_address_file, '-l', 'compress', '-t', str(num_threads), '-r', f'{start_key_hex}:{end_key_hex}', '-n', n_value_hex]
    command_str = shlex.join(command)
    logger.info(f"执行命令: {command_str}")
    print(f"  -> 执行命令: {command_str}")
    process, process_info = None, None
    final_result = {'found': False, 'error': False}
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='ignore')
        process_info = {'process': process, 'name': 'KeyHunt'}
        processes_to_cleanup.append(process_info)
        logger.info(f"KeyHunt (PID: {process.pid}) 已启动...")
        print(f"[CPU-WORKER] KeyHunt (PID: {process.pid}) 已启动...")
        stdout_q, stderr_q = Queue(), Queue()
        threading.Thread(target=reader_thread, args=(process.stdout, stdout_q), daemon=True).start()
        threading.Thread(target=reader_thread, args=(process.stderr, stderr_q), daemon=True).start()
        all_stdout_lines = []
        while process.poll() is None:
            try:
                line = stdout_q.get(timeout=1).strip()
                logger.debug(f"[STDOUT] {line}")
                all_stdout_lines.append(line)
                match = KEYHUNT_PRIV_KEY_RE.search(line)
                if match:
                    found_key = match.group(1).lower()
                    msg = f"实时捕获到密钥: {found_key}"
                    logger.info(f"🔔🔔🔔 {msg} 🔔🔔🔔")
                    print(f"\n🔔🔔🔔 [CPU-WORKER] {msg}！🔔🔔🔔")
                    final_result = {'found': True, 'private_key': found_key, 'error': False}
                    process.terminate()
                    break
            except Empty: pass
            while not stderr_q.empty(): logger.warning(f"[STDERR] {stderr_q.get_nowait().strip()}")
        returncode = process.wait()
        logger.info(f"KeyHunt 进程已退出，返回码: {returncode}")
        stderr_output = "".join(list(stderr_q.queue))
        if stderr_output: logger.warning(f"最终捕获的完整 STDERR:\n{stderr_output}")
        if final_result.get('found'):
            logger.info("任务因找到密钥而成功结束。")
        elif returncode != 0:
            final_result['error'] = True
            final_result['error_type'], final_result['error_message'] = classify_task_error(returncode, stderr_output)
            logger.error(f"任务失败! 类型: {final_result['error_type']}, 原因: {final_result['error_message']}")
        else:
            full_stdout = "\n".join(all_stdout_lines)
            if "0 values were loaded" in full_stdout or "Ommiting invalid line" in full_stdout:
                final_result = {'error': True, 'error_type': 'FATAL', 'error_message': "KeyHunt报告加载了0个地址，地址格式很可能无效。"}
                logger.error(f"检测到伪成功退出! {final_result['error_message']}")
            else:
                logger.info("范围搜索正常完成但未找到密钥。")
    except FileNotFoundError:
        final_result = {'error': True, 'error_type': 'FATAL', 'error_message': f"程序文件未找到: {KEYHUNT_PATH}"}
    except Exception as e:
        final_result = {'error': True, 'error_type': 'TRANSIENT', 'error_message': f"执行时发生Python异常: {e}"}
    finally:
        if process and process_info in processes_to_cleanup: processes_to_cleanup.remove(process_info)
        logger.info(f"===== 任务结束: {task_id} =====\n")
        for handler in logger.handlers:
            handler.close()
            logger.removeHandler(handler)
        result_container['result'] = final_result

# --- GPU 任务执行函数 (少量修改，增加强制清理) ---
def run_gpu_task(work_unit, gpu_params, result_container):
    """[V8 修复] 在 finally 块中增加强制进程树清理，以解决显存无法完全释放的问题。"""
    address, start_key_dec, end_key_dec = work_unit['address'], work_unit['range']['start'], work_unit['range']['end']
    print(f"[GPU-WORKER] 开始处理地址: {address[:12]}...")
    try:
        start_key_hex, end_key_hex = hex(int(start_key_dec))[2:], hex(int(end_key_dec))[2:]
        keyspace_hex = f'{start_key_hex}:{end_key_hex}'
        print(f"  -> API 范围 (10进制): {start_key_dec} - {end_key_dec}")
        print(f"  -> 程序范围 (16进制): {keyspace_hex}")
    except (ValueError, TypeError):
        msg = f"API返回的范围值无效: start={start_key_dec}, end={end_key_dec}"
        result_container['result'] = {'error': True, 'error_type': 'TRANSIENT', 'error_message': msg}
        return
    task_work_dir = os.path.join(BASE_WORK_DIR, f"bc_{address[:10]}_{uuid.uuid4().hex[:6]}")
    os.makedirs(task_work_dir, exist_ok=True)
    found_file_path = os.path.join(task_work_dir, 'found.txt')
    log_file_path = os.path.join(task_work_dir, 'bitcrack_output.log')
    command = [BITCRACK_PATH, '-b', str(gpu_params['blocks']), '-t', str(gpu_params['threads']), '-p', str(gpu_params['points']), '--keyspace', keyspace_hex, '-o', found_file_path, '--continue', os.path.join(task_work_dir, 'progress.dat'), address]
    print(f"  -> 执行命令: {shlex.join(command)}")
    process, process_info, pid_to_kill = None, None, None
    final_result = {'found': False, 'error': False}
    try:
        with open(log_file_path, 'w') as log_file:
            log_file.write(f"Command: {shlex.join(command)}\n---\n")
            log_file.flush()
            process = subprocess.Popen(command, stdout=log_file, stderr=subprocess.STDOUT)
            pid_to_kill = process.pid
            process_info = {'process': process, 'name': 'BitCrack'}
            processes_to_cleanup.append(process_info)
            print(f"[GPU-WORKER] BitCrack (PID: {pid_to_kill}) 已启动...")
            returncode = process.wait()
        print(f"\n[GPU-WORKER] BitCrack 进程 (PID: {pid_to_kill}) 已退出，返回码: {returncode}")
        if returncode != 0:
            with open(log_file_path, 'r', errors='ignore') as f: error_log_content = f.read()
            final_result['error'] = True
            final_result['error_type'], final_result['error_message'] = classify_task_error(returncode, error_log_content)
            print(f"⚠️ [GPU-WORKER] 任务失败! 类型: {final_result['error_type']}, 原因: {final_result['error_message']}")
        if os.path.exists(found_file_path) and os.path.getsize(found_file_path) > 0:
            with open(found_file_path, 'r') as f: line = f.readline().strip()
            if line:
                parts = line.split()
                found_key = next((p.lower() for p in parts if len(p) == 64 and all(c in '0123456789abcdefABCDEF' for c in p)), None)
                if found_key:
                    print(f"\n🎉🎉🎉 [GPU-WORKER] 在文件中找到密钥: {found_key}！🎉🎉🎉")
                    final_result = {'found': True, 'private_key': found_key, 'error': False}
                else:
                    final_result = {'error': True, 'error_type': 'TRANSIENT', 'error_message': f"无法解析私钥: '{line}'"}
    except FileNotFoundError:
        final_result = {'error': True, 'error_type': 'FATAL', 'error_message': f"程序文件未找到: {BITCRACK_PATH}"}
    except Exception as e:
        final_result = {'error': True, 'error_type': 'TRANSIENT', 'error_message': f"执行时发生Python异常: {e}"}
    finally:
        if pid_to_kill:
            force_kill_process_tree(pid_to_kill)
        if process and process_info in processes_to_cleanup:
            processes_to_cleanup.remove(process_info)
        print(f"[GPU-WORKER] 任务清理完成。工作目录保留于: {task_work_dir}")
        result_container['result'] = final_result


# ==============================================================================
# --- 6. 主控制器逻辑 (V8 重大修改) ---
# ==============================================================================

def main():
    """[V8 修改] 主控制器，增加基于VRAM的智能恢复逻辑。"""
    client_id = f"btc-controller-{uuid.uuid4().hex[:8]}"
    print(f"控制器启动 (V8 智能 VRAM 恢复版)，客户端 ID: {client_id}")
    os.makedirs(BASE_WORK_DIR, exist_ok=True)
    
    hardware = detect_hardware()
    session = requests.Session()
    session.headers.update(BROWSER_HEADERS)

    manager = multiprocessing.Manager()
    task_slots = {}
    if hardware['has_gpu']:
        task_slots['GPU'] = {
            'worker': None, 'work': None, 'result_container': None, 
            'status': 'ENABLED', # 新状态机: ENABLED, DISABLED_FATAL, DISABLED_VRAM_COOLDOWN
            'consecutive_errors': 0,
            'cooldown_until': 0 # VRAM 冷却计时器
        }
    task_slots['CPU'] = {'worker': None, 'work': None, 'result_container': None, 'status': 'ENABLED', 'consecutive_errors': 0}

    try:
        while any(slot['status'] != 'DISABLED_FATAL' for slot in task_slots.values()):
            for unit_name, slot in task_slots.items():
                if slot['status'] == 'DISABLED_FATAL':
                    continue

                # 步骤 1: 检查并处理已完成的任务 (逻辑不变)
                if slot['worker'] and not slot['worker'].is_alive():
                    print_header(f"{unit_name} 任务完成")
                    result = slot['result_container'].get('result', {'error': True, 'error_type': 'TRANSIENT', 'error_message': '结果容器为空'})

                    if not result.get('error'):
                        print(f"✅ {unit_name} 任务成功。重置连续错误计数。")
                        slot['consecutive_errors'] = 0 
                        submit_result(session, slot['work'], result.get('found', False), result.get('private_key'))
                    else:
                        slot['consecutive_errors'] += 1
                        error_type = result.get('error_type', 'TRANSIENT')
                        print(f"🔴 {unit_name} 任务连续失败次数: {slot['consecutive_errors']}/{MAX_CONSECUTIVE_ERRORS}")
                        if error_type == 'FATAL' or slot['consecutive_errors'] >= MAX_CONSECUTIVE_ERRORS:
                            slot['status'] = 'DISABLED_FATAL'
                            reason = '致命错误' if error_type == 'FATAL' else '达到最大重试次数'
                            print(f"🚫🚫🚫 {unit_name} 工作单元已被永久禁用! 原因: {reason} 🚫🚫🚫")
                    
                    slot['worker'], slot['work'] = None, None

                # 步骤 2: [V8 新增] 处理 GPU VRAM 冷却状态
                if unit_name == 'GPU' and slot['status'] == 'DISABLED_VRAM_COOLDOWN':
                    if time.time() < slot['cooldown_until']:
                        continue # 冷却中，跳过此单元
                    
                    print_header("GPU 冷却期结束，重新检查 VRAM")
                    total_vram, free_vram = get_gpu_vram_status(GPU_ID_TO_MONITOR)
                    if total_vram and (free_vram / total_vram) * 100 > VRAM_CLEANUP_THRESHOLD_PERCENT:
                        print(f"✅ VRAM 已恢复 ({free_vram}/{total_vram} MiB)。GPU 工作单元重新启用！")
                        slot['status'] = 'ENABLED'
                    else:
                        print(f"⚠️ VRAM 仍未恢复 ({free_vram}/{total_vram} MiB)。再次进入冷却期...")
                        slot['cooldown_until'] = time.time() + VRAM_COOLDOWN_PERIOD

                # 步骤 3: 为空闲且启用的任务槽分配新任务
                if not slot['worker'] and slot['status'] == 'ENABLED':
                    
                    # 步骤 3.1: [V8 新增] GPU 任务分配前的 VRAM 健康检查
                    if unit_name == 'GPU':
                        print_header("GPU VRAM 健康检查")
                        total_vram, free_vram = get_gpu_vram_status(GPU_ID_TO_MONITOR)
                        
                        if total_vram is None: # nvidia-smi 查询失败
                             print("无法检查 VRAM，暂时跳过 GPU 任务分配。")
                             time.sleep(API_RETRY_DELAY)
                             continue

                        free_percent = (free_vram / total_vram) * 100
                        print(f"  -> VRAM 状态: {free_vram} / {total_vram} MiB ({free_percent:.1f}%) 可用。")

                        if free_percent < VRAM_CLEANUP_THRESHOLD_PERCENT:
                            print_header(f"警告: VRAM 低于阈值 ({VRAM_CLEANUP_THRESHOLD_PERCENT}%)！启动恢复程序...")
                            
                            # 第一级恢复: 强制杀死所有已知挖矿进程 (预防性措施)
                            # (实际上 run_gpu_task 的 finally 已做，这里是双保险)
                            print("  -> [VRAM RECOVERY] 步骤 1: 检查并清理残留进程...")
                            for p in psutil.process_iter(['name', 'pid']):
                                if 'bitcrack' in p.info['name'].lower():
                                    print(f"    -> 发现残留进程 {p.info['name']} (PID: {p.info['pid']})，正在强制清理...")
                                    force_kill_process_tree(p.info['pid'])
                            
                            time.sleep(2)
                            _, free_vram_after_kill = get_gpu_vram_status(GPU_ID_TO_MONITOR)

                            if free_vram_after_kill and (free_vram_after_kill / total_vram) * 100 > VRAM_CLEANUP_THRESHOLD_PERCENT:
                                print("  -> ✅ 强制清理后 VRAM 已恢复。")
                            else:
                                print("  -> ⚠️ 强制清理无效，进入第二级恢复...")
                                # 第二级恢复: 重置 GPU
                                if attempt_gpu_reset(GPU_ID_TO_MONITOR):
                                    _, free_vram_after_reset = get_gpu_vram_status(GPU_ID_TO_MONITOR)
                                    if free_vram_after_reset and (free_vram_after_reset / total_vram) * 100 > VRAM_CLEANUP_THRESHOLD_PERCENT:
                                        print("  -> ✅ GPU 重置后 VRAM 已恢复。")
                                    else:
                                        print("  -> ❌ GPU 重置后 VRAM 仍未恢复。")
                                        # 第三级恢复: 进入冷却期
                                        print(f"  -> 所有恢复手段失败！GPU 将进入 {VRAM_COOLDOWN_PERIOD} 秒的冷却期。")
                                        slot['status'] = 'DISABLED_VRAM_COOLDOWN'
                                        slot['cooldown_until'] = time.time() + VRAM_COOLDOWN_PERIOD
                                else:
                                    print(f"  -> GPU 重置失败或不可用。进入 {VRAM_COOLDOWN_PERIOD} 秒的冷却期。")
                                    slot['status'] = 'DISABLED_VRAM_COOLDOWN'
                                    slot['cooldown_until'] = time.time() + VRAM_COOLDOWN_PERIOD
                            
                            continue # 无论恢复结果如何，本轮循环都不再为GPU分配任务

                    # 步骤 3.2: 获取并启动任务 (原始逻辑)
                    print_header(f"为 {unit_name} 请求新任务")
                    work_unit = get_work_with_retry(session, f"{client_id}-{unit_name}")
                    if work_unit:
                        slot['work'] = work_unit
                        if unit_name == 'GPU':
                            slot['result_container'] = manager.dict()
                            worker = multiprocessing.Process(target=run_gpu_task, args=(work_unit, hardware['gpu_params'], slot['result_container']))
                        else: # CPU
                            slot['result_container'] = {}
                            worker = threading.Thread(target=run_cpu_task, args=(work_unit, hardware['cpu_threads'], slot['result_container']))
                        
                        slot['worker'] = worker
                        worker.start()
            
            time.sleep(5) 
        
        print("\n" + "="*80 + "\n所有计算单元均已被永久禁用，控制器将退出。\n" + "="*80)

    except KeyboardInterrupt:
        print("\n[CONTROLLER] 检测到用户中断 (Ctrl+C)。")
    except Exception as e:
        print(f"\n[CONTROLLER FATAL ERROR] 主循环发生无法恢复的错误: {e}")
        import traceback; traceback.print_exc()
    finally:
        print("[CONTROLLER] 脚本正在关闭...")

if __name__ == '__main__':
    if not os.path.exists(KEYHUNT_PATH) or not shutil.which(KEYHUNT_PATH):
        print(f"!! 启动错误: KeyHunt 程序未找到或不可执行: '{KEYHUNT_PATH}' !!")
        sys.exit(1)
    try:
        subprocess.run(['nvidia-smi'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not os.path.exists(BITCRACK_PATH) or not shutil.which(BITCRACK_PATH):
            print(f"!! 启动错误: 检测到 NVIDIA GPU，但 BitCrack 程序未找到或不可执行: '{BITCRACK_PATH}' !!")
            sys.exit(1)
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass
    main()
