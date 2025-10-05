#!/usr/bin/env bash
# 安装 JupyterLab + 中文语言包，并直接以“无密码”参数启动（不写入任何配置文件）
# 关键参数：--ServerApp.token='' --ServerApp.password=''
# 默认：--ip=0.0.0.0 --no-browser；端口不指定（默认 8888）。如需指定，传 JL_PORT=8888
# 用法（文件）：chmod +x setup_jlab_run.sh && ./setup_jlab_run.sh
# 用法（管道）：curl -fsSL <脚本URL> | bash
set -Eeuo pipefail
trap 'echo "[ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

log(){ printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
die(){ echo "[FATAL] $*" >&2; exit 1; }

# 选择 pip
if command -v pip >/dev/null 2>&1; then
  PIP="pip"
elif command -v pip3 >/dev/null 2>&1; then
  PIP="pip3"
elif command -v python3 >/dev/null 2>&1; then
  PIP="python3 -m pip"
else
  die "未找到 pip/pip3/python3，请先安装 Python3 与 pip。"
fi

MIRROR="-i https://pypi.tuna.tsinghua.edu.cn/simple"

# 升级 pip（失败不致命）
$PIP install -U pip $MIRROR >/dev/null 2>&1 || true

# 安装 JupyterLab + 中文语言包（失败则回退 --user）
log "安装 jupyterlab 与中文语言包..."
if ! $PIP install -U jupyterlab jupyterlab-language-pack-zh-CN $MIRROR; then
  log "常规安装失败，回退到 --user ..."
  $PIP install --user -U jupyterlab jupyterlab-language-pack-zh-CN $MIRROR
  # 确保 ~/.local/bin 在 PATH
  export PATH="$HOME/.local/bin:$PATH"
fi

# 定位 jupyter
command -v jupyter >/dev/null 2>&1 || die "未找到 jupyter，可尝试将 ~/.local/bin 加入 PATH 后重试。"

# 拼装启动命令（不依赖配置文件）
CMD=(jupyter lab --ip=0.0.0.0 --no-browser --ServerApp.token='' --ServerApp.password='')
# 仅当以 root 运行时附加 --allow-root
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  CMD+=(--allow-root)
fi
# 可选端口：通过 JL_PORT 指定，否则省略（默认 8888）
if [ -n "${JL_PORT:-}" ]; then
  CMD+=(--port="$JL_PORT")
fi

echo
echo "将以如下命令启动（可复制备用）："
printf '  %q ' "${CMD[@]}"; echo
echo

# 启动
exec "${CMD[@]}"
