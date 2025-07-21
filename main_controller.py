#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
BTC 自动化挖矿总控制器 (V6 - 高效循环版)

该脚本整合了 API通信、CPU(KeyHunt)挖矿 和 GPU(BitCrack)挖矿三大功能，实现全自动、高容错的工作流程。

新特性:
- [V6] 解决了BitCrack找到密钥后不退出的问题。新增GPU任务实时文件监控，一旦发现密钥，会立即终止BitCrack进程并上报，极大提高效率。
- [V6] 明确了控制器架构：主循环持续运行，任何一个工作单元（CPU/GPU）完成任务（找到密钥或搜完范围）后，会立即上报并自动请求下一个新任务，实现无缝循环。
- 改进了GPU检测逻辑，即使自动参数调整失败，只要检测到GPU存在，就会回退到使用安全的默认参数。
- 引入智能错误处理机制，区分“瞬时错误”和“致命错误”。
"""

import subprocess
import os
import threading
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
MAX_CONSECUTIVE_ERRORS = 3
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
    """
    print("\n[CONTROLLER CLEANUP] 检测到程序退出，正在清理所有已注册的子进程...")
    for p_info in list(processes_to_cleanup):
        p = p_info['process']
        if p.poll() is None:
            print(f"  -> 正在终止进程 PID: {p.pid} ({p_info['name']})...")
            try:
                p.terminate(); p.wait(timeout=3)
            except (psutil.NoSuchProcess, subprocess.TimeoutExpired):
                if p.poll() is None:
                    try: p.kill(); p.wait(timeout=2)
                    except Exception as e: print(f"  -> 强制终止 PID: {p.pid} 时出错: {e}")
            except Exception as e:
                print(f"  -> 终止 PID: {p.pid} 时发生意外错误: {e}")
    print("[CONTROLLER CLEANUP] 清理完成。")

atexit.register(cleanup_all_processes)

def print_header(title):
    bar = "=" * 80
    print(f"\n{bar}\n===== {title} =====\n{bar}")

def classify_task_error(returncode, stderr_output):
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

# ==============================================================================
# --- 4. API 通信模块 ---
# ==============================================================================

def get_work_with_retry(session, client_id):
    print(f"\n[*] 客户端 '{client_id}' 正在向服务器请求新的工作...")
    while True:
        try:
            response = session.post(WORK_URL, json={'client_id': client_id}, timeout=30)
            if response.status_code == 200:
                work_data = response.json()
                if work_data.get('address') and work_data.get('range'):
                    print(f"[+] 成功获取工作! 地址: {work_data['address']}, 范围: {work_data['range']['start']} - {work_data['range']['end']}")
                    return work_data
                else:
                    print(f"[!] 获取工作成功(200)，但响应格式不正确: {response.text}。将在 {API_RETRY_DELAY} 秒后重试...")
            elif response.status_code == 503:
                error_message = response.json().get("error", "未知503错误")
                print(f"[!] 服务器当前无工作可分发 (原因: {error_message})。将在 {API_RETRY_DELAY} 秒后重试...")
            else:
                print(f"[!] 获取工作时遇到意外的HTTP状态码: {response.status_code}, 响应: {response.text}。将在 {API_RETRY_DELAY} 秒后重试...")
        except requests.exceptions.RequestException as e:
            print(f"[!] 请求工作时发生网络错误: {e}。将在 {API_RETRY_DELAY} 秒后重试...")
        time.sleep(API_RETRY_DELAY)

def submit_result(session, address, found, private_key=None):
    payload = {'address': address, 'found': found}
    if found:
        print(f"[*] 准备向服务器提交为地址 {address} 找到的私钥...")
        payload['private_key'] = private_key
    else:
        print(f"[*] 准备向服务器报告地址 {address} 的范围已搜索完毕 (未找到)。")
    try:
        response = session.post(SUBMIT_URL, json=payload, headers=BROWSER_HEADERS, timeout=30)
        if response.status_code == 200: print("[+] 结果提交成功!")
        else: print(f"[!] 提交失败! 状态码: {response.status_code}, 响应: {response.text}")
        return response.ok
    except requests.RequestException as e:
        print(f"[!] 提交结果时发生网络错误: {e}")
        return False

# ==============================================================================
# --- 5. 硬件检测与挖矿任务执行模块 (V6 修改) ---
# ==============================================================================

