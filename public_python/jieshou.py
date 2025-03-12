import paho.mqtt.client as paho
from paho.mqtt.properties import Properties
from paho.mqtt.packettypes import PacketTypes
import time
import json

# 加密映射 (与发布者相同)
encryption_mapping = {
    '0': 'a', '1': 'b', '2': 'c', '3': 'd', '4': 'e',
    '5': 'f', '6': 'g', '7': 'h', '8': 'i', '9': 'j',
    'a': '0', 'b': '1', 'c': '2', 'd': '3', 'e': '4',
    'f': '5', 'g': '6', 'h': '7', 'i': '8', 'j': '9'
}
reverse_mapping = {v: k for k, v in encryption_mapping.items()}

def simple_decrypt(encrypted_text):
    return ''.join(reverse_mapping.get(c, c) for c in encrypted_text)

# 定义回调函数
def on_connect(client, userdata, flags, reasonCode, properties=None):
    print(f"连接结果代码：{reasonCode}")
    if reasonCode == 0:
        print("成功连接到 Broker")
        # 订阅主题 jd/cookie/tasks
        client.subscribe("jd/cookie/tasks", qos=1)  # 修改为你的发布主题
    else:
        print("连接失败")

def on_disconnect(client, userdata, reasonCode, properties=None):
    print(f"断开连接，原因代码：{reasonCode}")
    if reasonCode != 0:
        print("意外断开，尝试重新连接...")

def on_message(client, userdata, msg):
    print(f"收到消息，主题：{msg.topic}")
    try:
        data = json.loads(msg.payload.decode())
        task_id = data.get("task_id")
        remark = data.get("remark", "")  # 获取备注
        encrypted_pt_key = data.get("pt_key")
        encrypted_pt_pin = data.get("pt_pin")

        if task_id and encrypted_pt_key and encrypted_pt_pin:
            pt_key = simple_decrypt(encrypted_pt_key)
            pt_pin = simple_decrypt(encrypted_pt_pin)
            print(f"  Task ID: {task_id}")
            print(f"  Remark: {remark}")  # 打印备注
            print(f"  解密后的 pt_key: {pt_key}")
            print(f"  解密后的 pt_pin: {pt_pin}")

            # 发送确认消息
            ack_message = json.dumps({"task_id": task_id})
            client.publish("jd/cookie/tasks/ack", ack_message, qos=1)  # 发送到确认主题
            print(f"  已发送确认消息，task_id: {task_id}")

        else:
            print("  消息格式错误，缺少必要字段")
    except json.JSONDecodeError:
        print("  消息不是有效的 JSON 格式")
    except Exception as e:
        print(f"  处理消息时发生错误: {e}")

def on_subscribe(client, userdata, mid, granted_qos, properties=None):
    print(f"成功订阅主题，QoS 等级：{granted_qos}")

# 重连函数 (保持不变)
def reconnect(client, broker, port, max_attempts=5, delay=5):
    attempt = 1
    while attempt <= max_attempts:
        try:
            print(f"尝试第 {attempt} 次重连...")
            client.reconnect()
            print("重连成功！")
            return True
        except Exception as e:
            print(f"重连失败，错误：{e}")
            time.sleep(delay)
            attempt += 1
    print(f"达到最大重连次数 {max_attempts}，放弃重连。")
    return False

# 设置 MQTT 客户端
client_id = "receiver-client-id"
client = paho.Client(client_id=client_id, transport="websockets", protocol=paho.MQTTv5)

# 设置回调函数
client.on_connect = on_connect
client.on_disconnect = on_disconnect
client.on_message = on_message
client.on_subscribe = on_subscribe

# 配置 WebSocket 路径
client.ws_set_options(path="/mqtt")

# 启用 TLS
client.tls_set()

# 连接到 MQTT Broker
broker = "broker.emqx.io"
port = 8084

# 启用自动重连
client.reconnect_delay_set(min_delay=1, max_delay=120)

# 初次连接
try:
    client.connect(broker, port, keepalive=60)
except Exception as e:
    print(f"初次连接失败：{e}")
    reconnect(client, broker, port)  # 如果初次连接失败，也尝试重连

# 启动循环
try:
    print("启动客户端，等待消息...")
    client.loop_forever()
except KeyboardInterrupt:
    print("正在断开连接...")
    client.disconnect()