#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
BTC 自动化挖矿总控制器 (V7 - JobKey 集成修复版)

该脚本整合了 API通信、CPU(KeyHunt)挖矿 和 GPU(BitCrack)挖矿三大功能，实现全自动、高容错的工作流程。

新特性:
- [V7] 修复与服务器的 JobKey 集成：客户端现在会正确接收、处理并提交 JobKey，解决了服务器端 assigned_work 和 recycled_work 列表异常增长的问题。
- [V7] 增加任务重试次数显示：获取新任务时，会显示其已被重试的次数，便于问题诊断。
- [V6] 智能范围转换：自动将API返回的十进制范围转换为挖矿程序所需的十六进制格式。
- [V6] 健壮的显存清理：通过将GPU任务置于独立的子进程中运行，确保任务结束后操作系统能彻底回收CUDA上下文和显存，解决显存泄露问题。
- [V6] 增强诊断日志：启动任务前会打印完整的命令行和范围转换信息，便于调试。
- [V5] 改进了GPU检测逻辑，即使自动参数调整失败，只要检测到GPU存在，就会回退到使用安全的默认参数，而不是禁用GPU。
- 引入智能错误处理机制，区分“瞬时错误”和“致命错误”。
- 对任务执行失败引入重试计数器，达到上限或遇到致命错误将自动禁用该计算单元(CPU/GPU)。
- 对API工作获取失败，采取无限延迟重试策略，以应对网络中断或服务器暂时不可用。
- 完全并行：在有兼容GPU的系统上，CPU和GPU将同时处理不同的工作单元，最大化效率。
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
import logging # <-- 新增
from queue import Queue, Empty # <-- 新增

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
        if p.poll() is None and p.is_alive(): # 检查进程是否仍在运行
            print(f"  -> 正在终止进程 PID: {p.pid} ({p_info['name']})...")
            try:
                # 尝试优雅终止
                p.terminate()
                p.join(timeout=3) # 对于进程和线程，join是更合适的等待方式
            except (psutil.NoSuchProcess, subprocess.TimeoutExpired):
                # 如果优雅终止失败或超时，则强制终止
                if p.is_alive():
                    try:
                        p.kill()
                        p.join(timeout=2)
                    except Exception as e:
                        print(f"  -> 强制终止 PID: {p.pid} 时出错: {e}")
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
    
    # --- 致命错误 (FATAL) ---
    # 这类错误重试没有意义，应该立即禁用该工作单元
    if returncode == 127 or "command not found" in stderr_lower or "no such file" in stderr_lower:
        return 'FATAL', "程序可执行文件未找到或路径错误"
    if "cuda" in stderr_lower and ("error" in stderr_lower or "failed" in stderr_lower):
        if "cuda_error_no_device" in stderr_lower or "no device found" in stderr_lower:
            return 'FATAL', "未检测到NVIDIA GPU或驱动有问题"
        return 'FATAL', f"发生致命CUDA错误，可能是驱动或硬件问题"
    if "out of memory" in stderr_lower:
        return 'FATAL', "GPU显存不足，请降低-b/-p参数或使用显存更大的GPU"

    # --- 瞬时错误 (TRANSIENT) ---
    # 这类错误更换工作单元后可能恢复，值得重试
    if "key" in stderr_lower and ("must be greater than" in stderr_lower or "invalid range" in stderr_lower):
        return 'TRANSIENT', "服务器分配的密钥范围无效"
    if "cannot open file" in stderr_lower and ".txt" in stderr_lower:
        return 'TRANSIENT', "无法读取地址文件，可能是临时的文件系统或权限问题"

    # --- 未知错误，默认为瞬时 ---
    # 给予重试机会，如果持续发生，会被重试计数器捕获
    return 'TRANSIENT', f"发生未知错误 (返回码: {returncode})，将尝试重试"

# ==============================================================================
# --- 4. API 通信模块 ---
# ==============================================================================

