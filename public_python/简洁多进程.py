from flask import Flask, jsonify
import paho.mqtt.client as paho
import time
import json
import threading
import uuid
import queue

app = Flask(__name__)

# 定义主题
TOPIC = "jd/cookie/tasks"
ACK_TOPIC = "jd/cookie/tasks/ack"

# 加密映射
encryption_mapping = {
    '0': 'a', '1': 'b', '2': 'c', '3': 'd', '4': 'e',
    '5': 'f', '6': 'g', '7': 'h', '8': 'i', '9': 'j',
    'a': '0', 'b': '1', 'c': '2', 'd': '3', 'e': '4',
    'f': '5', 'g': '6', 'h': '7', 'i': '8', 'j': '9'
}

# 全局变量
ack_queue = queue.Queue()
task_queue = queue.Queue()
task_threads = []
MAX_CONCURRENT_TASKS = 3  # 最大并发任务数
client = None

def simple_encrypt(text):
    """简单加密"""
    return ''.join(encryption_mapping.get(c, c) for c in text)

# 定义回调函数
def on_connect(client, userdata, flags, reasonCode, properties=None):
    print(f"MQTT连接状态: {reasonCode}")
    if reasonCode == 0:
        print("成功连接到MQTT broker")
        client.subscribe(ACK_TOPIC, qos=2)
        print(f"已订阅确认主题: {ACK_TOPIC}")
    else:
        print(f"连接失败，错误代码: {reasonCode}")

def on_subscribe(client, userdata, mid, granted_qos, properties=None):
    print(f"成功订阅，mid: {mid}, QoS: {granted_qos}")

def on_message(client, userdata, msg):
    print(f"收到消息，主题: {msg.topic}")
    try:
        payload = msg.payload.decode()
        print(f"消息内容: {payload}")
        
        if msg.topic == ACK_TOPIC:
            data = json.loads(payload)
            task_id = data.get("task_id")
            if task_id:
                print(f"收到确认消息，task_id: {task_id}")
                ack_queue.put(task_id)
            else:
                print("确认消息中缺少task_id")
    except Exception as e:
        print(f"处理确认消息错误: {e}")

def task_worker():
    """任务工作线程，从队列中取出任务执行"""
    while True:
        try:
            # 从队列中获取任务ID
            task_number = task_queue.get(block=True)
            print(f"开始执行任务队列中的任务 #{task_number}")
            
            # 执行任务
            send_task_message(task_number)
            
            # 标记任务完成
            task_queue.task_done()
        except Exception as e:
            print(f"任务执行错误: {e}")

def send_task_message(task_number):
    """发送任务消息的函数，接受一个任务编号参数"""
    print(f"开始发送任务序列 #{task_number}...")
    
    try:
        for i in range(3):
            # 生成唯一的task_id
            task_id = str(uuid.uuid4())
            print(f"\n准备发送任务 {i+1}/3 (序列 #{task_number}), task_id: {task_id}")
            
            # 示例数据
            pt_key = f"AAJlq5MnADDk9Gm-example-key-{i}"
            pt_pin = f"jd_example_pin_{i}"
            
            # 加密数据
            encrypted_pt_key = simple_encrypt(pt_key)
            encrypted_pt_pin = simple_encrypt(pt_pin)
            
            # 创建消息
            message = {
                "task_id": task_id,
                "remark": f"测试任务 {i+1}/3 (序列 #{task_number})",
                "pt_key": encrypted_pt_key,
                "pt_pin": encrypted_pt_pin
            }
            
            # 发送消息直到收到确认
            confirmed = False
            attempt = 1
            
            while not confirmed:
                print(f"发送任务 {i+1}/3 (序列 #{task_number}, 尝试 #{attempt})")
                
                # 清空队列中可能存在的旧确认消息
                while not ack_queue.empty():
                    old_ack = ack_queue.get(False)
                    print(f"清除旧确认消息: {old_ack}")
                
                result = client.publish(TOPIC, json.dumps(message), qos=2)
                if result.rc != 0:
                    print(f"发布失败，错误码: {result.rc}")
                    time.sleep(2)
                    attempt += 1
                    continue
                else:
                    print(f"消息已发布，mid: {result.mid}")
                
                try:
                    # 等待确认，超时5秒
                    received_task_id = ack_queue.get(block=True, timeout=5)
                    
                    if received_task_id == task_id:
                        print(f"任务 {i+1}/3 (序列 #{task_number}) 已确认")
                        confirmed = True
                        # 如果不是最后一个任务，等待5秒再发送下一个
                        if i < 2:
                            print("等待5秒后发送下一个任务...")
                            time.sleep(5)
                    else:
                        print(f"收到不匹配的确认ID: {received_task_id}，期望: {task_id}")
                except queue.Empty:
                    # 超时未收到确认，继续循环重新发送
                    print("未收到确认，5秒后重新发送...")
                    time.sleep(5)
                    attempt += 1
        
        print(f"\n任务序列 #{task_number} 所有任务发送完成")
    except Exception as e:
        print(f"发送任务时发生错误: {e}")

