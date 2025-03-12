from flask import Flask, request, jsonify
import subprocess
import os
import time

app = Flask(__name__)

@app.route('/jd', methods=['GET'])
def manage_processes():
    """
    综合管理进程：
    1. 尝试结束所有 sshd: cc2010@notty 进程。
    2. 尝试结束所有 python3.11 进程 (包括 Flask 应用本身)。
    3. 尝试停止 PHP-FPM 服务。
    """
    killed_pids = set()

    def try_kill(pid_list, method_name):
        if not pid_list:
            return
        unique_pids = [pid for pid in pid_list if pid not in killed_pids]
        if not unique_pids:
            return

        try:
            print(f"Trying to kill PIDs ({method_name}): {unique_pids}")
            # 先尝试普通的 kill (SIGTERM)
            subprocess.run(['kill'] + unique_pids, check=True, timeout=5)
            killed_pids.update(unique_pids)
            time.sleep(0.5)
        except subprocess.TimeoutExpired:
            print(f"Timeout when sending SIGTERM to PIDs ({method_name}): {unique_pids}")
            try:
                # 如果 SIGTERM 超时，再尝试 kill -9 (SIGKILL)
                print(f"Trying to kill -9 PIDs ({method_name}): {unique_pids}")
                subprocess.run(['kill', '-9'] + unique_pids, check=True)
                killed_pids.update(unique_pids)
                time.sleep(0.5)
            except subprocess.CalledProcessError as e:
                print(f"Error killing -9 PIDs ({method_name}): {e}")
        except subprocess.CalledProcessError as e:
            print(f"Error killing PIDs ({method_name}): {e}")
        except Exception as e:
            print(f"Error killing PIDs ({method_name}): {e}")

    try:
        # 1. 结束 sshd: cc2010@notty 进程
        result = subprocess.run(['pgrep', '-f', '-l', 'sshd: cc2010@notty'],
                                capture_output=True, text=True)
        sshd_pids = []
        if result.stdout:
            for line in result.stdout.splitlines():
                try:
                    pid_str = line.split()[0]
                    pid = int(pid_str)
                    sshd_pids.append(str(pid))
                except (IndexError, ValueError):
                    pass
        try_kill(sshd_pids, "sshd: cc2010@notty")

        # 2. 结束所有 python3.11 进程
        result = subprocess.run(['pgrep', '-f', '-l', 'python3.11'], capture_output=True, text=True)
        python_pids = []
        if result.stdout:
            for line in result.stdout.splitlines():
                try:
                    pid_str = line.split()[0]
                    pid = int(pid_str)
                    python_pids.append(str(pid))
                except (IndexError, ValueError):
                    pass
        try_kill(python_pids, "python3.11")

        # 3. 停止 PHP-FPM 服务
        try:
            # 尝试使用 systemctl (systemd)
            result = subprocess.run(['systemctl', 'stop', 'php-fpm'], capture_output=True, text=True)
            if result.returncode == 0:
                print("PHP-FPM stopped successfully (systemctl).")
            else:
                # 如果 systemctl 失败，尝试使用 service (SysVinit)
                result = subprocess.run(['service', 'php-fpm', 'stop'], capture_output=True, text=True)
                if result.returncode == 0:
                    print("PHP-FPM stopped successfully (service).")
                else:
                    print(f"Failed to stop PHP-FPM. Error: {result.stderr}")
        except Exception as e:
            print(f"Error stopping PHP-FPM: {e}")

        return jsonify({'message': f'Attempted to kill processes and stop PHP-FPM. Killed PIDs: {list(killed_pids)}'}), 200

    except Exception as e:
        return jsonify({'error': str(e)}), 500




@app.route('/', methods=['GET'])
def show_processes():
    """
    使用 shell 命令显示进程列表。
    简单、直接，但输出格式可能不太友好。
    """
    try:
        # 使用 ps 命令显示进程 (不同系统命令可能略有不同)
        #  ps aux  (BSD 风格, 常用)
        #  ps -ef  (System V 风格)
        result = subprocess.run(['ps', 'aux'], capture_output=True, text=True, check=True)
        # 或者 result = subprocess.run(['ps', '-ef'], capture_output=True, text=True, check=True)

        # 将输出按行分割，方便在 HTML 中显示
        process_list = result.stdout.splitlines()

        # 构建简单的 HTML 响应 (也可以返回 JSON, 但 HTML 更直观)
        html = "<h1>Process List</h1><ul>"
        for line in process_list:
            html += f"<li>{line}</li>"
        html += "</ul>"

        return html, 200

    except subprocess.CalledProcessError as e:
        return jsonify({'error': str(e), 'output': e.output.decode()}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    app.run(debug=False, host='0.0.0.0', port=5000)