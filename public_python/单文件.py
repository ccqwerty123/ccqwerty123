from flask import Flask, render_template, request, jsonify
import threading
import queue
import json
import re
import os
import time
import uuid
import paho.mqtt.client as paho
from paho.mqtt.properties import Properties
from paho.mqtt.packettypes import PacketTypes
from datetime import datetime, timedelta

app = Flask(__name__)

# 全局变量 (保持不变)
task_queue = queue.Queue()
results_file = "results.json"
worker_lock = threading.Lock()
worker_thread = None
mqtt_client = None
current_task = None

DEFAULT_DURATION = 10 * 3600
INITIAL_SEND_INTERVAL = 10
MAX_SEND_INTERVAL = 3600
MIN_DURATION = 0
MAX_DURATION = 72

worker_status = "stopped"
current_task_id = None
next_retry_time = None
in_progress = False
mqtt_status_str = "not initialized"

# MQTT设置 (保持不变)
BROKER = "broker.emqx.io"
PORT = 8084
TOPIC = "jd/cookie/tasks"
ACK_TOPIC = "jd/cookie/tasks/ack"
CLIENT_ID = f"app-client-{str(uuid.uuid4())[:8]}"
MESSAGE_EXPIRY_INTERVAL = 60

# 加密映射 (保持不变)
encryption_mapping = {
    '0': 'a', '1': 'b', '2': 'c', '3': 'd', '4': 'e',
    '5': 'f', '6': 'g', '7': 'h', '8': 'i', '9': 'j',
    'a': '0', 'b': '1', 'c': '2', 'd': '3', 'e': '4',
    'f': '5', 'g': '6', 'h': '7', 'i': '8', 'j': '9'
}
reverse_mapping = {v: k for k, v in encryption_mapping.items()}

# 状态映射 (保持不变)
status_mapping = {
    "pending": "待处理",
    "retrying": "重试中",
    "success": "成功",
    "failed": "失败",
}

def simple_encrypt(text):
    return ''.join(encryption_mapping.get(c, c) for c in text)

def simple_decrypt(encrypted_text):
    return ''.join(reverse_mapping.get(c, c) for c in encrypted_text)

def log(message):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}")

def on_connect(client, userdata, flags, rc, properties=None):
    global worker_status, mqtt_status_str
    if rc == 0:
        log("MQTT Connected")
        client.subscribe(ACK_TOPIC, qos=1)
        worker_status = "idle"
        mqtt_status_str = "connected"
    else:
        log(f"MQTT Connection failed: {rc}")
        worker_status = "connecting"
        mqtt_status_str = "disconnected"

def on_message(client, userdata, msg):
    global worker_status, current_task_id, next_retry_time, in_progress, current_task
    log(f"on_message: Received message on topic {msg.topic}: {msg.payload.decode()}")
    try:
        ack_data = json.loads(msg.payload.decode())
        task_id = ack_data.get("task_id")

        if current_task and task_id == current_task["task_id"]:
            log(f"on_message: Task {task_id} completed successfully")
            update_task_status(current_task, "success")
            in_progress = False
            worker_status = "idle"
            current_task_id = None
            next_retry_time = None
            current_task = None
            task_queue.task_done()
            if task_queue.empty():
                shutdown_worker()

        else:
            log(f"on_message: Warning: Received confirmation for unknown or already completed task_id: {task_id}")

    except Exception as e:
        log(f"on_message: Error processing message: {e}")