def detect_hardware():
    print_header("硬件自检")
    hardware_config = {'has_gpu': False, 'gpu_params': None, 'cpu_threads': 1}
    default_gpu_params = {'blocks': 288, 'threads': 256, 'points': 1024}
    try:
        cmd_tune = ['nvidia-smi', '--query-gpu=name,multiprocessor_count', '--format=csv,noheader,nounits']
        result = subprocess.run(cmd_tune, capture_output=True, text=True, check=True, timeout=5)
        gpu_name, sm_count_str = result.stdout.strip().split(', ')
        if not sm_count_str.isdigit(): raise ValueError(f"SM Count 无效: '{sm_count_str}'")
        sm_count = int(sm_count_str)
        blocks, threads, points = sm_count * 7, 256, 1024
        hardware_config.update({'has_gpu': True, 'gpu_params': {'blocks': blocks, 'threads': threads, 'points': points}})
        print(f"✅ GPU: {gpu_name} (SM: {sm_count}) -> 检测成功，已自动配置性能参数。")
    except Exception as e_tune:
        print(f"⚠️ 自动GPU参数调优失败 (原因: {e_tune})。正在尝试基本GPU检测...")
        try:
            cmd_basic = ['nvidia-smi', '--query-gpu=name', '--format=csv,noheader,nounits']
            gpu_name_basic = subprocess.check_output(cmd_basic, text=True, timeout=5).strip()
            hardware_config.update({'has_gpu': True, 'gpu_params': default_gpu_params})
            print(f"✅ GPU: {gpu_name_basic} -> 基本检测成功。GPU任务将使用默认性能参数。")
        except Exception as e_detect:
            print(f"❌ 最终确认：未检测到有效NVIDIA GPU (原因: {e_detect}) -> 将只使用 CPU。")
            hardware_config['has_gpu'] = False
    try:
        cpu_cores = os.cpu_count()
        threads = cpu_cores if hardware_config['has_gpu'] else max(1, cpu_cores - 1 if cpu_cores > 1 else 1)
        hardware_config['cpu_threads'] = threads
        print(f"✅ CPU: {cpu_cores} 核心 -> CPU 任务将使用 {threads} 个线程。")
    except Exception as e:
        hardware_config['cpu_threads'] = 15 # fallback
        print(f"⚠️ CPU核心检测失败 (原因: {e}) -> CPU 任务将使用默认 {hardware_config['cpu_threads']} 个线程。")
    return hardware_config


def run_cpu_task(work_unit, num_threads, result_container):
    address, start_key, end_key = work_unit['address'], work_unit['range']['start'], work_unit['range']['end']
    print(f"[CPU-WORKER] 开始处理地址: {address[:12]}...")
    task_work_dir = os.path.join(BASE_WORK_DIR, f"kh_{address[:10]}_{uuid.uuid4().hex[:6]}")
    os.makedirs(task_work_dir, exist_ok=True)
    kh_address_file = os.path.join(task_work_dir, 'target_address.txt')
    with open(kh_address_file, 'w') as f: f.write(address)
    command = [
        KEYHUNT_PATH, '-m', 'address', '-f', kh_address_file,
        '-l', 'both', '-t', str(num_threads), '-R', '-r', f'{start_key}:{end_key}'
    ]
    process, process_info = None, None
    final_result = {'found': False, 'error': False, 'error_type': None, 'error_message': ''}
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='ignore')
        process_info = {'process': process, 'name': 'KeyHunt'}
        processes_to_cleanup.append(process_info)
        print(f"[CPU-WORKER] KeyHunt (PID: {process.pid}) 已启动...")
        for line in iter(process.stdout.readline, ''):
            if process.poll() is not None: break
            clean_line = line.strip()
            if 'K/s' in clean_line or 'M/s' in clean_line:
                 sys.stdout.write(f"\r  [CPU Status] {clean_line}"); sys.stdout.flush()
            match = KEYHUNT_PRIV_KEY_RE.search(line)
            if match:
                found_key = match.group(1).lower()
                print(f"\n🔔🔔🔔 [CPU-WORKER] 实时捕获到密钥: {found_key}！🔔🔔🔔")
                final_result = {'found': True, 'private_key': found_key, 'error': False}
                process.terminate() # 找到后立即终止
                break
        sys.stdout.write("\r" + " " * 80 + "\r"); sys.stdout.flush()
        returncode = process.wait()
        stderr_output = process.stderr.read()
        if returncode != 0 and not final_result['found']:
            final_result['error'] = True
            final_result['error_type'], final_result['error_message'] = classify_task_error(returncode, stderr_output)
            print(f"⚠️ [CPU-WORKER] 任务失败! 类型: {final_result['error_type']}, 原因: {final_result['error_message']}")
        elif not final_result['found']:
             print("[CPU-WORKER] 范围搜索完毕但未找到密钥。")
    except FileNotFoundError:
        final_result = {'error': True, 'error_type': 'FATAL', 'error_message': f"程序文件未找到: {KEYHUNT_PATH}"}
    except Exception as e:
        final_result = {'error': True, 'error_type': 'TRANSIENT', 'error_message': f"执行时发生Python异常: {e}"}
    finally:
        if process and process_info in processes_to_cleanup: processes_to_cleanup.remove(process_info)
        shutil.rmtree(task_work_dir, ignore_errors=True)
        print(f"[CPU-WORKER] 任务清理完成。")
        result_container['result'] = final_result


