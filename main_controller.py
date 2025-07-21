#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
BTC 自动化挖矿总控制器 (V2 - 安静模式)

该脚本整合了 API通信、CPU(KeyHunt)挖矿 和 GPU(BitCrack)挖矿三大功能，实现全自动工作流程：
1.  通过 API 从中央服务器获取工作单元（BTC地址 + 密钥范围）。
2.  自动检测本机硬件（优先使用 NVIDIA GPU，若无则使用 CPU）。
3.  将任务分配给相应的挖矿程序 (cuBitCrack for GPU, KeyHunt for CPU)。
4.  在独立的、无窗口的后台模式下执行和监控任务。
5.  对进程进行严格管理，确保任务结束或找到密钥后，子进程被彻底清理。
6.  [V2 更新] BitCrack 的详细输出将被重定向到日志文件，保持主控台清洁。
7.  将结果（找到密钥 或 范围搜索完成）提交回服务器。
8.  循环执行以上步骤。

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
    # 从列表副本进行迭代，因为列表可能在其他地方被修改
    for p_info in list(processes_to_cleanup):
        p = p_info['process']
        if p.poll() is None:  # 如果进程仍在运行
            print(f"  -> 正在终止进程 PID: {p.pid} ({p_info['name']})...")
            try:
                p.terminate() # 发送 SIGTERM，让进程有机会优雅退出
                p.wait(timeout=3) # 等待3秒
            except (psutil.NoSuchProcess, subprocess.TimeoutExpired):
                if p.poll() is None: # 再次检查
                    try:
                        print(f"  -> 进程 PID: {p.pid} 未能优雅退出，强制终止 (kill)...")
                        p.kill() # 发送 SIGKILL，强制终止
                        p.wait(timeout=2)
                    except Exception as e:
                        print(f"  -> 强制终止 PID: {p.pid} 时出错: {e}")
            except Exception as e:
                print(f"  -> 终止 PID: {p.pid} 时发生意外错误: {e}")
    print("[CONTROLLER CLEANUP] 清理完成。")

