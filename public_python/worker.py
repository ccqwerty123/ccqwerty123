import time
import json
import uuid
import paho.mqtt.client as paho
from paho.mqtt.properties import Properties
from paho.mqtt.packettypes import PacketTypes
import re

# MQTT Broker 设置
BROKER = "broker.emqx.io"
PORT = 8084
TOPIC = "jd/cookie/tasks"
ACK_TOPIC = "jd/cookie/tasks/ack"
CLIENT_ID = "worker-client"

# 加密 (只需要 simple_encrypt)
encryption_mapping = {
    '0': 'a', '1': 'b', '2': 'c', '3': 'd', '4': 'e',
    '5': 'f', '6': 'g', '7': 'h', '8': 'i', '9': 'j',
    'a': '0', 'b': '1', 'c': '2', 'd': '3', 'e': '4',
    'f': '5', 'g': '6', 'h': '7', 'i': '8', 'j': '9'
}
reverse_mapping = {v: k for k, v in encryption_mapping.items()}

def simple_encrypt(text):
    return ''.join(encryption_mapping.get(c, c) for c in text)
def simple_decrypt(encrypted_text):
    return ''.join(reverse_mapping.get(c, c) for c in encrypted_text)

def extract_and_validate_cookie(jd_cookie):
    pt_key_match = re.search(r"pt_key=([^;]+)", jd_cookie)
    pt_pin_match = re.search(r"pt_pin=([^;]+)", jd_cookie)
    if pt_key_match and pt_pin_match:
        return f"pt_key={pt_key_match.group(1)}; pt_pin={pt_pin_match.group(1)};", pt_key_match.group(1), pt_pin_match.group(1)
    return None, None, None

def run_worker(queue, update_status_callback):
    """worker 进程的主函数"""

    mqtt_client = None
    pending_messages = {}

    def on_connect(client, userdata, flags, rc, properties=None):
        if rc == 0:
            client.subscribe(ACK_TOPIC, qos=1)
        else:
            print(f"MQTT Connection failed: {rc}")

    def on_message(client, userdata, msg):
        try:
            ack_data = json.loads(msg.payload.decode())
            message_id = ack_data.get("message_id")
            remark = ack_data.get("remark")
            if message_id in pending_messages:
                expected_remark, _ = pending_messages[message_id]
                if remark == expected_remark:
                    update_status_callback(remark, "success")  # 调用回调
                    del pending_messages[message_id]
        except Exception as e:
            print(f"Error processing message: {e}")

    def connect_mqtt():
        nonlocal mqtt_client
        mqtt_client = paho.Client(client_id=CLIENT_ID, transport="websockets", protocol=paho.MQTTv5)
        mqtt_client.ws_set_options(path="/mqtt")
        mqtt_client.tls_set()
        mqtt_client.on_connect = on_connect
        mqtt_client.on_message = on_message
        mqtt_client.reconnect_delay_set(min_delay=1, max_delay=120)
        try:
            mqtt_client.connect(BROKER, PORT, keepalive=60)
            mqtt_client.loop_start()
            return True
        except Exception as e:
            print(f"MQTT Connection failed: {e}")
            return False

    def send_mqtt_message(data, remark):
        message_id = str(uuid.uuid4())
        data["message_id"] = message_id
        message = json.dumps(data)
        properties = Properties(PacketTypes.PUBLISH)
        properties.MessageExpiryInterval = 10

        try:
            result = mqtt_client.publish(TOPIC, message, qos=1, properties=properties)
            if result.rc != paho.MQTT_ERR_SUCCESS:
                return False
            pending_messages[message_id] = (remark, time.time())
            return True
        except Exception as e:
            print(f"Failed to send MQTT message: {e}")
            return False

    def process_task(task):
        _, pt_key, pt_pin = extract_and_validate_cookie(task["jd_cookie"])  # 使用 worker 中的函数
        encrypted_pt_key = simple_encrypt(pt_key)  # 使用 worker 中的函数
        encrypted_pt_pin = simple_encrypt(pt_pin)  # 使用 worker 中的函数
        return {
            "pt_key": encrypted_pt_key,
            "pt_pin": encrypted_pt_pin,
            "remark": task["remark"],
            "option": task["option"], # 增加上传选项
        }

    def cleanup_pending_messages():
        now = time.time()
        for message_id, (remark, timestamp) in list(pending_messages.items()):
            if now - timestamp > 60:
                update_status_callback(remark, "failed")  # 调用回调
                del pending_messages[message_id]

    if not connect_mqtt():
        return

    while True:
        try:
            task = queue.get(timeout=10)
            message_data = process_task(task)
            if send_mqtt_message(message_data, task["remark"]):
                pass  # 等待确认, 已在 on_message 中处理
            else:
                update_status_callback(task["remark"], "failed")  # 调用回调
            queue.task_done()

        except queue.Empty:
            time.sleep(1)  # 队列为空时稍作等待, 避免 CPU 占用过高
            continue       # 继续检查队列
        except Exception as e:
            print(f"An error occurred in worker: {e}")

        cleanup_pending_messages()

    mqtt_client.loop_stop()
    mqtt_client.disconnect()