def get_work_with_retry(session, client_id):
    """
    [V7 修改] 请求新工作。如果失败（网络/服务器问题），将无限期延迟重试。
    现在会解析并显示任务的重试次数。
    """
    print(f"\n[*] 客户端 '{client_id}' 正在向服务器请求新的工作...")
    while True: # 无限重试循环，直到成功
        try:
            response = session.post(WORK_URL, json={'client_id': client_id}, timeout=30)

            if response.status_code == 200:
                work_data = response.json()
                if work_data.get('address') and work_data.get('range') and work_data.get('job_key'):
                    # 【V7 新增】打印更详细的任务信息
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
    """
    [V7 修复] 向服务器提交工作结果。
    现在会包含 job_key，这是正确处理任务完成状态的关键。
    """
    address = work_unit.get('address')
    job_key = work_unit.get('job_key')

    # 【V7 修复】在提交时必须包含 job_key
    payload = {
        'address': address, 
        'found': found,
        'job_key': job_key 
    }
    
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
# --- 5. 硬件检测与挖矿任务执行模块 (V6 修改) ---
# ==============================================================================

def detect_hardware():
    """
    [V5 修改] 统一硬件检测函数。
    首先尝试自动调优，如果失败则回退到基本检测和默认参数。
    """
    print_header("硬件自检")
    hardware_config = {'has_gpu': False, 'gpu_params': None, 'cpu_threads': 1}
    default_gpu_params = {'blocks': 288, 'threads': 256, 'points': 1024}

    # --- GPU 检测与调优 ---
    try:
        # 步骤 1: 尝试获取所有信息以进行自动调优
        cmd_tune = ['nvidia-smi', '--query-gpu=name,multiprocessor_count', '--format=csv,noheader,nounits']
        result = subprocess.run(cmd_tune, capture_output=True, text=True, check=True, timeout=5)
        gpu_name, sm_count_str = result.stdout.strip().split(', ')

        if not sm_count_str.isdigit():
            raise ValueError(f"从 nvidia-smi 获得的 SM Count 不是有效数字: '{sm_count_str}'")
        
        sm_count = int(sm_count_str)
        blocks, threads, points = sm_count * 7, 256, 1024
        
        hardware_config['has_gpu'] = True
        hardware_config['gpu_params'] = {'blocks': blocks, 'threads': threads, 'points': points}
        print(f"✅ GPU: {gpu_name} (SM: {sm_count}) -> 检测成功，已自动配置性能参数。")

    except Exception as e_tune:
        # 步骤 2: 如果调优失败，尝试进行基本检测
        print(f"⚠️ 自动GPU参数调优失败 (原因: {e_tune})。")
        print("   正在尝试基本GPU检测...")
        try:
            cmd_basic = ['nvidia-smi', '--query-gpu=name', '--format=csv,noheader,nounits']
            result_basic = subprocess.run(cmd_basic, capture_output=True, text=True, check=True, timeout=5)
            gpu_name_basic = result_basic.stdout.strip()
            
            hardware_config['has_gpu'] = True
            hardware_config['gpu_params'] = default_gpu_params
            print(f"✅ GPU: {gpu_name_basic} -> 基本检测成功。GPU任务将使用默认性能参数。")

        except Exception as e_detect:
            # 步骤 3: 如果基本检测也失败，则确认无可用GPU
            print(f"❌ 最终确认：未检测到有效NVIDIA GPU (原因: {e_detect}) -> 将只使用 CPU。")
            hardware_config['has_gpu'] = False

    # --- CPU 检测 ---
    try:
        cpu_cores = os.cpu_count()
        # 如果有GPU，让CPU全力以赴；如果没有GPU，保留一个核心给系统
        threads = cpu_cores if hardware_config['has_gpu'] else max(1, cpu_cores - 1 if cpu_cores > 1 else 1)
        hardware_config['cpu_threads'] = threads
        print(f"✅ CPU: {cpu_cores} 核心 -> CPU 任务将使用 {threads} 个线程。")
    except Exception as e:
        hardware_config['cpu_threads'] = 15 # fallback
        print(f"⚠️ CPU核心检测失败 (原因: {e}) -> CPU 任务将使用默认 {hardware_config['cpu_threads']} 个线程。")
        
    return hardware_config



