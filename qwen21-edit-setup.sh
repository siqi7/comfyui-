#!/usr/bin/env bash
# =============================================================================
# Qwen-Image-2.1-Turbo 图像编辑 · 一键部署脚本
# 环境：阿里云 DSW / 魔搭 Notebook，8核 CPU / 32GB 内存 / 24GB 显存
# 用法：bash setup_qwen21_edit.sh
# 特点：全部走国内加速源，模型用魔搭官方仓库，幂等可重复执行
# =============================================================================

set -uo pipefail

# ------------------------------ 配置区 --------------------------------------
WORKDIR="/mnt/workspace"
COMFY_DIR="${WORKDIR}/ComfyUI"
LOG_DIR="${WORKDIR}/logs"
PIP_MIRROR="https://mirrors.aliyun.com/pypi/simple/"
MS_MODEL="Comfy-Org/Qwen-Image-2.1"

# GitHub 加速代理（前缀式）。脚本会依次尝试，谁通用谁。
# 这类站点生命周期不稳定，多放几个，任一可用即可。
GH_PROXIES=(
  "https://gh-proxy.com/"
  "https://ghfast.top/"
  "https://github.moeyy.xyz/"
  "https://ghproxy.net/"
  "https://ghproxy.cc/"
  "https://gh.llkk.cc/"
  "https://ghproxy.homeboyc.cn/"
  "https://hub.gitmirror.com/"
  "https://ghps.cc/"
  "https://ghp.ci/"
)
# 域名替换式加速（语法不同，单独列）
GH_HOSTS=(
  "https://kkgithub.com/"
  "https://bgithub.xyz/"
)
PORT="8188"
DOMAIN="comfyui.7117777.xyz"

# Cloudflare Tunnel token（内含 account_id / tunnel_id / secret）
# 安全起见不写入仓库。运行前先设置：
#   export TUNNEL_TOKEN='eyJhIjoi...'
# 不设置也能跑，只是跳过公网隧道，ComfyUI 本地照常可用。
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"

# 模型清单：路径 | 期望 sha256 | 期望字节数
DIT_REL="diffusion_models/qwen_image_2.1_turbo_int8_convrot.safetensors"
DIT_SHA="8144a0182964aa8403ad6dbc011db837304167d235161b9aabaa8532e967314c"
TE_REL="text_encoders/qwen3vl_8b_int8_convrot.safetensors"
TE_SHA="8bfd0f6e12abf2d2d697ecc888e5e90b0d6741d6708f05799f53afa560452e8f"
VAE_REL="vae/qwen_image_2.1_vae_bf16.safetensors"
VAE_SHA="bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9"
# ---------------------------------------------------------------------------

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; RST=$'\033[0m'
info() { echo "${CYA}[*]${RST} $*"; }
ok()   { echo "${GRN}[✓]${RST} $*"; }
warn() { echo "${YEL}[!]${RST} $*"; }
err()  { echo "${RED}[✗]${RST} $*" >&2; }
die()  { err "$*"; exit 1; }

mkdir -p "$LOG_DIR"

# ============================ 0. 环境检查 ===================================
step_env() {
  echo
  echo "${CYA}=========== [1/6] 环境检查 ===========${RST}"

  command -v git  >/dev/null || die "缺少 git"
  command -v curl >/dev/null || die "缺少 curl"
  command -v python >/dev/null || die "缺少 python"

  local py; py=$(python -V 2>&1)
  ok "Python: $py"

  if command -v nvidia-smi >/dev/null; then
    nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader | while read -r line; do
      ok "GPU: $line"
    done
  else
    warn "未检测到 nvidia-smi，GPU 可能不可用"
  fi

  if python -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    ok "torch: $(python -c 'import torch;print(torch.__version__)') (CUDA 可用)"
  else
    warn "torch CUDA 不可用，后续出图会失败，请先确认镜像环境"
  fi

  local avail; avail=$(df -BG --output=avail "$WORKDIR" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -n "${avail:-}" ] && [ "$avail" -lt 40 ]; then
    warn "可用空间仅 ${avail}G，建议至少 40G（模型 17.3G + 环境 8G）"
  else
    ok "磁盘可用: ${avail:-未知}G"
  fi
}

