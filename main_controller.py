#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
BTC 自动化挖矿总控制器 (V3 - 并行加速版)

该脚本整合了 API通信、CPU(KeyHunt)挖矿 和 GPU(BitCrack)挖矿三大功能，实现全自动工作流程：
1.  通过 API 从中央服务器获取工作单元（BTC地址 + 密钥范围）。
2.  自动检测本机硬件。
3.  [V3 更新] 如果检测到NVIDIA GPU，将同时启动一个 GPU 任务和一个 CPU 任务，并行加速搜索。
4.  [V3 更新] 如果没有GPU，则只启动一个 CPU 任务。
5.  在独立的、无窗口的后台模式下执行和监控任务。
6.  对进程进行严格管理，确保任务结束或找到密钥后，子进程被彻底清理。
7.  BitCrack 的详细输出将被重定向到日志文件，保持主控台清洁。
8.  将结果（找到密钥 或 范围搜索完成）提交回服务器。
9.  循环执行以上步骤，自动为完成任务的计算单元（CPU/GPU）申请新任务。

!! 使用前请务必配置下面的路径和URL !!
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
from random import getrandbits

# ==============================================================================
# --- 1. 全局配置 (请根据您的环境修改) ---
# ==============================================================================

# --- API 服务器配置 ---
BASE_URL = "https://cc2010.serv00.net/" # 【配置】请根据您的服务器地址修改此URL

# --- 挖矿程序路径配置 ---
KEYHUNT_PATH = '/workspace/keyhunt/keyhunt'    # 【配置】KeyHunt 程序的可执行文件路径
BITCRACK_PATH = '/workspace/BitCrack/bin/cuBitCrack' # 【配置】cuBitCrack 程序的可执行文件路径

# --- 工作目录配置 ---
# 总控制器将为每个任务创建独立的子目录，以防止文件冲突
BASE_WORK_DIR = '/tmp/btc_controller_work'

# ==============================================================================
# --- 2. 全局状态与常量 (通常无需修改) ---
# ==============================================================================

# --- API 端点 ---
# [原始注释] API 端点
WORK_URL = f"{BASE_URL}/btc/work"
SUBMIT_URL = f"{BASE_URL}/btc/submit"
STATUS_URL = f"{BASE_URL}/btc/status"

# --- 全局进程列表 ---
# [新代码注释] 一个全局列表，用于注册所有需要清理的子进程，确保程序在任何情况下退出时都能尝试终止它们。
processes_to_cleanup = []

# --- 正则表达式 ---
# [原始注释] 正则表达式 (无修改)
KEYHUNT_PRIV_KEY_RE = re.compile(r'(?:Private key \(hex\)|Hit! Private Key):\s*([0-9a-fA-F]+)')

# --- 模拟浏览器头信息 ---
# [原始注释] 模拟浏览器头信息
BROWSER_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36',
    'Content-Type': 'application/json'
}

# ==============================================================================
# --- 3. 核心清理与工具函数 ---
# ==============================================================================