def setup_task_logger(name, log_file):
    """为单个任务动态配置一个专用的日志记录器。"""
    # 防止日志重复添加处理器
    logger = logging.getLogger(name)
    if logger.hasHandlers():
        logger.handlers.clear()
        
    logger.setLevel(logging.DEBUG)
    formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    
    # 文件处理器
    fh = logging.FileHandler(log_file, encoding='utf-8')
    fh.setFormatter(formatter)
    logger.addHandler(fh)
    
    # 控制台处理器 (可选，用于在主控台也显示部分日志)
    # sh = logging.StreamHandler(sys.stdout)
    # sh.setFormatter(formatter)
    # logger.addHandler(sh)
    
    return logger

def reader_thread(pipe, queue):
    """一个简单的线程目标函数，它从管道(pipe)读取数据并放入队列(queue)。"""
    try:
        with pipe:
            for line in iter(pipe.readline, ''):
                queue.put(line)
    except Exception as e:
        # 在某些情况下管道可能已经关闭，这里记录一下
        # print(f"[READER-THREAD] 读取管道时发生异常: {e}")
        pass


def run_cpu_task(work_unit, num_threads, result_container):
    """
    [V8 重构] 
    - 使用线程和队列实现对 KeyHunt 的非阻塞 I/O 读取，彻底解决卡死问题。
    - 为每次任务执行创建详细的日志文件，记录所有输入、输出和最终结果。
    - 改进错误检测逻辑，能识别因无效地址等原因导致的“伪成功”退出。
    """
    address, start_key_dec, end_key_dec = work_unit['address'], work_unit['range']['start'], work_unit['range']['end']
    
    # --- 1. 初始化工作目录和日志 ---
    task_id = f"kh_{address[:10]}_{uuid.uuid4().hex[:6]}"
    task_work_dir = os.path.join(BASE_WORK_DIR, task_id)
    os.makedirs(task_work_dir, exist_ok=True)
    
    log_file_path = os.path.join(task_work_dir, 'task_run.log')
    logger = setup_task_logger(task_id, log_file_path)

    logger.info(f"===== CPU 任务启动: {task_id} =====")
    logger.info(f"目标地址: {address}")
    # [V7] 记录任务元数据
    logger.info(f"JobKey: {work_unit.get('job_key')}, 重试次数: {work_unit.get('retries')}")
    print(f"[CPU-WORKER] 开始处理地址: {address[:12]}... 日志: {log_file_path}")

    # --- 2. 范围转换和参数计算 ---
    try:
        start_key_int = int(start_key_dec)
        end_key_int = int(end_key_dec)
        start_key_hex = hex(start_key_int)[2:]
        end_key_hex = hex(end_key_int)[2:]
        logger.info(f"API 范围 (10进制): {start_key_dec} - {end_key_dec}")
        logger.info(f"程序范围 (16进制): {start_key_hex} - {end_key_hex}")

        keys_to_search = end_key_int - start_key_int + 1
        if keys_to_search <= 0:
            raise ValueError("密钥范围无效，结束点小于起始点")
        n_value = (keys_to_search + 1023) // 1024 * 1024
        n_value_hex = hex(n_value)
        logger.info(f"范围总数: {keys_to_search} | 计算出的 -n 参数: {n_value} ({n_value_hex})")

    except (ValueError, TypeError) as e:
        msg = f"API返回的范围值或计算-n参数时无效: {e}"
        logger.error(msg)
        print(f"⚠️ [CPU-WORKER] {msg}")
        result_container['result'] = {'error': True, 'error_type': 'TRANSIENT', 'error_message': msg}
        return

    # --- 3. 构建并执行命令 ---
    kh_address_file = os.path.join(task_work_dir, 'target_address.txt')
    with open(kh_address_file, 'w') as f: f.write(address)

    command = [
        KEYHUNT_PATH, '-m', 'address', '-f', kh_address_file,
        '-l', 'compress', '-t', str(num_threads),
        '-r', f'{start_key_hex}:{end_key_hex}',
        '-n', n_value_hex
    ]
    
    command_str = shlex.join(command)
    logger.info(f"执行命令: {command_str}")
    print(f"  -> 执行命令: {command_str}")

    process, process_info = None, None
    final_result = {'found': False, 'error': False}
    
    try:
        process = subprocess.Popen(
            command, 
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE,
            text=True, 
            encoding='utf-8',
            errors='ignore'
        )
        process_info = {'process': process, 'name': 'KeyHunt'}
        processes_to_cleanup.append(process_info)
        logger.info(f"KeyHunt (PID: {process.pid}) 已启动...")
        print(f"[CPU-WORKER] KeyHunt (PID: {process.pid}) 已启动...")

        # --- 4. 非阻塞 I/O 读取 ---
        stdout_q, stderr_q = Queue(), Queue()
        stdout_thread = threading.Thread(target=reader_thread, args=(process.stdout, stdout_q))
        stderr_thread = threading.Thread(target=reader_thread, args=(process.stderr, stderr_q))
        stdout_thread.daemon = stderr_thread.daemon = True
        stdout_thread.start()
        stderr_thread.start()

        all_stdout_lines = []
        
        # 循环直到进程结束
        while process.poll() is None:
            try:
                # 尝试从 stdout 队列读取，超时1秒
                line = stdout_q.get(timeout=1)
                clean_line = line.strip()
                logger.debug(f"[STDOUT] {clean_line}")
                all_stdout_lines.append(clean_line)
                
                # 实时检查是否找到密钥
                match = KEYHUNT_PRIV_KEY_RE.search(clean_line)
                if match:
                    found_key = match.group(1).lower()
                    msg = f"实时捕获到密钥: {found_key}"
                    logger.info(f"🔔🔔🔔 {msg} 🔔🔔🔔")
                    print(f"\n🔔🔔🔔 [CPU-WORKER] {msg}！🔔🔔🔔")
                    final_result = {'found': True, 'private_key': found_key, 'error': False}
                    process.terminate() # 找到后立即终止
                    break # 退出读取循环

            except Empty:
                # 队列为空是正常现象，表示子进程正在计算而没有输出
                pass
            
            # 检查 stderr，只记录不中断
            while not stderr_q.empty():
                line = stderr_q.get_nowait()
                logger.warning(f"[STDERR] {line.strip()}")
        
        # --- 5. 任务结束后的处理 ---
        returncode = process.wait()
        logger.info(f"KeyHunt 进程已退出，返回码: {returncode}")

        # 等待读取线程结束，并排空队列中的剩余数据
        stdout_thread.join(timeout=2)
        stderr_thread.join(timeout=2)
        while not stdout_q.empty(): all_stdout_lines.append(stdout_q.get_nowait().strip())
        
        stderr_output = "".join(list(stderr_q.queue))
        if stderr_output: logger.warning(f"最终捕获的完整 STDERR:\n---(start)---\n{stderr_output}\n---(end)---")
        
        # --- 6. 最终结果判断 ---
        if final_result.get('found'):
            msg = "任务因找到密钥而成功结束。"
            logger.info(msg)
            print(f"[CPU-WORKER] {msg}")
        elif returncode != 0:
            final_result['error'] = True
            final_result['error_type'], final_result['error_message'] = classify_task_error(returncode, stderr_output)
            msg = f"任务失败! 类型: {final_result['error_type']}, 原因: {final_result['error_message']}"
            logger.error(msg)
            print(f"⚠️ [CPU-WORKER] {msg}")
        else: # returncode == 0 且未找到密钥
            # [智能判断] 检查是否存在“伪成功”的迹象
            full_stdout = "\n".join(all_stdout_lines)
            if "0 values were loaded" in full_stdout or "Ommiting invalid line" in full_stdout:
                final_result['error'] = True
                final_result['error_type'] = 'FATAL' # 地址无效是致命错误，无需重试
                final_result['error_message'] = "KeyHunt报告加载了0个地址，地址格式很可能无效。"
                msg = f"检测到伪成功退出! {final_result['error_message']}"
                logger.error(msg)
                print(f"⚠️ [CPU-WORKER] {msg}")
            else:
                msg = "范围搜索正常完成但未找到密钥。"
                logger.info(msg)
                print(f"[CPU-WORKER] {msg}")

    except FileNotFoundError:
        final_result = {'error': True, 'error_type': 'FATAL', 'error_message': f"程序文件未找到: {KEYHUNT_PATH}"}
        logger.critical(final_result['error_message'])
    except Exception as e:
        final_result = {'error': True, 'error_type': 'TRANSIENT', 'error_message': f"执行时发生Python异常: {e}"}
        logger.exception("执行 run_cpu_task 时发生未捕获的Python异常")
    finally:
        if process and process_info in processes_to_cleanup:
            processes_to_cleanup.remove(process_info)
        
        # 保留工作目录和日志以供调试
        # shutil.rmtree(task_work_dir, ignore_errors=True) 
        msg = f"任务清理完成。工作目录保留于: {task_work_dir}"
        logger.info(f"===== 任务结束: {task_id} =====\n")
        print(f"[CPU-WORKER] {msg}")

        # 关闭日志处理器，释放文件句柄
        for handler in logger.handlers:
            handler.close()
            logger.removeHandler(handler)
            
        result_container['result'] = final_result