def connect_mqtt():
    global mqtt_client, worker_status, mqtt_status_str
    log("Connecting to MQTT...")
    if mqtt_client:
        try:
            if mqtt_client.is_connected():
                mqtt_client.disconnect()
            mqtt_client.loop_stop()
            log("connect_mqtt: Old MQTT client disconnected and stopped.")
        except Exception as e:
            log(f"connect_mqtt: Error disconnecting old client: {e}")
        finally:
            mqtt_client = None

    worker_status = "connecting"
    mqtt_status_str = "connecting"

    try:
        mqtt_client = paho.Client(client_id=CLIENT_ID, transport="websockets", protocol=paho.MQTTv5)
        mqtt_client.ws_set_options(path="/mqtt")
        mqtt_client.tls_set()
        mqtt_client.on_connect = on_connect
        mqtt_client.on_message = on_message
        mqtt_client.connect(BROKER, PORT, keepalive=60)
        mqtt_client.loop_start()
        mqtt_status_str = "connected"
        return True
    except Exception as e:
        log(f"MQTT Connection failed: {e}")
        worker_status = "failed"
        mqtt_status_str = "disconnected"
        return False

def send_task(task):
    global mqtt_client, worker_status, current_task_id

    if mqtt_client is None or not mqtt_client.is_connected():
        log("send_task: MQTT not connected, attempting to connect...")
        if not connect_mqtt():
            log("send_task: Failed to connect to MQTT")
            return False

    task_id = task["task_id"]
    encrypted_pt_key = simple_encrypt(task["pt_key"])
    encrypted_pt_pin = simple_encrypt(task["pt_pin"])

    data = {
        "task_id": task_id,
        "remark": task["remark"],
        "pt_key": encrypted_pt_key,
        "pt_pin": encrypted_pt_pin,
        "timestamp": task["timestamp_str"],
    }
    message = json.dumps(data)

    properties = Properties(PacketTypes.PUBLISH)
    properties.MessageExpiryInterval = MESSAGE_EXPIRY_INTERVAL

    try:
        result = mqtt_client.publish(TOPIC, message, qos=1, properties=properties)
        if result.rc == paho.MQTT_ERR_SUCCESS:
            log(f"send_task: Task {task_id} sent")
            current_task_id = task_id
            return True
        else:
            log(f"send_task: Failed to send task: {result.rc}")
            return False
    except Exception as e:
        log(f"send_task: Error sending task: {e}")
        return False