def cleanup_all_processes():
    """
    [新代码注释]
    全局清理函数，由 atexit 注册，在脚本退出时自动调用。
    它的核心职责是终止在 `processes_to_cleanup` 列表中注册的所有子进程。
    这是防止僵尸进程的最后一道防线。
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
    """
    [原始注释]
    打印一个格式化的标题，方便区分不同的示例步骤。
    """
    bar = "=" * 80
    print(f"\n{bar}\n===== {title} =====\n{bar}")

# ==============================================================================
# --- 4. API 通信模块 (源自 api_client.py) ---
# ==============================================================================

def get_work_with_retry(session, client_id, max_retries=3, retry_delay=10):
    """
    [原始注释]
    【核心改进】请求一个新的工作范围，如果服务器暂时没有可用的工作，会自动重试。
    """
    print(f"\n[*] 客户端 '{client_id}' 正在向服务器请求新的工作...")
    for attempt in range(max_retries):
        try:
            response = session.post(WORK_URL, json={'client_id': client_id}, timeout=30)
            if response.status_code == 200:
                work_data = response.json()
                if work_data.get('address') and work_data.get('range'):
                    print(f"[+] 成功获取工作! 地址: {work_data['address']}, 范围: {work_data['range']['start']} - {work_data['range']['end']}")
                    return work_data
                else:
                    print(f"[!] 获取工作成功(200)，但响应格式不正确: {response.text}。将在 {retry_delay} 秒后重试...")
            elif response.status_code == 503:
                error_message = response.json().get("error", "未知503错误")
                print(f"[!] 服务器当前无工作可分发 (原因: {error_message})。将在 {retry_delay} 秒后重试 ({attempt + 1}/{max_retries})...")
            else:
                print(f"[!] 获取工作时遇到意外HTTP状态码: {response.status_code}, 响应: {response.text}。将在 {retry_delay} 秒后重试...")
        except requests.exceptions.RequestException as e:
            print(f"[!] 请求工作时发生网络错误: {e}。将在 {retry_delay} 秒后重试...")
        if attempt < max_retries - 1:
            time.sleep(retry_delay)
    print(f"\n[!] 在尝试 {max_retries} 次后，仍未能获取到工作。")
    return None

def submit_result(session, address, found, private_key=None):
    """
    [原始注释]
    向服务器提交工作结果。此函数逻辑保持不变。
    """
    payload = {'address': address, 'found': found}
    if found:
        print(f"[*] 准备向服务器提交为地址 {address} 找到的私钥...")
        payload['private_key'] = private_key
    else:
        print(f"[*] 准备向服务器报告地址 {address} 的范围已搜索完毕 (未找到)。")
    try:
        response = session.post(SUBMIT_URL, json=payload, headers=BROWSER_HEADERS, timeout=30)
        if response.status_code == 200:
            print("[+] 结果提交成功!")
            return True
        else:
            print(f"[!] 提交失败! 状态码: {response.status_code}, 响应: {response.text}")
            return False
    except requests.RequestException as e:
        print(f"[!] 提交结果时发生网络错误: {e}")
        return False

# ==============================================================================
# --- 5. 硬件检测与挖矿任务执行模块 ---
# ==============================================================================

def detect_hardware():
    """
    [新代码注释] (V3 修改)
    统一硬件检测函数。返回一个包含has_gpu和cpu_threads信息的字典。
    """
    print_header("硬件自检")
    hardware_config = {'has_gpu': False, 'gpu_params': None, 'cpu_threads': 1}
    
    # 检测 GPU
    try:
        cmd = ['nvidia-smi', '--query-gpu=name,multiprocessor_count', '--format=csv,noheader,nounits']
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=5)
        gpu_name, sm_count_str = result.stdout.strip().split(', ')
        if not sm_count_str.isdigit(): raise ValueError(f"非预期的 SM Count: '{sm_count_str}'")
        sm_count = int(sm_count_str)
        blocks, threads, points = sm_count * 7, 256, 1024
        
        hardware_config['has_gpu'] = True
        hardware_config['gpu_params'] = {'blocks': blocks, 'threads': threads, 'points': points}
        print(f"✅ 检测到 GPU: {gpu_name} (SM: {sm_count}) -> GPU 任务将启用。")
    except Exception as e:
        print(f"⚠️ 未检测到有效NVIDIA GPU (原因: {e}) -> 将只使用 CPU。")

    # 检测 CPU
    try:
        cpu_cores = os.cpu_count()
        # [V3 新逻辑] 如果有GPU，CPU可以不用留出核心；如果没有，则留一个核心给系统。
        threads = cpu_cores if hardware_config['has_gpu'] else max(1, cpu_cores - 1 if cpu_cores > 1 else 1)
        hardware_config['cpu_threads'] = threads
        print(f"✅ 检测到 CPU: {cpu_cores} 核心 -> CPU 任务将使用 {threads} 个线程。")
    except Exception as e:
        hardware_config['cpu_threads'] = 15 # fallback
        print(f"⚠️ CPU核心检测失败 (原因: {e}) -> CPU 任务将使用默认 {hardware_config['cpu_threads']} 个线程。")
        
    return hardware_config


def run_cpu_task(work_unit, num_threads, result_container):
    """
    [新代码注释]
    在线程中执行 KeyHunt (CPU) 任务的函数。
    它将最终结果存入传入的 result_container 字典中。
    """
    address, start_key, end_key = work_unit['address'], work_unit['range']['start'], work_unit['range']['end']
    print(f"[CPU-WORKER] 开始处理地址: {address}, 范围: {start_key} - {end_key}")
    
    task_work_dir = os.path.join(BASE_WORK_DIR, f"kh_{address[:10]}_{uuid.uuid4().hex[:6]}")
    os.makedirs(task_work_dir, exist_ok=True)
    kh_address_file = os.path.join(task_work_dir, 'target_address.txt')
    with open(kh_address_file, 'w') as f: f.write(address)

    command = [
        KEYHUNT_PATH, '-m', 'address', '-f', kh_address_file,
        '-l', 'both', '-t', str(num_threads), '-R', '-r', f'{start_key}:{end_key}'
    ]
    
    process = None; process_info = None; final_result = {'found': False}
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8')
        process_info = {'process': process, 'name': 'KeyHunt'}
        processes_to_cleanup.append(process_info)
        print(f"[CPU-WORKER] KeyHunt (PID: {process.pid}) 已启动...")

        for line in iter(process.stdout.readline, ''):
            clean_line = line.strip()
            if 'K/s' in clean_line or 'M/s' in clean_line:
                 sys.stdout.write(f"\r  [CPU Status] {clean_line}"); sys.stdout.flush()
            
            match = KEYHUNT_PRIV_KEY_RE.search(line)
            if match:
                found_key = match.group(1).lower()
                print(f"\n🔔🔔🔔 [CPU-WORKER] 实时捕获到密钥: {found_key}！🔔🔔🔔")
                final_result = {'found': True, 'private_key': found_key}
                break # 找到就跳出循环
        
        if not final_result['found']:
            sys.stdout.write("\r" + " " * 80 + "\r"); sys.stdout.flush()
            print("[CPU-WORKER] 范围搜索完毕但未找到密钥。")

    except FileNotFoundError:
        print(f"\n[致命错误] 程序文件未找到: {KEYHUNT_PATH}。"); final_result['error'] = True
    except Exception as e:
        print(f"\n[致命错误] 执行 KeyHunt 任务时发生错误: {e}"); final_result['error'] = True
    finally:
        if process:
            if process_info in processes_to_cleanup: processes_to_cleanup.remove(process_info)
            if process.poll() is None:
                try: process.terminate(); process.wait(2)
                except: process.kill()
        shutil.rmtree(task_work_dir, ignore_errors=True)
        print(f"[CPU-WORKER] 任务清理完成。")
        # [新代码注释] 无论如何，都将结果存入容器
        result_container['result'] = final_result

def run_gpu_task(work_unit, gpu_params, result_container):
    """
    [新代码注释]
    在线程中执行 BitCrack (GPU) 任务的函数。它将结果存入 result_container。
    """
    address, keyspace = work_unit['address'], f"{work_unit['range']['start']}:{work_unit['range']['end']}"
    print(f"[GPU-WORKER] 开始处理地址: {address}, 范围: {keyspace}")

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
    
    process = None; process_info = None; final_result = {'found': False}
    try:
        with open(log_file_path, 'w') as log_file:
            process = subprocess.Popen(command, stdout=log_file, stderr=log_file)
            process_info = {'process': process, 'name': 'BitCrack'}
            processes_to_cleanup.append(process_info)
            print(f"[GPU-WORKER] BitCrack (PID: {process.pid}) 已启动。日志: tail -f {log_file_path}")
            process.wait()

        print(f"\n[GPU-WORKER] BitCrack 进程 (PID: {process.pid}) 已退出，返回码: {process.returncode}")
        if process.returncode != 0: print(f"⚠️ BitCrack 异常退出！请检查日志: {log_file_path}")
        
        if os.path.exists(found_file_path) and os.path.getsize(found_file_path) > 0:
            with open(found_file_path, 'r') as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        found_key = parts[1]
                        print(f"\n🎉🎉🎉 [GPU-WORKER] 在文件中找到密钥: {found_key}！🎉🎉🎉")
                        final_result = {'found': True, 'private_key': found_key}
                        break
        
        if not final_result['found']: print("[GPU-WORKER] 范围搜索完毕但未在文件中找到密钥。")

    except FileNotFoundError:
        print(f"\n[致命错误] 程序文件未找到: {BITCRACK_PATH}。"); final_result['error'] = True
    except Exception as e:
        print(f"\n[致命错误] 执行 BitCrack 任务时发生错误: {e}"); final_result['error'] = True
    finally:
        if process:
            if process_info in processes_to_cleanup: processes_to_cleanup.remove(process_info)
            if process.poll() is None:
                try: process.kill()
                except: pass
        print(f"[GPU-WORKER] 任务清理完成。工作目录保留在: {task_work_dir}")
        result_container['result'] = final_result


# ==============================================================================
# --- 6. 主控制器逻辑 (V3 - 并行调度) ---
# ==============================================================================

def main():
    """
    [新代码注释] (V3 修改)
    主控制器函数，现在作为并行任务调度器。
    它管理 CPU 和 GPU 的任务“槽”，一旦有空闲就为其分配新任务。
    """
    client_id = f"btc-controller-{uuid.uuid4().hex[:8]}"
    print(f"控制器启动 (并行模式)，客户端 ID: {client_id}")
    os.makedirs(BASE_WORK_DIR, exist_ok=True)
    
    hardware = detect_hardware()
    
    session = requests.Session()
    session.headers.update(BROWSER_HEADERS)

    # [新代码注释] 为每个计算单元（GPU/CPU）创建一个状态跟踪字典
    gpu_task_slot = {'thread': None, 'work': None, 'result_container': None}
    cpu_task_slot = {'thread': None, 'work': None, 'result_container': None}

    try:
        while True:
            # --- GPU 任务槽管理 ---
            if hardware['has_gpu']:
                # 检查GPU任务是否已完成
                if gpu_task_slot['thread'] and not gpu_task_slot['thread'].is_alive():
                    print_header("GPU 任务完成")
                    result = gpu_task_slot['result_container'].get('result', {'found': False})
                    if not result.get('error'):
                        submit_result(session, gpu_task_slot['work']['address'], result.get('found', False), result.get('private_key'))
                    # 标记任务槽为空闲
                    gpu_task_slot['thread'] = None; gpu_task_slot['work'] = None

                # 如果GPU任务槽空闲，则分配新任务
                if not gpu_task_slot['thread']:
                    print_header("请求新的 GPU 任务")
                    work_unit = get_work_with_retry(session, f"{client_id}-GPU")
                    if work_unit:
                        gpu_task_slot['work'] = work_unit
                        gpu_task_slot['result_container'] = {}
                        thread = threading.Thread(target=run_gpu_task, args=(work_unit, hardware['gpu_params'], gpu_task_slot['result_container']))
                        gpu_task_slot['thread'] = thread
                        thread.start()
                    else:
                        print("未能获取GPU任务，稍后重试...")

            # --- CPU 任务槽管理 ---
            # 检查CPU任务是否已完成
            if cpu_task_slot['thread'] and not cpu_task_slot['thread'].is_alive():
                print_header("CPU 任务完成")
                result = cpu_task_slot['result_container'].get('result', {'found': False})
                if not result.get('error'):
                    submit_result(session, cpu_task_slot['work']['address'], result.get('found', False), result.get('private_key'))
                # 标记任务槽为空闲
                cpu_task_slot['thread'] = None; cpu_task_slot['work'] = None
            
            # 如果CPU任务槽空闲，则分配新任务
            if not cpu_task_slot['thread']:
                print_header("请求新的 CPU 任务")
                work_unit = get_work_with_retry(session, f"{client_id}-CPU")
                if work_unit:
                    cpu_task_slot['work'] = work_unit
                    cpu_task_slot['result_container'] = {}
                    thread = threading.Thread(target=run_cpu_task, args=(work_unit, hardware['cpu_threads'], cpu_task_slot['result_container']))
                    cpu_task_slot['thread'] = thread
                    thread.start()
                else:
                    print("未能获取CPU任务，稍后重试...")

            # [新代码注释] 短暂休眠，防止主循环空转消耗过多CPU
            time.sleep(5)

    except KeyboardInterrupt:
        print("\n[CONTROLLER] 检测到用户中断 (Ctrl+C)。将执行最终清理后退出。")
    except Exception as e:
        print(f"\n[CONTROLLER FATAL ERROR] 主循环发生无法恢复的错误: {e}")
        import traceback; traceback.print_exc()
    finally:
        print("[CONTROLLER] 脚本正在关闭...")

if __name__ == '__main__':
    if not os.path.exists(KEYHUNT_PATH) or not os.path.exists(BITCRACK_PATH):
        print("="*60); print("!! 启动错误: 关键程序路径未找到 !!")
        print(f"  请检查 KEYHUNT_PATH: '{KEYHUNT_PATH}' 是否存在。")
        print(f"  请检查 BITCRACK_PATH: '{BITCRACK_PATH}' 是否存在。")
        print("="*60); sys.exit(1)
        
    main()
