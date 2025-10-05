# FILENAME: setup_env.py
# VERSION: 2.0 (General-Purpose Python Environment Installer)

import os
import sys
import subprocess
import tempfile

# --- 配置 ---
# 虚拟环境的名称，存储在临时目录中
VENV_NAME = ".my_general_purpose_venv"

# 将常用依赖按类别分组，方便管理和理解
REQUIRED_PACKAGES = {
    # --- Web 开发 & API 访问 ---
    "Web & Network": [
        "flask",          # 轻量级 Web 框架
        "gunicorn",       # 生产级的 WSGI 服务器 (适用于 Linux/macOS)
        "requests",       # 业界标准，简单易用的 HTTP 请求库
        "httpx",          # 现代化的、支持异步的 HTTP 客户端
        "beautifulsoup4", # 强大的 HTML/XML 解析库
        "lxml",           # 最高性能的解析器，供 beautifulsoup4 使用
    ],
    
    # --- 比特币 & 加密 ---
    "Crypto & Bitcoin": [
        "base58",         # 比特币地址编码/解码
        "secp256k1",      # 比特币使用的椭圆曲线加密算法
        "pycryptodome",   # 功能全面的底层加密库 (hash,-ciphers 等)
    ],
    
    # --- 数据处理 & 科学计算 ---
    "Data Handling": [
        "numpy",          # Python 科学计算的基础包
        "pandas",         # 强大的数据分析和处理工具
    ],

    # --- 常用工具库 ---
    "Utilities": [
        "python-dotenv",  # 从 .env 文件加载环境变量，管理配置
        "tqdm",           # 为任何循环添加漂亮的进度条
        "clearscreen",    # 跨平台的清屏库
    ]
}

def get_venv_path() -> str:
    """获取虚拟环境在系统临时目录中的完整路径。"""
    return os.path.join(tempfile.gettempdir(), VENV_NAME)

def main():
    """主函数：创建环境并安装所有指定的依赖。"""
    print("--- 运行通用环境安装脚本 (版本 2.0) ---")
    
    venv_path = get_venv_path()
    python_executable = os.path.join(venv_path, "bin", "python") if sys.platform != "win32" else os.path.join(venv_path, "Scripts", "python.exe")
    pip_executable = os.path.join(venv_path, "bin", "pip") if sys.platform != "win32" else os.path.join(venv_path, "Scripts", "pip.exe")

    # 1. 检查并创建虚拟环境
    if not os.path.exists(python_executable):
        print(f"虚拟环境不存在，正在临时目录创建: '{venv_path}'...")
        try:
            # 使用 --upgrade-deps 确保 pip, setuptools 是最新的
            subprocess.run([sys.executable, "-m", "venv", venv_path, "--upgrade-deps"], check=True, capture_output=True, text=True)
            print("虚拟环境创建成功。")
        except subprocess.CalledProcessError as e:
            print(f"创建虚拟环境失败: {e.stderr}")
            sys.exit(1)
    else:
        print(f"虚拟环境已存在于: '{venv_path}'")

    # 2. 将所有需要安装的包合并到一个列表
    all_packages_to_install = []
    print("\n--- 将要安装/更新以下依赖包 ---")
    for category, packages in REQUIRED_PACKAGES.items():
        print(f"  [{category}]: {', '.join(packages)}")
        all_packages_to_install.extend(packages)
    
    # 3. 安装或更新所有依赖
    print("\n--- 开始执行安装 (pip 会自动跳过已是最新版的包) ---")
    try:
        # 使用 --upgrade 会确保所有包都更新到最新兼容版本
        command = [pip_executable, "install", "--upgrade"] + all_packages_to_install
        # 使用 Popen 实时流式传输输出，而不是等待命令完成
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8')
        while True:
            output = process.stdout.readline()
            if output == '' and process.poll() is not None:
                break
            if output:
                print(output.strip())
        
        if process.returncode != 0:
             raise subprocess.CalledProcessError(process.returncode, command)
             
        print("\n--- 所有依赖已成功安装/更新 ---")

    except subprocess.CalledProcessError as e:
        print(f"\n错误：安装依赖时出错！返回码: {e.returncode}")
        sys.exit(1)
        
    print("\n✅ 环境设置完成！")
    print("您现在可以使用下面的Python解释器来运行您的应用脚本:")
    print(f"\n   {python_executable}\n")

if __name__ == "__main__":
    main()
