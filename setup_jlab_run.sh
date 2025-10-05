#!/usr/bin/env bash
# 作用：安装 jupyterlab 与中文语言包，并用命令行参数直接“无密码”启动
# 特点：不创建虚拟环境；不写配置文件；自动处理 PEP 668（externally-managed-environment）
# 端口：默认不显式指定（用 8888）。如需固定端口：JL_PORT=8888
# 用法（文件）：chmod +x run_jlab_nopass.sh && ./run_jlab_nopass.sh
# 用法（管道）：curl -fsSL <URL> | bash
set -Eeuo pipefail
trap 'echo "[ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

log(){ printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
die(){ echo "[FATAL] $*" >&2; exit 1; }

# 选 pip
if command -v pip >/dev/null 2>&1; then
  PIP="pip"
elif command -v pip3 >/dev/null 2>&1; then
  PIP="pip3"
elif command -v python3 >/dev/null 2>&1; then
  PIP="python3 -m pip"
else
  die "未找到 pip/pip3/python3，请先安装 Python3 与 pip。"
fi

export PATH="$HOME/.local/bin:$PATH"
MIRROR="-i https://pypi.tuna.tsinghua.edu.cn/simple"
PKGS=(jupyterlab jupyterlab-language-pack-zh-CN)

# 升级 pip（失败不致命）
$PIP install -U pip $MIRROR >/dev/null 2>&1 || true

install_pkgs() {
  # 1) 常规
  if $PIP install -U "${PKGS[@]}" $MIRROR; then return 0; fi
  log "常规安装失败，尝试 --user ..."
  # 2) --user
  if $PIP install --user -U "${PKGS[@]}" $MIRROR; then return 0; fi
  # 3) PEP 668：与 --user 搭配的 --break-system-packages
  if $PIP --help 2>&1 | grep -q -- '--break-system-packages'; then
    echo "[警告] 检测到外部托管环境，使用 --user --break-system-packages 回退安装。" >&2
    if $PIP install --user --break-system-packages -U "${PKGS[@]}" $MIRROR; then return 0; fi
    # 4) 最后尝试系统级安装（无交互 sudo），适用于需要写入系统 site-packages 的场景
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      echo "[警告] 使用 sudo --break-system-packages 进行系统级安装。" >&2
      if sudo -n $PIP install --break-system-packages -U "${PKGS[@]}" $MIRROR; then return 0; fi
    fi
  fi
  return 1
}

log "安装 jupyterlab 与中文语言包..."
if ! install_pkgs; then
  cat >&2 <<'EOF'
[提示] 仍然失败，原因通常是：
- 系统启用了 PEP 668 并禁止用户目录安装；且无 sudo 权限可写系统 site-packages。
可选方案（保持“无配置文件直启”的思路）：
1) 重新执行并输入 sudo 密码（若允许）：sudo bash run_jlab_nopass.sh
2) 或手动执行（需 sudo 权限）：
   sudo pip install --break-system-packages -U jupyterlab jupyterlab-language-pack-zh-CN -i https://pypi.tuna.tsinghua.edu.cn/simple
3) 或使用 pipx（隔离环境，但不写配置）：pipx install jupyterlab
EOF
  exit 1
fi

# 定位 jupyter
if ! command -v jupyter >/dev/null 2>&1; then
  [ -x "$HOME/.local/bin/jupyter" ] || die "未找到 jupyter，可将 ~/.local/bin 加入 PATH 后重试。"
fi
JUP="$(command -v jupyter || echo "$HOME/.local/bin/jupyter")"

# 组装启动命令（只用命令行参数，无需配置文件）
CMD=( "$JUP" lab --ip=0.0.0.0 --no-browser --ServerApp.token='' --ServerApp.password='' )
# 仅 root 时附加 --allow-root
if [ "${EUID:-$(id -u)}" -eq 0 ]; then CMD+=(--allow-root); fi
# 可选端口
if [ -n "${JL_PORT:-}" ]; then CMD+=(--port="$JL_PORT"); fi

echo
echo "将以如下命令启动（可复制）："
printf '  %q ' "${CMD[@]}"; echo
echo

exec "${CMD[@]}"
