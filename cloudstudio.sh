#!/bin/bash

# 首先，下载 Parsec 的 .deb 安装包
wget "https://builds.parsec.app/package/parsec-linux.deb"

# 使用 dpkg 尝试安装。 如果有依赖问题，会报错，但这是预期行为。
sudo dpkg -i parsec-linux.deb

# 使用 apt-get -f 来自动修复所有缺失的依赖并完成安装。
sudo apt-get update  # 确保软件包列表是最新的
sudo apt-get install -f

echo "Parsec 安装完成！"

# 建议：尝试运行 parsec 命令来启动程序。
#  请注意，在某些特殊环境中（例如没有图形界面的 WSL 或 Docker），
#  即使安装成功，也可能无法正常运行 Parsec。
