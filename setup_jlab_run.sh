#!/bin/bash
set -Eeuo pipefail

INDEX_URL=${INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}

# 升级 pip（走清华源）  安装并启动 JupyterLab
python3 -m pip install -U pip -i "$INDEX_URL"

# 安装 JupyterLab + 中文包 + LSP + Python 内核（走清华源）
python3 -m pip install -U \
  jupyterlab \
  jupyterlab-language-pack-zh-CN \
  jupyterlab-lsp \
  jedi-language-server \
  ipykernel \
  -i "$INDEX_URL"

echo "安装完成！正在以 root 且无密码方式启动 JupyterLab..."
# 如需修改端口，启动前导出：PORT=9999
exec jupyter lab \
  --allow-root \
  --ip=0.0.0.0 \
  --port="${PORT:-8888}" \
  --ServerApp.token='' \
  --ServerApp.password=''