# ============================ 1. 安装 ComfyUI ===============================
step_comfy() {
  echo
  echo "${CYA}=========== [2/6] 安装 ComfyUI ===========${RST}"

  if [ -f "${COMFY_DIR}/main.py" ] && [ -f "${COMFY_DIR}/requirements.txt" ]; then
    ok "已存在完整 ComfyUI，跳过 clone"
  else
    if [ -d "$COMFY_DIR" ]; then
      warn "目录存在但不完整，清理后重新拉取"
      rm -rf "$COMFY_DIR"
    fi
    local cloned=0 u p
    local urls=()
    for p in "${GH_PROXIES[@]}"; do
      urls+=("${p}https://github.com/comfyanonymous/ComfyUI.git")
    done
    for p in "${GH_HOSTS[@]}"; do
      urls+=("${p}comfyanonymous/ComfyUI.git")
    done
    urls+=("https://gitclone.com/github.com/comfyanonymous/ComfyUI.git")
    urls+=("https://github.com/comfyanonymous/ComfyUI.git")

    for u in "${urls[@]}"; do
      info "clone: $u"
      if timeout 420 git clone --depth 1 \
           --config http.lowSpeedLimit=1000 --config http.lowSpeedTime=60 \
           "$u" "$COMFY_DIR" 2>"${LOG_DIR}/clone.log"; then
        cloned=1; break
      fi
      rm -rf "$COMFY_DIR"
      warn "该源失败或超时，换下一个"
    done
    # clone 全失败 -> 退化为下载 zip 包，避免卡死在 clone 上
    if [ "$cloned" -eq 0 ]; then
      warn "所有 clone 源都失败，改用 zip 包方式"
      local zp="${WORKDIR}/ComfyUI.zip"
      local zip_rel="https://github.com/comfyanonymous/ComfyUI/archive/refs/heads/master.zip"
      local zurls=()
      for p in "${GH_PROXIES[@]}"; do zurls+=("${p}${zip_rel}"); done
      zurls+=("$zip_rel")

      for u in "${zurls[@]}"; do
        info "下载 zip: $u"
        rm -f "$zp"
        if curl -fL --retry 1 --connect-timeout 15 --max-time 420 \
             --speed-limit 2048 --speed-time 30 -o "$zp" "$u" 2>/dev/null; then
          rm -rf "${WORKDIR}/_comfy_zip"
          if python -m zipfile -e "$zp" "${WORKDIR}/_comfy_zip" 2>/dev/null; then
            local inner
            inner=$(find "${WORKDIR}/_comfy_zip" -maxdepth 1 -mindepth 1 -type d | head -1)
            if [ -n "$inner" ]; then
              mv "$inner" "$COMFY_DIR"
              rm -rf "${WORKDIR}/_comfy_zip" "$zp"
              cloned=1
              ok "已通过 zip 包获取 ComfyUI"
              break
            fi
          fi
          rm -rf "${WORKDIR}/_comfy_zip"
        fi
        warn "该 zip 源失败，换下一个"
      done
      rm -f "$zp"
    fi

    [ "$cloned" -eq 1 ] || die "所有源均失败。手动下载解压到 ${COMFY_DIR} 即可：https://gh-proxy.com/https://github.com/comfyanonymous/ComfyUI/archive/refs/heads/master.zip"
    ok "ComfyUI 拉取完成"
  fi

  cd "$COMFY_DIR" || die "无法进入 $COMFY_DIR"

  info "安装依赖（预计 3-8 分钟）..."
  pip install -q -r requirements.txt -i "$PIP_MIRROR" || die "依赖安装失败"
  pip install -q -U comfyui-workflow-templates modelscope -i "$PIP_MIRROR" || die "模板/模型工具安装失败"

  if python -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    ok "依赖就绪，torch CUDA 正常"
  else
    die "依赖装完后 torch CUDA 不可用（可能被降级），请检查镜像自带的 torch"
  fi
}

# ============================ 2. 下载模型 ===================================
check_sha() {
  local f="$1" want="$2"
  [ -f "$f" ] || return 1
  local got; got=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
  [ "$got" = "$want" ]
}

dl_one() {
  local rel="$1" sha="$2"
  local dst="${COMFY_DIR}/models/${rel}"

  if check_sha "$dst" "$sha"; then
    ok "已就绪: $rel ($(du -h "$dst" | cut -f1))"
    return 0
  fi

  info "下载 $rel ..."
  local i
  for i in 1 2 3; do
    if modelscope download --model "$MS_MODEL" --include "$rel" \
         --local_dir "${COMFY_DIR}/models" >"${LOG_DIR}/ms_$(basename "$rel").log" 2>&1; then
      break
    fi
    warn "第 $i 次失败，重试..."
    sleep 3
  done

  if check_sha "$dst" "$sha"; then
    ok "完成: $rel ($(du -h "$dst" | cut -f1))"
    return 0
  fi
  err "校验失败: $rel"
  err "看日志: ${LOG_DIR}/ms_$(basename "$rel").log"
  return 1
}

step_models() {
  echo
  echo "${CYA}=========== [3/6] 下载模型（Turbo · 共 17.3G）===========${RST}"
  export MODELSCOPE_CACHE="${WORKDIR}/.ms_cache"

  mkdir -p "${COMFY_DIR}/models"/{diffusion_models,text_encoders,vae}

  dl_one "$DIT_REL" "$DIT_SHA" || die "DiT 下载失败"
  dl_one "$TE_REL"  "$TE_SHA"  || die "文本编码器下载失败"
  dl_one "$VAE_REL" "$VAE_SHA" || die "VAE 下载失败"

  echo
  info "模型清单："
  ls -lh "${COMFY_DIR}/models/diffusion_models" "${COMFY_DIR}/models/text_encoders" \
         "${COMFY_DIR}/models/vae" 2>/dev/null | grep -v '^total'
}