# 初始化MQTT客户端
def init_mqtt_client():
    global client
    client_id = f"flask-publisher-{uuid.uuid4()}"
    client = paho.Client(client_id=client_id, transport="websockets", protocol=paho.MQTTv5)
    client.on_connect = on_connect
    client.on_message = on_message
    client.on_subscribe = on_subscribe
    client.ws_set_options(path="/mqtt")
    client.tls_set()
    
    # 连接到MQTT Broker
    broker = "broker.emqx.io"
    port = 8084
    
    try:
        print(f"尝试连接到MQTT broker: {broker}:{port}")
        client.connect(broker, port, keepalive=60)
        client.loop_start()
        print("MQTT客户端已启动")
        return True
    except Exception as e:
        print(f"MQTT连接失败: {e}")
        return False

# 启动工作线程
def start_workers():
    global task_threads
    
    # 清理已结束的线程
    task_threads = [t for t in task_threads if t.is_alive()]
    
    # 启动工作线程（如果数量不足）
    if len(task_threads) < MAX_CONCURRENT_TASKS:
        for i in range(MAX_CONCURRENT_TASKS - len(task_threads)):
            thread = threading.Thread(target=task_worker)
            thread.daemon = True
            thread.start()
            task_threads.append(thread)
            print(f"启动工作线程 #{len(task_threads)}")
    
    return len(task_threads)

# Flask路由
@app.route('/jd', methods=['GET'])
def trigger_jd_tasks():
    """触发发送任务的HTTP端点"""
    global client
    
    # 确保MQTT客户端已连接
    if client is None:
        if not init_mqtt_client():
            return jsonify({"status": "error", "message": "MQTT客户端初始化失败"}), 500
    
    if not client.is_connected():
        try:
            client.reconnect()
            print("MQTT客户端重新连接成功")
        except Exception as e:
            print(f"MQTT客户端重连失败: {e}")
            return jsonify({"status": "error", "message": "MQTT客户端无法连接"}), 500
    
    # 确保工作线程已启动
    active_workers = start_workers()
    
    # 添加新任务到队列
    task_number = int(time.time())  # 使用时间戳作为任务编号
    task_queue.put(task_number)
    
    queue_size = task_queue.qsize()
    
    print(f"任务 #{task_number} 已加入队列，当前队列长度: {queue_size}，活动工作线程: {active_workers}")
    return jsonify({
        "status": "success", 
        "message": f"任务 #{task_number} 已加入队列", 
        "queue_size": queue_size,
        "active_workers": active_workers
    })

@app.route('/queue', methods=['GET'])
def queue_status():
    """查看任务队列状态"""
    return jsonify({
        "status": "ok",
        "queue_size": task_queue.qsize(),
        "active_workers": len([t for t in task_threads if t.is_alive()]),
        "mqtt_status": "connected" if client and client.is_connected() else "disconnected"
    })

@app.route('/health', methods=['GET'])
def health_check():
    """健康检查端点"""
    global client
    mqtt_status = "connected" if client and client.is_connected() else "disconnected"
    return jsonify({
        "status": "ok",
        "mqtt_status": mqtt_status,
        "queue_size": task_queue.qsize(),
        "active_workers": len([t for t in task_threads if t.is_alive()])
    })

@app.route('/restart', methods=['GET'])
def restart_mqtt():
    """重启MQTT客户端"""
    global client
    
    # 清理现有客户端
    if client is not None:
        try:
            if client.is_connected():
                client.disconnect()
            client.loop_stop()
            print("已断开并停止旧的MQTT客户端")
        except Exception as e:
            print(f"清理旧MQTT客户端时出错: {e}")
    
    # 初始化新的MQTT客户端
    if init_mqtt_client():
        # 确保工作线程已启动
        active_workers = start_workers()
        return jsonify({
            "status": "success", 
            "message": "MQTT客户端已重启",
            "active_workers": active_workers
        })
    else:
        return jsonify({"status": "error", "message": "MQTT客户端重启失败"}), 500

if __name__ == '__main__':
    print("初始化MQTT客户端...")
    if init_mqtt_client():
        print("启动工作线程...")
        start_workers()
        print("启动Flask应用...")
        # 使用调试模式和线程模式启动Flask
        app.run(debug=True, threaded=True)
    else:
        print("应用启动失败，MQTT连接错误")
