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

# 全局变量
task_queue = queue.Queue()
results_file = "results.json"
worker_lock = threading.Lock()
worker_thread = None
mqtt_client = None
pending_messages = {}

DEFAULT_DURATION = 10 * 3600
INITIAL_SEND_INTERVAL = 10
MAX_SEND_INTERVAL = 3600
MIN_DURATION = 0
MAX_DURATION = 72

worker_status = "idle"
current_task_id = None
next_retry_time = None

# MQTT设置
BROKER = "broker.emqx.io"
PORT = 8084
TOPIC = "jd/cookie/tasks"
ACK_TOPIC = "jd/cookie/tasks/ack"
CLIENT_ID = f"app-client-{str(uuid.uuid4())[:8]}"
MESSAGE_EXPIRY_INTERVAL = 60

# 加密映射
encryption_mapping = {
    '0': 'a', '1': 'b', '2': 'c', '3': 'd', '4': 'e',
    '5': 'f', '6': 'g', '7': 'h', '8': 'i', '9': 'j',
    'a': '0', 'b': '1', 'c': '2', 'd': '3', 'e': '4',
    'f': '5', 'g': '6', 'h': '7', 'i': '8', 'j': '9'
}
reverse_mapping = {v: k for k, v in encryption_mapping.items()}

# 状态映射
status_mapping = {
    "pending": "待处理",
    "sent": "已发送",
    "success": "成功",
    "failed": "失败",
}

def simple_encrypt(text):
    return ''.join(encryption_mapping.get(c, c) for c in text)

def simple_decrypt(encrypted_text):
    return ''.join(reverse_mapping.get(c, c) for c in encrypted_text)

def log(message):
    """带时间戳的日志函数"""
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}")

def on_connect(client, userdata, flags, rc, properties=None):
    global worker_status
    if rc == 0:
        log("MQTT Connected")
        client.subscribe(ACK_TOPIC, qos=1)
        worker_status = "idle"
    else:
        log(f"MQTT Connection failed: {rc}")
        worker_status = "connecting"

def on_message(client, userdata, msg):
    global worker_status, current_task_id, next_retry_time
    log(f"on_message: Received message on topic {msg.topic}: {msg.payload.decode()}")
    try:
        ack_data = json.loads(msg.payload.decode())
        task_id = ack_data.get("task_id")

        if task_id in pending_messages:
            with worker_lock:
                results = load_results()
                if task_id in results:
                    results[task_id]["status"] = "success"
                    save_results(results)
                    log(f"on_message: Task {task_id} completed successfully")
                else:
                    log(f"on_message: Warning: Received confirmation for unknown task_id: {task_id}")
                del pending_messages[task_id]
            worker_status = "idle"  # 确认成功，worker 变为空闲
            current_task_id = None  # 清空当前任务 ID
            next_retry_time = None
        else:
            log(f"on_message: Warning: Received confirmation for unknown task_id: {task_id}")

    except Exception as e:
        log(f"on_message: Error processing message: {e}")

def connect_mqtt():
    global mqtt_client, worker_status
    log("Connecting to MQTT...")
    worker_status = "connecting"
    # 检查是否已经连接
    if mqtt_client and mqtt_client.is_connected():
        log("connect_mqtt: MQTT already connected, skipping connection attempt.")
        return True

    try:
        mqtt_client = paho.Client(client_id=CLIENT_ID, transport="websockets", protocol=paho.MQTTv5)
        mqtt_client.ws_set_options(path="/mqtt")
        mqtt_client.tls_set()
        mqtt_client.on_connect = on_connect
        mqtt_client.on_message = on_message
        mqtt_client.connect(BROKER, PORT, keepalive=60)
        mqtt_client.loop_start()
        time.sleep(2)
        log("MQTT Connected")
        return True
    except Exception as e:
        log(f"MQTT Connection failed: {e}")
        worker_status = "failed"
        return False

def send_task(task):
    global mqtt_client, worker_status, current_task_id
    # 在每次发送前检查连接状态
    if mqtt_client is None or not mqtt_client.is_connected():
        log("send_task: MQTT not connected, attempting to connect...")
        worker_status = "connecting"
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
            pending_messages[task_id] = True  # task_id 加入待确认列表
            log(f"send_task: Task {task_id} sent")
            worker_status = "waiting"
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

def save_results(results):
    with worker_lock:
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

def check_duplicate_task(pt_key, results):
    encrypted_pt_key = simple_encrypt(pt_key)
    for data in results.values():
        if data.get("pt_key") == encrypted_pt_key and data.get("status") in ["pending", "sent", "success"]:
            return True
    return False