# ============================ 3. 安装 cloudflared ===========================
step_cloudflared() {
  echo
  echo "${CYA}=========== [4/6] 准备 cloudflared ===========${RST}"

  local bin="${WORKDIR}/cloudflared"
  if [ -x "$bin" ]; then
    ok "已存在: $("$bin" --version 2>/dev/null | head -1)"
    return 0
  fi

  local u p
  local rel="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  local urls=()
  for p in "${GH_PROXIES[@]}"; do urls+=("${p}${rel}"); done
  urls+=("$rel")

  for u in "${urls[@]}"; do
    info "下载 cloudflared: $u"
    if curl -fL --retry 2 --connect-timeout 15 --max-time 300 \
         --speed-limit 1024 --speed-time 30 -o "$bin" "$u" 2>/dev/null; then
      chmod +x "$bin"
      if "$bin" --version >/dev/null 2>&1; then
        ok "cloudflared 就绪: $("$bin" --version | head -1)"
        return 0
      fi
    fi
    rm -f "$bin"
    warn "该源失败，换下一个"
  done
  err "cloudflared 下载失败，隧道将不会启动（不影响 ComfyUI 本地使用）"
  return 1
}

# ============================ 4. 启动服务 ===================================
wait_port() {
  local port="$1" tries="${2:-60}" i
  for ((i = 0; i < tries; i++)); do
    if curl -s -o /dev/null -m 2 "http://127.0.0.1:${port}/" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

step_start() {
  echo
  echo "${CYA}=========== [5/6] 启动 ComfyUI ===========${RST}"

  pkill -f "main.py --listen" 2>/dev/null && warn "已停止旧的 ComfyUI 进程"
  sleep 1

  cd "$COMFY_DIR" || die "无法进入 $COMFY_DIR"
  setsid nohup python main.py --listen 0.0.0.0 --port "$PORT" --reserve-vram 1 \
    > "${LOG_DIR}/comfyui.log" 2>&1 &
  local pid=$!
  info "ComfyUI 启动中 (pid=$pid)，日志: ${LOG_DIR}/comfyui.log"

  if wait_port "$PORT" 90; then
    ok "ComfyUI 已就绪: http://127.0.0.1:${PORT}"
  else
    err "90 秒内未监听 ${PORT}，最后 30 行日志："
    tail -30 "${LOG_DIR}/comfyui.log" >&2
    return 1
  fi
}

step_tunnel() {
  echo
  echo "${CYA}=========== [6/6] 启动 Cloudflare 隧道 ===========${RST}"

  local bin="${WORKDIR}/cloudflared"
  if [ -z "${TUNNEL_TOKEN:-}" ]; then
    warn "未设置 TUNNEL_TOKEN，跳过隧道启动（ComfyUI 本地仍可正常使用）"
    warn "需要公网访问时：export TUNNEL_TOKEN='你的token' 后重跑本脚本"
    return 0
  fi
  [ -x "$bin" ] || { warn "cloudflared 不存在，跳过隧道"; return 0; }

  pkill -f "cloudflared tunnel run" 2>/dev/null && warn "已停止旧隧道进程"
  sleep 1

  setsid nohup "$bin" tunnel run --token "$TUNNEL_TOKEN" \
    > "${LOG_DIR}/cloudflared.log" 2>&1 &

  sleep 8
  if pgrep -f "cloudflared tunnel run" >/dev/null; then
    ok "隧道进程运行中"
    if grep -qi "Registered tunnel connection" "${LOG_DIR}/cloudflared.log" 2>/dev/null; then
      ok "已连上 Cloudflare 边缘节点"
    else
      warn "尚未看到注册成功日志，稍等或用下面命令查看："
      echo "    tail -f ${LOG_DIR}/cloudflared.log"
    fi
  else
    err "隧道启动失败，日志："
    tail -25 "${LOG_DIR}/cloudflared.log" >&2
  fi
}

# ============================ 主流程 ========================================
main() {
  echo "${CYA}╔══════════════════════════════════════════════════════╗${RST}"
  echo "${CYA}║  Qwen-Image-2.1-Turbo 图像编辑 · 一键部署            ║${RST}"
  echo "${CYA}╚══════════════════════════════════════════════════════╝${RST}"

  step_env
  step_comfy
  step_models
  step_cloudflared || true
  step_start   || die "ComfyUI 启动失败"
  step_tunnel

  echo
  echo "${GRN}════════════════ 部署完成 ════════════════${RST}"
  echo "  本地地址 : http://127.0.0.1:${PORT}"
  echo "  公网地址 : https://${DOMAIN}"
  echo "  Jupyter  : 把地址栏 /lab 换成 /proxy/${PORT}/"
  echo
  echo "  ComfyUI 日志 : tail -f ${LOG_DIR}/comfyui.log"
  echo "  隧道日志     : tail -f ${LOG_DIR}/cloudflared.log"
  echo
  echo "${YEL}  工作流：Workflow → Browse Templates → 选 'Qwen Image 2.1 Turbo: Image Edit'${RST}"
  echo "${YEL}  参数  ：steps 8 · cfg 1.0 · euler / simple${RST}"
  echo
}

main "$@"