def run_gpu_task(work_unit, gpu_params, result_container):
    """
    [V6 修改] 执行BitCrack，自动转换范围为16进制，并读取日志文件内容进行错误分类。
    """
    address, start_key_dec, end_key_dec = work_unit['address'], work_unit['range']['start'], work_unit['range']['end']
    print(f"[GPU-WORKER] 开始处理地址: {address[:12]}...")

    # --- [V6] 范围转换和日志 ---
    try:
        start_key_hex = hex(int(start_key_dec))[2:]
        end_key_hex = hex(int(end_key_dec))[2:]
        keyspace_hex = f'{start_key_hex}:{end_key_hex}'
        print(f"  -> API 范围 (10进制): {start_key_dec} - {end_key_dec}")
        print(f"  -> 程序范围 (16进制): {keyspace_hex}")
    except (ValueError, TypeError):
        msg = f"API返回的范围值无效: start={start_key_dec}, end={end_key_dec}"
        print(f"⚠️ [GPU-WORKER] {msg}")
        result_container['result'] = {'error': True, 'error_type': 'TRANSIENT', 'error_message': msg}
        return
    # --- [V6] 结束 ---

    task_work_dir = os.path.join(BASE_WORK_DIR, f"bc_{address[:10]}_{uuid.uuid4().hex[:6]}")
    os.makedirs(task_work_dir, exist_ok=True)
    found_file_path = os.path.join(task_work_dir, 'found.txt')
    progress_file = os.path.join(task_work_dir, 'progress.dat')
    log_file_path = os.path.join(task_work_dir, 'bitcrack_output.log')

    command = [
        BITCRACK_PATH, '-b', str(gpu_params['blocks']), '-t', str(gpu_params['threads']),
        '-p', str(gpu_params['points']), '--keyspace', keyspace_hex, '-o', found_file_path, # <-- [V6] 使用16进制范围
        '--continue', progress_file, address
    ]
    
    # --- [V6] 打印完整命令 ---
    print(f"  -> 执行命令: {shlex.join(command)}")

    process, process_info = None, None
    final_result = {'found': False, 'error': False, 'error_type': None, 'error_message': ''}
    
    try:
        # 注意：为了简洁，这里直接等待进程结束，并通过日志文件判断错误。
        # 对于需要实时监控进度的场景，可以改回 Popen。
        with open(log_file_path, 'w') as log_file:
            # [V7] 在日志中记录任务元数据
            log_file.write(f"===== GPU 任务启动 =====\n")
            log_file.write(f"JobKey: {work_unit.get('job_key')}\n")
            log_file.write(f"Retries: {work_unit.get('retries')}\n")
            log_file.write(f"Command: {shlex.join(command)}\n")
            log_file.write("---------------------------\n\n")
            log_file.flush()
            
            process = subprocess.Popen(command, stdout=log_file, stderr=subprocess.STDOUT)
            process_info = {'process': process, 'name': 'BitCrack'}
            processes_to_cleanup.append(process_info)
            print(f"[GPU-WORKER] BitCrack (PID: {process.pid}) 已启动。日志提示: tail -f {shlex.quote(log_file_path)}")
            returncode = process.wait()

        print(f"\n[GPU-WORKER] BitCrack 进程 (PID: {process.pid}) 已退出，返回码: {returncode}")
        
        if returncode != 0:
            error_log_content = ""
            if os.path.exists(log_file_path):
                with open(log_file_path, 'r', errors='ignore') as f:
                    error_log_content = f.read()
            final_result['error'] = True
            final_result['error_type'], final_result['error_message'] = classify_task_error(returncode, error_log_content)
            print(f"⚠️ [GPU-WORKER] 任务失败! 类型: {final_result['error_type']}, 原因: {final_result['error_message']}")

        if os.path.exists(found_file_path) and os.path.getsize(found_file_path) > 0:
            with open(found_file_path, 'r') as f:
                line = f.readline().strip()
                if line:
                    parts = line.split()
                    # 健壮地提取私钥，防止文件格式问题
                    key_part_index = -1
                    for i, part in enumerate(parts):
                        if len(part) == 64 and all(c in '0123456789abcdefABCDEF' for c in part):
                            key_part_index = i
                            break
                    
                    if key_part_index != -1:
                        found_key = parts[key_part_index].lower()
                        print(f"\n🎉🎉🎉 [GPU-WORKER] 在文件中找到密钥: {found_key}！🎉🎉🎉")
                        final_result = {'found': True, 'private_key': found_key, 'error': False}
                    else:
                        final_result['error'] = True
                        final_result['error_type'] = 'TRANSIENT'
                        final_result['error_message'] = f"在found.txt中找到内容但无法解析出私钥: '{line}'"
                        print(f"⚠️ [GPU-WORKER] {final_result['error_message']}")
        
        if not final_result.get('found') and not final_result.get('error'):
            print("[GPU-WORKER] 范围搜索完毕但未在文件中找到密钥。")

    except FileNotFoundError:
        final_result = {'error': True, 'error_type': 'FATAL', 'error_message': f"程序文件未找到: {BITCRACK_PATH}"}
    except Exception as e:
        final_result = {'error': True, 'error_type': 'TRANSIENT', 'error_message': f"执行时发生Python异常: {e}"}
    finally:
        if process and process_info in processes_to_cleanup:
            processes_to_cleanup.remove(process_info)
        # 保留GPU的工作目录以供调试
        print(f"[GPU-WORKER] 任务清理完成。工作目录保留于: {task_work_dir}")
        result_container['result'] = final_result