def process_queue():
    global worker_status, current_task_id, next_retry_time
    log("Worker thread started")
    while True:
        try:
            task = task_queue.get(timeout=5)
            current_task_id = task["task_id"]
            worker_status = "processing"
            log(f"process_queue: Processing task: {task['task_id']}")

            now = time.time()

            if now > task["end_time"]:
                with worker_lock:
                    results = load_results()
                    if task["task_id"] in results:
                        results[task["task_id"]]["status"] = "failed"
                        save_results(results)
                log(f"process_queue: Task {task['task_id']} timed out")
                task_queue.task_done()
                worker_status = "idle"
                current_task_id = None
                continue

            if task.get("next_send_time") is None or now >= task["next_send_time"]:
                if send_task(task):
                    with worker_lock:
                        results = load_results()
                        results[task["task_id"]]["status"] = "sent"
                        save_results(results)
                    task["next_send_time"] = None  # 等待确认

                else:
                    if "send_attempts" not in task:
                        task["send_attempts"] = 0
                    task["send_attempts"] += 1
                    interval = min(INITIAL_SEND_INTERVAL * (2 ** task["send_attempts"]), MAX_SEND_INTERVAL)
                    task["next_send_time"] = now + interval
                    next_retry_time = task["next_send_time"]
                    log(f"process_queue: Task {task['task_id']} next send in {interval} seconds")

                    if task["next_send_time"] > task["end_time"]:
                         with worker_lock:
                            results = load_results()
                            if task["task_id"] in results:
                                results[task["task_id"]]["status"] = "failed"
                                save_results(results)
                                log(f"process_queue: Task {task['task_id']} failed (exceeded end time)")
            else:
                # 还没到下次发送时间, worker 状态仍然是 waiting, 什么也不做
                pass

            task_queue.task_done()
            task_queue.put(task)  # 无论如何都将任务放回队列
            cleanup_pending_messages()
            time.sleep(1)

        except queue.Empty:
            worker_status = "idle"
            current_task_id = None
            next_retry_time = None
            cleanup_pending_messages()
            time.sleep(1)
        except Exception as e:
            log(f"process_queue: Error in worker thread: {e}")
            time.sleep(1)

def cleanup_pending_messages():
    now = time.time()
    with worker_lock:
        results = load_results()
        for task_id in list(pending_messages.keys()):
            task = results.get(task_id)
            if task:
                timestamp_str = task.get("timestamp")
                if timestamp_str:
                    timestamp_datetime = datetime.strptime(timestamp_str, "%Y-%m-%d %H:%M:%S")
                    timestamp = timestamp_datetime.timestamp()
                    if now - timestamp > 60:
                        task["status"] = "failed"
                        log(f"cleanup_pending_messages: Task {task_id} marked as failed due to timeout")
                        del pending_messages[task_id]
                else:
                    log(f"cleanup_pending_messages: Warning: Task {task_id} does not have a timestamp.")
            else:
                log(f"cleanup_pending_messages: Warning: No matching task found for task_id {task_id} in cleanup.")

        save_results(results)

def start_worker():
    global worker_thread
    if worker_thread is None or not worker_thread.is_alive():
        worker_thread = threading.Thread(target=process_queue, daemon=True)
        worker_thread.start()

@app.route("/jd", methods=["GET", "POST"])
def index():
    if request.method == "POST":
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

        results = load_results()
        if check_duplicate_task(pt_key, results):
            return jsonify({"error": "任务已存在"}), 400

        encrypted_pt_key = simple_encrypt(pt_key)
        for k, data in list(results.items()):
            if data.get("pt_key") == encrypted_pt_key and data.get("status") == "failed":
                del results[k]

        task_id = str(uuid.uuid4())
        now = time.time()
        timestamp_str = time.strftime("%Y-%m-%d %H:%M:%S")
        end_time = now + duration_seconds

        results[task_id] = {
            "task_id": task_id,
            "status": "pending",
            "remark": remark,
            "pt_key": simple_encrypt(pt_key),
            "pt_pin": simple_encrypt(pt_pin),
            "timestamp": timestamp_str,
            "end_time": end_time,
        }
        save_results(results)

        task_queue.put({
            "task_id": task_id,
            "jd_cookie": formatted_cookie,
            "remark": remark,
            "option": option,
            "pt_key": pt_key,
            "pt_pin": pt_pin,
            "timestamp_str": timestamp_str,
            "next_send_time": now,
            "end_time": end_time,
        })

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
    matching_tasks = []

    for task_data in results.values():
        if pt_key_query and task_data.get("pt_key") == simple_encrypt(pt_key_query):
            matching_tasks.append(task_data)
        elif pt_pin_query and task_data.get("pt_pin") == simple_encrypt(pt_pin_query):
            matching_tasks.append(task_data)
        elif remark_query and task_data.get("remark") == remark_query:
            matching_tasks.append(task_data)

    if matching_tasks:
        response_data = []
        for task in matching_tasks:
            response_data.append({
                "status": status_mapping.get(task["status"], "未知状态"),
                "remark": task.get("remark", ""),
                "timestamp": task["timestamp"],
            })
        return jsonify(response_data), 200
    else:
        return jsonify({"error": "未找到该任务"}), 404

@app.route("/mqtt_status")
def mqtt_status():
    global worker_status, current_task_id, next_retry_time

    if mqtt_client:
        if mqtt_client.is_connected():
            mqtt_status_str = "connected"
        else:
            mqtt_status_str = "disconnected"
    else:
        mqtt_status_str = "not initialized"

    status_info = {
        "mqtt_status": mqtt_status_str,
        "worker_status": worker_status,
        "current_task_id": current_task_id,
        "pending_messages_count": len(pending_messages),
        "next_retry_time": next_retry_time if next_retry_time is None else datetime.fromtimestamp(next_retry_time).strftime('%Y-%m-%d %H:%M:%S')
    }
    return jsonify(status_info)

if __name__ == "__main__":
    if not os.path.exists(results_file):
        save_results({})
    if not connect_mqtt():
        log("Initial MQTT connection failed")
    start_worker()
    app.run(debug=True)