# [新代码注释] 程序启动时就注册这个清理函数，保证在任何出口（正常结束, Ctrl+C, 异常）都会被调用。
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
    [新代码注释]
    此函数现在是主控制器获取任务的唯一入口。
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
        # [原始注释] 私钥处理等原始代码没有问题，请不要随意变更代码
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
    [新代码注释]
    统一的硬件检测函数。
    首先检查NVIDIA GPU，如果存在，则返回GPU模式所需的信息。
    如果失败，则回退到CPU模式。
    """
    print_header("硬件自检")
    
    # 尝试检测 GPU
    try:
        cmd = ['nvidia-smi', '--query-gpu=name,multiprocessor_count', '--format=csv,noheader,nounits']
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=5)
        gpu_name, sm_count_str = result.stdout.strip().split(', ')
        
        if not sm_count_str.isdigit():
            raise ValueError(f"nvidia-smi 返回了非预期的 SM Count: '{sm_count_str}'")

        sm_count = int(sm_count_str)
        blocks, threads, points = sm_count * 7, 256, 1024
        
        gpu_params = {'blocks': blocks, 'threads': threads, 'points': points}
        print(f"✅ GPU模式激活: 检测到 {gpu_name} (SM: {sm_count})")
        print(f"   自动配置BitCrack参数: -b {blocks} -t {threads} -p {points}")
        return {'mode': 'gpu', 'params': gpu_params}

    except FileNotFoundError:
        print("⚠️ 未找到 'nvidia-smi' 命令。将使用 CPU 模式。")
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as e:
        print(f"⚠️ GPU 检测失败 (原因: {e})。将使用 CPU 模式。")
    except Exception as e:
        print(f"⚠️ GPU 检测时发生未知错误 (原因: {e})。将使用 CPU 模式。")

    # 如果GPU检测失败，则配置CPU
    try:
        cpu_cores = os.cpu_count()
        threads = max(1, cpu_cores - 1 if cpu_cores > 1 else 1)
        print(f"✅ CPU模式激活: 检测到 {cpu_cores} 个CPU核心，将为 KeyHunt 分配 {threads} 个线程。")
        return {'mode': 'cpu', 'threads': threads}
    except Exception as e:
        print(f"⚠️ 无法自动检测CPU核心数，使用默认值 15。错误: {e}")
        return {'mode': 'cpu', 'threads': 15}


def run_cpu_task(work_unit, num_threads):
    """
    [新代码注释]
    执行 KeyHunt (CPU) 任务的函数。
    它在后台启动 keyhunt 进程，并实时监控其标准输出以捕获密钥，同时在主控台显示简略进度。
    """
    address = work_unit['address']
    start_key, end_key = work_unit['range']['start'], work_unit['range']['end']
    print(f"[CPU-TASK] 开始处理地址: {address}, 范围: {start_key} - {end_key}")
    
    task_work_dir = os.path.join(BASE_WORK_DIR, f"kh_{address[:10]}_{uuid.uuid4().hex[:6]}")
    os.makedirs(task_work_dir, exist_ok=True)
    kh_address_file = os.path.join(task_work_dir, 'target_address.txt')
    with open(kh_address_file, 'w') as f: f.write(address)

    command = [
        KEYHUNT_PATH, '-m', 'address', '-f', kh_address_file,
        '-l', 'both', '-t', str(num_threads), '-R', 
        '-r', f'{start_key}:{end_key}'
    ]
    
    process = None
    process_info = None
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8')
        process_info = {'process': process, 'name': 'KeyHunt'}
        processes_to_cleanup.append(process_info)
        print(f"[CPU-TASK] KeyHunt (PID: {process.pid}) 已启动，正在实时监控输出...")

        for line in iter(process.stdout.readline, ''):
            clean_line = line.strip()
            # [新代码注释] 只显示简洁的状态行，而不是所有输出
            if 'K/s' in clean_line or 'M/s' in clean_line:
                 sys.stdout.write(f"\r  [KeyHunt Status] {clean_line}")
                 sys.stdout.flush()
            
            match = KEYHUNT_PRIV_KEY_RE.search(line)
            if match:
                found_key = match.group(1).lower()
                print(f"\n🔔🔔🔔 [CPU-TASK] 实时捕获到密钥: {found_key}！🔔🔔🔔")
                print("[CPU-TASK] 任务成功，正在终止 KeyHunt 进程...")
                return {'found': True, 'private_key': found_key}

        # [新代码注释] 进程正常结束后，清除最后一行进度
        sys.stdout.write("\r" + " " * 80 + "\r") 
        sys.stdout.flush()
        print("[CPU-TASK] KeyHunt 进程已结束，范围搜索完毕但未找到密钥。")
        return {'found': False}

    except FileNotFoundError:
        print(f"\n[致命错误] 程序文件未找到: {KEYHUNT_PATH}。请检查配置。")
        return {'found': False, 'error': True}
    except Exception as e:
        print(f"\n[致命错误] 执行 KeyHunt 任务时发生错误: {e}")
        return {'found': False, 'error': True}
    finally:
        if process:
            if process_info and process_info in processes_to_cleanup:
                processes_to_cleanup.remove(process_info)
            if process.poll() is None:
                try: process.terminate(); process.wait(2)
                except: process.kill()
        shutil.rmtree(task_work_dir, ignore_errors=True)
        print(f"[CPU-TASK] 任务清理完成。")


def run_gpu_task(work_unit, gpu_params):
    """
    [新代码注释] (V2 修改)
    执行 BitCrack (GPU) 任务的函数。
    它在后台启动 cuBitCrack 进程，并将其所有输出（stdout/stderr）重定向到一个日志文件。
    主控台只显示简略信息和日志文件路径，不再被进度信息刷屏。
    """
    address = work_unit['address']
    keyspace = f"{work_unit['range']['start']}:{work_unit['range']['end']}"
    print(f"[GPU-TASK] 开始处理地址: {address}, 范围: {keyspace}")

    task_work_dir = os.path.join(BASE_WORK_DIR, f"bc_{address[:10]}_{uuid.uuid4().hex[:6]}")
    os.makedirs(task_work_dir, exist_ok=True)
    found_file_path = os.path.join(task_work_dir, 'found.txt')
    progress_file = os.path.join(task_work_dir, 'progress.dat')
    # [新代码注释] 为 BitCrack 的输出创建一个专用的日志文件
    log_file_path = os.path.join(task_work_dir, 'bitcrack_output.log')

    command = [
        BITCRACK_PATH, '-b', str(gpu_params['blocks']), '-t', str(gpu_params['threads']),
        '-p', str(gpu_params['points']), '--keyspace', keyspace, '-o', found_file_path,
        '--continue', progress_file, address
    ]
    
    process = None
    process_info = None
    try:
        # [新代码注释] 使用 "with open" 来安全地管理日志文件句柄
        with open(log_file_path, 'w') as log_file:
            print(f"[GPU-TASK] 正在启动 BitCrack 进程... ")
            # [新代码注释] 关键修改：将 stdout 和 stderr 都指向我们打开的日志文件
            process = subprocess.Popen(command, stdout=log_file, stderr=log_file)
            
            process_info = {'process': process, 'name': 'BitCrack'}
            processes_to_cleanup.append(process_info)
            
            print(f"[GPU-TASK] BitCrack (PID: {process.pid}) 已启动，正在后台运行。")
            print(f"           详细进度请查看日志: tail -f {log_file_path}")
            
            process.wait() # 等待子进程执行结束

        print(f"\n[GPU-TASK] BitCrack 进程 (PID: {process.pid}) 已退出，返回码: {process.returncode}")

        # [新代码注释] 检查 BitCrack 是否成功退出
        if process.returncode != 0:
            print(f"⚠️ [GPU-TASK] BitCrack 异常退出！请检查日志文件以获取详细错误信息: {log_file_path}")
            # 即使异常退出，也检查一下文件，以防万一在崩溃前找到了密钥
        
        if os.path.exists(found_file_path) and os.path.getsize(found_file_path) > 0:
            with open(found_file_path, 'r') as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        found_key = parts[1]
                        print(f"\n🎉🎉🎉 [GPU-TASK] 在文件中找到密钥: {found_key}！🎉🎉🎉")
                        return {'found': True, 'private_key': found_key}
        
        print("[GPU-TASK] 范围搜索完毕但未在文件中找到密钥。")
        return {'found': False}

    except FileNotFoundError:
        print(f"\n[致命错误] 程序文件未找到: {BITCRACK_PATH}。请检查配置。")
        return {'found': False, 'error': True}
    except Exception as e:
        print(f"\n[致命错误] 执行 BitCrack 任务时发生错误: {e}")
        return {'found': False, 'error': True}
    finally:
        if process:
            if process_info and process_info in processes_to_cleanup:
                processes_to_cleanup.remove(process_info)
            if process.poll() is None:
                try: process.kill()
                except: pass
        
        # [新代码注释] 任务结束后，可以选择保留或删除工作目录。暂时保留以便检查日志。
        # shutil.rmtree(task_work_dir, ignore_errors=True)
        print(f"[GPU-TASK] 任务清理完成。工作目录保留在: {task_work_dir}")


# ==============================================================================
# --- 6. 主控制器逻辑 ---
# ==============================================================================

def main():
    """
    [新代码注释]
    主控制器函数，负责整个自动化流程的编排。
    """
    client_id = f"btc-controller-{uuid.uuid4().hex[:8]}"
    print(f"控制器启动，本次运行客户端 ID: {client_id}")

    os.makedirs(BASE_WORK_DIR, exist_ok=True)
    
    hardware_info = detect_hardware()
    
    session = requests.Session()
    session.headers.update(BROWSER_HEADERS)

    try:
        while True:
            print_header("开始新的任务周期")
            
            work_unit = get_work_with_retry(session, client_id)
            if not work_unit:
                print("[CONTROLLER] 未能从服务器获取任务，将在 60 秒后重试...")
                time.sleep(60)
                continue

            result = None
            if hardware_info['mode'] == 'gpu':
                result = run_gpu_task(work_unit, hardware_info['params'])
            else:
                result = run_cpu_task(work_unit, hardware_info['threads'])
            
            if result.get('error'):
                print("[CONTROLLER] 任务执行失败，将在 30 秒后尝试获取下一个任务...")
                time.sleep(30)
                continue

            submit_result(
                session, 
                address=work_unit['address'], 
                found=result['found'], 
                private_key=result.get('private_key')
            )

            print("[CONTROLLER] 当前任务周期完成，10秒后将开始获取下一个任务...")
            time.sleep(10)

    except KeyboardInterrupt:
        print("\n[CONTROLLER] 检测到用户中断 (Ctrl+C)。将执行最终清理后退出。")
    except Exception as e:
        print(f"\n[CONTROLLER FATAL ERROR] 主循环发生无法恢复的错误: {e}")
        import traceback
        traceback.print_exc()
    finally:
        print("[CONTROLLER] 脚本正在关闭...")


if __name__ == '__main__':
    if not os.path.exists(KEYHUNT_PATH) or not os.path.exists(BITCRACK_PATH):
        print("="*60)
        print("!! 启动错误: 关键程序路径未找到 !!")
        print(f"  请检查 KEYHUNT_PATH: '{KEYHUNT_PATH}' 是否存在。")
        print(f"  请检查 BITCRACK_PATH: '{BITCRACK_PATH}' 是否存在。")
        print("="*60)
        sys.exit(1)
        
    main()