# ==============================================================================
# --- 6. 主控制器逻辑 (V6 修改) ---
# ==============================================================================

def main():
    """[V7 修改] 主控制器，使用独立进程处理GPU任务，并正确处理JobKey。"""
    client_id = f"btc-controller-{uuid.uuid4().hex[:8]}"
    print(f"控制器启动 (V7 JobKey 集成修复版)，客户端 ID: {client_id}")
    os.makedirs(BASE_WORK_DIR, exist_ok=True)
    
    hardware = detect_hardware()
    session = requests.Session()
    session.headers.update(BROWSER_HEADERS)

    # --- [V6] 使用 multiprocessing.Manager 来创建进程安全的共享字典 ---
    manager = multiprocessing.Manager()

    # 为每个计算单元创建状态机
    task_slots = {}
    if hardware['has_gpu']:
        task_slots['GPU'] = {'worker': None, 'work': None, 'result_container': None, 'enabled': True, 'consecutive_errors': 0}
    task_slots['CPU'] = {'worker': None, 'work': None, 'result_container': None, 'enabled': True, 'consecutive_errors': 0}

    try:
        # 主循环条件：只要至少还有一个工作单元是启用的，就继续运行
        while any(slot['enabled'] for slot in task_slots.values()):
            for unit_name, slot in task_slots.items():
                if not slot['enabled']:
                    continue

                # 步骤 1: 检查并处理已完成的任务
                if slot['worker'] and not slot['worker'].is_alive():
                    print_header(f"{unit_name} 任务完成")
                    # 从共享容器中获取结果
                    result = slot['result_container'].get('result', {'error': True, 'error_type': 'TRANSIENT', 'error_message': '结果容器为空，未知错误'})

                    if not result.get('error'):
                        # 任务成功
                        print(f"✅ {unit_name} 任务成功。重置连续错误计数。")
                        slot['consecutive_errors'] = 0 
                        # 【V7 修复】传递整个 work 对象，它包含了 job_key
                        submit_result(session, slot['work'], result.get('found', False), result.get('private_key'))
                    else:
                        # 任务失败
                        slot['consecutive_errors'] += 1
                        error_type = result.get('error_type', 'TRANSIENT')
                        
                        print(f"🔴 {unit_name} 任务连续失败次数: {slot['consecutive_errors']}/{MAX_CONSECUTIVE_ERRORS}")

                        if error_type == 'FATAL' or slot['consecutive_errors'] >= MAX_CONSECUTIVE_ERRORS:
                            slot['enabled'] = False
                            reason = '致命错误' if error_type == 'FATAL' else '达到最大重试次数'
                            print(f"🚫🚫🚫 {unit_name} 工作单元已被永久禁用! 原因: {reason} 🚫🚫🚫")
                    
                    slot['worker'], slot['work'] = None, None

                # 步骤 2: 为空闲且启用的任务槽分配新任务
                if not slot['worker'] and slot['enabled']:
                    print_header(f"为 {unit_name} 请求新任务")
                    work_unit = get_work_with_retry(session, f"{client_id}-{unit_name}")
                    if work_unit:
                        slot['work'] = work_unit
                        
                        # --- [V6] 根据单元类型选择线程或进程 ---
                        if unit_name == 'GPU':
                            slot['result_container'] = manager.dict() # 进程安全的字典
                            target_func = run_gpu_task
                            args = (work_unit, hardware['gpu_params'], slot['result_container'])
                            worker = multiprocessing.Process(target=target_func, args=args)
                        else: # CPU
                            slot['result_container'] = {} # 普通字典即可
                            target_func = run_cpu_task
                            args = (work_unit, hardware['cpu_threads'], slot['result_container'])
                            worker = threading.Thread(target=target_func, args=args)
                        
                        slot['worker'] = worker
                        worker.start()
            
            time.sleep(5) # 主循环轮询间隔
        
        print("\n" + "="*80)
        print("所有计算单元均已被禁用，控制器将退出。请检查以上日志以诊断问题。")
        print("="*80)

    except KeyboardInterrupt:
        print("\n[CONTROLLER] 检测到用户中断 (Ctrl+C)。将执行最终清理后退出。")
    except Exception as e:
        print(f"\n[CONTROLLER FATAL ERROR] 主循环发生无法恢复的错误: {e}")
        import traceback; traceback.print_exc()
    finally:
        print("[CONTROLLER] 脚本正在关闭...")

if __name__ == '__main__':
    # [V6] 对于 multiprocessing，必须将主代码放在 if __name__ == '__main__': 块中
    # 这是为了防止在Windows和macOS上创建子进程时出现无限递归。

    # 启动前进行关键路径检查
    if not os.path.exists(KEYHUNT_PATH) or not shutil.which(KEYHUNT_PATH):
        print(f"!! 启动错误: KeyHunt 程序未找到或不可执行，路径: '{KEYHUNT_PATH}' !!")
        sys.exit(1)
    
    try:
        # 简单运行 nvidia-smi 判断是否有GPU，避免在无GPU机器上强行要求BitCrack
        subprocess.run(['nvidia-smi'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not os.path.exists(BITCRACK_PATH) or not shutil.which(BITCRACK_PATH):
            print(f"!! 启动错误: 检测到NVIDIA GPU，但BitCrack程序未找到或不可执行，路径: '{BITCRACK_PATH}' !!")
            sys.exit(1)
    except (FileNotFoundError, subprocess.CalledProcessError):
        # 没有nvidia-smi，或执行失败，说明没有可用的GPU，不检查BitCrack路径
        pass
        
    main()