def load_results():
    try:
        with open(results_file, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_results(task):
    with worker_lock:
        results = load_results()
        results[task['task_id']] = task
        with open(results_file, "w") as f:
            json.dump(results, f, indent=4)

def extract_and_validate_cookie(jd_cookie):
    pt_key_match = re.search(r"pt_key=([^;]+)", jd_cookie)
    pt_pin_match = re.search(r"pt_pin=([^;]+)", jd_cookie)
    if pt_key_match and pt_pin_match:
        pt_key = pt_key_match.group(1)
        pt_pin = pt_pin_match.group(1)
        return f"pt_key={pt_key}; pt_pin={pt_pin};", pt_key, pt_pin
    return None, None, None

def update_task_status(task, new_status):
    task["status"] = new_status
    save_results(task)

def check_duplicate_task(pt_key):
    """检查是否有重复任务（内存中或已成功的）"""
    # 检查当前任务
    if current_task and current_task["pt_key"] == pt_key and current_task["status"] in ["pending", "retrying"]:
        return True
    # 检查 results.json 中的成功任务
    results = load_results()
    for task_data in results.values():
        if task_data.get("pt_key") == pt_key and task_data.get("status") == "success":
            return True
    return False
def shutdown_worker():
    global worker_thread, worker_status
    if worker_thread and worker_thread.is_alive():
        log("Shutting down worker thread...")
        task_queue.put("stop")
        worker_thread.join()
        worker_thread = None
        worker_status = "stopped"
        log("Worker thread stopped.")
    else:
        log("Worker thread already stopped.")

def process_queue():
    global worker_status, current_task_id, next_retry_time, in_progress, current_task
    log("Worker thread started")
    worker_status = "idle"
    while True:
        try:
            task = task_queue.get(timeout=5)

            if task == "stop":
                log("process_queue: Received stop signal")
                break

            current_task_id = task["task_id"]
            current_task = task
            worker_status = "processing"
            log(f"process_queue: Processing task: {task['task_id']}")

            now = time.time()

            if now > task["end_time"]:
                log(f"process_queue: Task {task['task_id']} timed out")
                update_task_status(task, "failed")
                task_queue.task_done()
                worker_status = "idle"
                current_task_id = None
                in_progress = False
                current_task = None
                continue

            if task.get("next_send_time") is None or now >= task["next_send_time"]:
                if send_task(task):
                    update_task_status(task, "retrying")
                else:
                    if "send_attempts" not in task:
                        task["send_attempts"] = 0
                    task["send_attempts"] += 1
                    interval = min(INITIAL_SEND_INTERVAL * (2 ** task["send_attempts"]), MAX_SEND_INTERVAL)
                    task["next_send_time"] = now + interval
                    next_retry_time = task["next_send_time"]
                    log(f"process_queue: Task {task['task_id']} next send in {interval} seconds")
                    update_task_status(task, "retrying")

                    if task["next_send_time"] > task["end_time"]:
                        log(f"process_queue: Task {task['task_id']} failed (exceeded end time)")
                        update_task_status(task, "failed")
                        task_queue.task_done()
                        in_progress = False
                        current_task = None
                        continue

        except queue.Empty:
            if worker_status != "stopped":
                worker_status = "idle"
            time.sleep(1)
        except Exception as e:
            log(f"process_queue: Error in worker thread: {e}")
            time.sleep(1)
    log("Worker thread exiting.")
    worker_status = "stopped"

def start_worker():
    global worker_thread
    # 启动前确保旧的 worker 已关闭
    shutdown_worker()  # 先尝试关闭可能存在的旧 worker
    if worker_thread is None or not worker_thread.is_alive():
        worker_thread = threading.Thread(target=process_queue, daemon=True)
        worker_thread.start()

@app.route("/jd", methods=["GET", "POST"])
def index():
    global in_progress
    if request.method == "POST":
        # 更严格的 in_progress 检查
        if in_progress:
            return jsonify({"error": "已有任务正在进行中，请稍后再试"}), 429

        jd_cookie = request.form.get("jd_cookie", "").strip()
        remark = request.form.get("remark", "").strip()
        option = request.form.get("option", "").strip()
        duration_str = request.form.get("duration", str(DEFAULT_DURATION // 3600)).strip()

        if not jd_cookie:
            return jsonify({"error": "JD Cookie 不能为空"}), 400
        if len(jd_cookie) > 300 or len(remark) > 30 or len(option) > 30:
            return jsonify({"error": "输入长度超过限制"}), 400

        try:
            duration = int(duration_str)
            if not MIN_DURATION <= duration <= MAX_DURATION:
                raise ValueError(f"Duration must be between {MIN_DURATION} and {MAX_DURATION}")
            duration_seconds = duration * 3600
        except ValueError as e:
            return jsonify({"error": f"发送时长必须是 {MIN_DURATION} 到 {MAX_DURATION} 之间的整数（小时）"}), 400

        formatted_cookie, pt_key, pt_pin = extract_and_validate_cookie(jd_cookie)
        if not formatted_cookie:
            return jsonify({"error": "Cookie 格式错误"}), 400

        # 检查重复任务 (包括内存中和已成功的)
        if check_duplicate_task(pt_key):
            return jsonify({"error": "任务已存在或已成功提交"}), 400

        # 检查是否是失败的任务,如果是,则可以重新提交
        results = load_results()
        for task_data in results.values():
            if task_data.get("pt_key") == pt_key and task_data.get("status") == "failed":
                # 可以重新提交,不做操作.
                break
        else: # 如果没有找到失败的任务,且任务已存在或已成功提交,则返回错误
             if check_duplicate_task(pt_key):
                return jsonify({"error": "任务已存在或已成功提交"}), 400
        task_id = str(uuid.uuid4())
        now = time.time()
        timestamp_str = time.strftime("%Y-%m-%d %H:%M:%S")
        end_time = now + duration_seconds

        in_progress = True

        task = {
            "task_id": task_id,
            "status": "pending",
            "remark": remark,
            "pt_key": pt_key,
            "pt_pin": pt_pin,
            "timestamp": timestamp_str,
            "timestamp_str": timestamp_str,
            "end_time": end_time,
            "next_send_time": now,
        }
        task_queue.put(task)

        start_worker()
        return jsonify({"message": "任务已提交!", "task_id": task_id}), 200

    return render_template("index.html")

@app.route("/jd/status", methods=["GET"])
def status():
    pt_key_query = request.args.get("pt_key")
    pt_pin_query = request.args.get("pt_pin")
    remark_query = request.args.get("remark")

    if not pt_key_query and not pt_pin_query and not remark_query:
        return jsonify({"error": "请提供 pt_key、pt_pin 或 remark 进行查询"}), 400

    results = load_results()
    matching_tasks = [
        task_data for task_data in results.values()
        if (pt_key_query and task_data.get("pt_key") == pt_key_query) or
           (pt_pin_query and task_data.get("pt_pin") == pt_pin_query) or
           (remark_query and task_data.get("remark") == remark_query)
    ]

    if matching_tasks:
        response_data = [
            {
                "status": status_mapping.get(task["status"], "未知状态"),
                "remark": task.get("remark", ""),
                "timestamp": task.get("timestamp"),
            }
            for task in matching_tasks
        ]
        return jsonify(response_data), 200
    else:
        return jsonify({"error": "未找到该任务"}), 404

@app.route("/mqtt_status")
def mqtt_status():
    global worker_status, current_task_id, next_retry_time, mqtt_status_str

    if mqtt_client:
        if mqtt_client.is_connected():
            mqtt_status_str = "connected"
        else:
            mqtt_status_str = "disconnected"
    else:
        mqtt_status_str = "not initialized"

    pending_count = 1 if current_task and current_task["status"] != "success" else 0

    status_info = {
        "mqtt_status": mqtt_status_str,
        "worker_status": worker_status,
        "current_task_id": current_task_id,
        "pending_messages_count": pending_count,
        "in_progress": in_progress,
        "next_retry_time": next_retry_time if next_retry_time is None else datetime.fromtimestamp(next_retry_time).strftime('%Y-%m-%d %H:%M:%S')
    }
    return jsonify(status_info)

@app.route('/restart', methods=['GET'])
def restart_mqtt():
    global mqtt_client, worker_status, in_progress, mqtt_status_str

    if mqtt_client is not None:
        try:
            if mqtt_client.is_connected():
                mqtt_client.disconnect()
            mqtt_client.loop_stop()
            log("已断开并停止旧的MQTT客户端")
        except Exception as e:
            log(f"清理旧MQTT客户端时出错: {e}")
        finally:
            mqtt_client = None

    in_progress = False
    worker_status = "idle"
    mqtt_status_str = "not initialized"

    if connect_mqtt():
        return jsonify({"status": "success", "message": "MQTT客户端已重启"})
    else:
        return jsonify({"status": "error", "message": "MQTT客户端重启失败"}), 500

@app.route('/stop', methods=['GET'])
def stop_all():
    global mqtt_client, in_progress, mqtt_status_str

    shutdown_worker()

    if mqtt_client:
        try:
            if mqtt_client.is_connected():
                mqtt_client.disconnect()
            mqtt_client.loop_stop()
            log("MQTT client disconnected and stopped.")
        except Exception as e:
            log(f"Error disconnecting MQTT client: {e}")
        finally:
            mqtt_client = None

    in_progress = False
    mqtt_status_str = "stopped"
    return jsonify({"message": "Worker and MQTT stopped."})

if __name__ == "__main__":
    if not os.path.exists(results_file):
        with open(results_file, "w") as f:
            json.dump({}, f)
    app.run(debug=True)