def run_gpu_task(work_unit, gpu_params, result_container):
    """
    [V6 修改] 执行BitCrack，并引入实时文件监控以在找到密钥时立即终止进程。
    """
    address, keyspace = work_unit['address'], f"{work_unit['range']['start']}:{work_unit['range']['end']}"
    print(f"[GPU-WORKER] 开始处理地址: {address[:12]}...")
    task_work_dir = os.path.join(BASE_WORK_DIR, f"bc_{address[:10]}_{uuid.uuid4().hex[:6]}")
    os.makedirs(task_work_dir, exist_ok=True)
    found_file_path = os.path.join(task_work_dir, 'found.txt')
    progress_file = os.path.join(task_work_dir, 'progress.dat')
    log_file_path = os.path.join(task_work_dir, 'bitcrack_output.log')
    command = [
        BITCRACK_PATH, '-b', str(gpu_params['blocks']), '-t', str(gpu_params['threads']),
        '-p', str(gpu_params['points']), '--keyspace', keyspace, '-o', found_file_path,
        '--continue', progress_file, address
    ]
    process, process_info = None, None
    final_result = {'found': False, 'error': False, 'error_type': None, 'error_message': ''}
    try:
        with open(log_file_path, 'w') as log_file:
            process = subprocess.Popen(command, stdout=log_file, stderr=log_file)
            process_info = {'process': process, 'name': 'BitCrack'}
            processes_to_cleanup.append(process_info)
            print(f"[GPU-WORKER] BitCrack (PID: {process.pid}) 已启动。日志提示: tail -f {shlex.quote(log_file_path)}")
            
            # --- V6 新增：实时文件监控 ---
            while process.poll() is None:
                if os.path.exists(found_file_path) and os.path.getsize(found_file_path) > 0:
                    print(f"\n🎉🎉🎉 [GPU-WORKER] 检测到 'found.txt' 文件非空，正在终止 BitCrack... 🎉🎉🎉")
                    process.terminate() # 找到后立即终止
                    time.sleep(1) # 等待进程响应
                    break
                time.sleep(5) # 每5秒检查一次
            # --- 监控结束 ---

        returncode = process.wait()
        print(f"\n[GPU-WORKER] BitCrack 进程 (PID: {process.pid}) 已退出，返回码: {returncode}")
        
        # 检查最终结果
        if os.path.exists(found_file_path) and os.path.getsize(found_file_path) > 0:
            with open(found_file_path, 'r') as f:
                line = f.readline().strip()
                if line:
                    parts = line.split()
                    found_key = parts[1] if len(parts) >= 2 else "格式错误"
                    print(f"[GPU-WORKER] 在文件中确认找到密钥: {found_key}")
                    final_result = {'found': True, 'private_key': found_key, 'error': False}

        if returncode != 0 and not final_result['found']:
            error_log_content = ""
            if os.path.exists(log_file_path):
                with open(log_file_path, 'r', errors='ignore') as f: error_log_content = f.read()
            final_result['error'] = True
            final_result['error_type'], final_result['error_message'] = classify_task_error(returncode, error_log_content)
            print(f"⚠️ [GPU-WORKER] 任务失败! 类型: {final_result['error_type']}, 原因: {final_result['error_message']}")
        
        if not final_result['found'] and not final_result['error']:
            print("[GPU-WORKER] 范围搜索完毕但未在文件中找到密钥。")

    except FileNotFoundError:
        final_result = {'error': True, 'error_type': 'FATAL', 'error_message': f"程序文件未找到: {BITCRACK_PATH}"}
    except Exception as e:
        final_result = {'error': True, 'error_type': 'TRANSIENT', 'error_message': f"执行时发生Python异常: {e}"}
    finally:
        if process and process_info in processes_to_cleanup: processes_to_cleanup.remove(process_info)
        print(f"[GPU-WORKER] 任务清理完成。工作目录保留于: {task_work_dir}")
        result_container['result'] = final_result

