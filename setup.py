# FILENAME: setup_global.py
# VERSION: 2.0 (Global-Purpose Python Package Installer)

import sys
import subprocess

# --- 配置 ---
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

def main():
    """主函数：在当前的 Python 环境中安装所有指定的依赖。"""
    print("--- 运行全局环境安装脚本 (版本 2.0) ---")
    print(f"将把依赖包安装到这个 Python 解释器对应的环境中:\n  '{sys.executable}'")
    print("\n警告：正在将依赖包直接安装到系统环境中。")
    print("这可能会与其他项目产生依赖冲突。推荐使用虚拟环境进行项目隔离。")

    # 1. 将所有需要安装的包合并到一个列表
    all_packages_to_install = []
    print("\n--- 将要安装/更新以下依赖包 ---")
    for category, packages in REQUIRED_PACKAGES.items():
        print(f"  [{category}]: {', '.join(packages)}")
        all_packages_to_install.extend(packages)
    
    # 2. 安装或更新所有依赖
    print("\n--- 开始执行安装 (pip 会自动跳过已是最新版的包) ---")
    try:
        # 使用 sys.executable -m pip 是最稳妥的方式，确保使用的是当前 python 环境的 pip
        command = [sys.executable, "-m", "pip", "install", "--upgrade"] + all_packages_to_install
        
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
             
        print("\n--- 所有依赖已成功安装/更新到全局环境 ---")

    except subprocess.CalledProcessError as e:
        print(f"\n错误：安装依赖时出错！返回码: {e.returncode}")
        # 如果是权限问题，给出提示
        if e.returncode == 1 and ('Permission denied' in str(e.output) or 'Access is denied' in str(e.output)):
             print("提示：可能是权限不足。在 Linux/macOS 上，您可能需要使用 'sudo'。")
             print(f"例如: sudo {sys.executable} setup_global.py")
        sys.exit(1)
    except Exception as e:
        print(f"\n发生未知错误: {e}")
        sys.exit(1)
        
    print("\n✅ 环境设置完成！")
    print("您现在可以在系统中直接运行使用这些库的 Python 脚本了。")

if __name__ == "__main__":
    main()