# ==============================================================================
# --- 6. 主控制器逻辑 (智能容错) ---
# ==============================================================================

def main():
    client_id = f"btc-controller-{uuid.uuid4().hex[:8]}"
    print(f"控制器启动 (V6 高效循环版)，客户端 ID: {client_id}")
    os.makedirs(BASE_WORK_DIR, exist_ok=True)
    hardware = detect_hardware()
    session = requests.Session()
    session.headers.update(BROWSER_HEADERS)
    task_slots = {}
    if hardware['has_gpu']:
        task_slots['GPU'] = {'thread': None, 'work': None, 'result_container': None, 'enabled': True, 'consecutive_errors': 0}
    task_slots['CPU'] = {'thread': None, 'work': None, 'result_container': None, 'enabled': True, 'consecutive_errors': 0}

    try:
        while any(slot['enabled'] for slot in task_slots.values()):
            for unit_name, slot in task_slots.items():
                if not slot['enabled']: continue

                # 步骤 1: 检查并处理已完成的任务
                if slot['thread'] and not slot['thread'].is_alive():
                    print_header(f"{unit_name} 任务完成")
                    result = slot['result_container'].get('result', {'error': True, 'error_type': 'TRANSIENT', 'error_message': '结果容器为空'})
                    if not result.get('error'):
                        print(f"✅ {unit_name} 任务成功。重置连续错误计数。")
                        slot['consecutive_errors'] = 0 
                        submit_result(session, slot['work']['address'], result.get('found', False), result.get('private_key'))
                    else:
                        slot['consecutive_errors'] += 1
                        error_type = result.get('error_type', 'TRANSIENT')
                        print(f"🔴 {unit_name} 任务连续失败次数: {slot['consecutive_errors']}/{MAX_CONSECUTIVE_ERRORS}")
                        if error_type == 'FATAL' or slot['consecutive_errors'] >= MAX_CONSECUTIVE_ERRORS:
                            slot['enabled'] = False
                            reason = '致命错误' if error_type == 'FATAL' else '达到最大重试次数'
                            print(f"🚫🚫🚫 {unit_name} 工作单元已被永久禁用! 原因: {reason} 🚫🚫🚫")
                    slot['thread'], slot['work'] = None, None

                # 步骤 2: 为空闲且启用的任务槽分配新任务
                if not slot['thread'] and slot['enabled']:
                    print_header(f"为 {unit_name} 请求新任务")
                    work_unit = get_work_with_retry(session, f"{client_id}-{unit_name}")
                    if work_unit:
                        slot['work'] = work_unit
                        slot['result_container'] = {}
                        target_func = run_gpu_task if unit_name == 'GPU' else run_cpu_task
                        args = (work_unit, hardware['gpu_params'], slot['result_container']) if unit_name == 'GPU' else (work_unit, hardware['cpu_threads'], slot['result_container'])
                        thread = threading.Thread(target=target_func, args=args)
                        slot['thread'] = thread
                        thread.start()
            time.sleep(5)
        print("\n" + "="*80 + "\n所有计算单元均已被禁用，控制器将退出。\n" + "="*80)
    except KeyboardInterrupt:
        print("\n[CONTROLLER] 检测到用户中断 (Ctrl+C)。将执行最终清理后退出。")
    except Exception as e:
        print(f"\n[CONTROLLER FATAL ERROR] 主循环发生无法恢复的错误: {e}")
        import traceback; traceback.print_exc()
    finally:
        print("[CONTROLLER] 脚本正在关闭...")

if __name__ == '__main__':
    # 启动前进行关键路径检查
    if not os.path.exists(KEYHUNT_PATH) or not shutil.which(KEYHUNT_PATH):
        print(f"!! 启动错误: KeyHunt 程序未找到或不可执行，路径: '{KEYHUNT_PATH}' !!")
        sys.exit(1)
    try:
        subprocess.run(['nvidia-smi'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not os.path.exists(BITCRACK_PATH) or not shutil.which(BITCRACK_PATH):
            print(f"!! 启动错误: 检测到NVIDIA GPU，但BitCrack程序未找到或不可执行，路径: '{BITCRACK_PATH}' !!")
            sys.exit(1)
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass # 没有GPU，不检查BitCrack
    main()
