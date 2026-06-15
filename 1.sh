#!/bin/bash
# =================================================================
# BFS ComfyUI 一键部署脚本 (AMD ROCm 7.2.1, Ubuntu 24.04)
# 功能：
#   1. 安装 Clash 代理（使用你的订阅链接）
#   2. 部署 ComfyUI + BFSNodes
#   3. 下载全部所需模型（含基础模型和 LoRA）
#   4. 启动 ComfyUI 并创建 Cloudflare 公网隧道
# =================================================================

set -e

# ----------------------------- 用户必须修改的两个变量 -----------------------------
SUBSCRIPTION_URL="https://sub.aaaa.gay/link/G3mDAERoPO6s7mln?client=clashmeta"   # 你的 Clash 订阅链接
PREFERRED_NODE="☀JP-日本3-[直连][移优]-1x"                                      # 测速后最快的节点名
# 如需自动切换节点，请将节点名称填入上面变量；否则脚本会尝试用默认节点。

# ----------------------------- 基本配置 -----------------------------
WORKDIR="${WORKDIR:-/workspace}"                     # 工作目录，默认 /workspace
COMFYUI_DIR="$WORKDIR/ComfyUI"
CLASH_DIR="$WORKDIR/clash"
CLASH_PORT=7890
COMFYUI_PORT=8188
HF_TOKEN="${HF_TOKEN:-}"                             # 可选 HF token，下载更快
export HSA_OVERRIDE_GFX_VERSION=11.0.0               # AMD RDNA3 架构

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ----------------------------- 1. 基础环境 -----------------------------
info "安装基础依赖..."
apt update && apt install -y screen wget curl git git-lfs unzip python3-pip

# ----------------------------- 2. Clash 部署 -----------------------------
info "部署 Clash 代理..."
mkdir -p "$CLASH_DIR" && cd "$CLASH_DIR"

# 下载 mihomo 内核
wget -c "https://github.com/MetaCubeX/mihomo/releases/download/v1.18.10/mihomo-linux-amd64-v1.18.10.gz" -O mihomo.gz
gzip -d mihomo.gz && chmod +x mihomo

# 下载订阅并生成配置
curl -L -o config_raw.yaml "$SUBSCRIPTION_URL"
# 删除可能冲突的字段
sed -i '/^mixed-port:/d; /^allow-lan:/d; /^bind-address:/d; /^mode:/d; /^log-level:/d; /^external-controller:/d' config_raw.yaml

cat > config.yaml << 'EOF'
mixed-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
external-controller: 127.0.0.1:9090
EOF
cat config_raw.yaml >> config.yaml
rm config_raw.yaml

# 后台启动 Clash
screen -dmS clash "$CLASH_DIR/mihomo" -d "$CLASH_DIR"
sleep 3

# 尝试切换到指定节点
if [ -n "$PREFERRED_NODE" ]; then
    info "尝试切换节点: $PREFERRED_NODE"
    curl -s -X PUT http://127.0.0.1:9090/proxies/%E9%BB%98%E8%AE%A4%E8%8A%82%E7%82%B9 -d "{\"name\":\"$PREFERRED_NODE\"}" || warn "节点切换失败，使用默认节点"
    sleep 2
fi

# 验证代理
if ! curl -x http://127.0.0.1:$CLASH_PORT -m 10 -o /dev/null -w "%{http_code}" https://huggingface.co | grep -q 200; then
    error "代理测试失败，请检查订阅链接或手动运行：curl -x http://127.0.0.1:$CLASH_PORT -v https://huggingface.co"
fi
info "Clash 代理已运行在 http://127.0.0.1:$CLASH_PORT"

# 设置全局代理变量
export http_proxy="http://127.0.0.1:$CLASH_PORT"
export https_proxy="http://127.0.0.1:$CLASH_PORT"
export all_proxy="http://127.0.0.1:$CLASH_PORT"

# ----------------------------- 3. 下载 ComfyUI -----------------------------
info "下载 ComfyUI..."
cd "$WORKDIR"
if [ -d "$COMFYUI_DIR" ]; then
    warn "ComfyUI 目录已存在，跳过克隆"
else
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
fi

# 安装依赖（使用清华源加速）
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
cd "$COMFYUI_DIR"
pip install -r requirements.txt

# ----------------------------- 4. 安装 BFSNodes -----------------------------
info "安装 BFSNodes..."
cd "$COMFYUI_DIR/custom_nodes"
if [ -d "ComfyUI-BFSNodes" ]; then
    warn "BFSNodes 已存在，跳过克隆"
else
    git clone https://github.com/alisson-anjos/ComfyUI-BFSNodes.git
fi

# 安装 ComfyUI-Manager（确保内置）
pip install -U --pre comfyui-manager

# ----------------------------- 5. Manager 安全配置 -----------------------------
info "配置 ComfyUI Manager 安全策略..."
mkdir -p "$COMFYUI_DIR/user/__manager"
cat > "$COMFYUI_DIR/user/__manager/config.ini" << 'EOF'
[default]
security_level = normal
network_mode = personal_cloud
EOF

# ----------------------------- 6. 下载所有模型 -----------------------------
info "开始下载模型文件（约 65GB，视代理速度可能需要 2-4 小时）..."

# 创建所有模型目录
mkdir -p "$COMFYUI_DIR"/models/{diffusion_models,latent_upscale_models,loras/ltx-2.3,text_encoders/ltx2,text_encoders/ltx2.3,vae/ltx2.3}

# 定义下载函数，失败后重试一次
download_with_retry() {
    for i in 1 2; do
        if hf download "$1" "$2" --local-dir "$3"; then
            return 0
        fi
        warn "下载失败，重试 ($i/2)"
    done
    error "模型下载失败: $1/$2"
}

# 基础模型
info "  [1/6] diffusion model"
download_with_retry Kijai/LTX2.3_comfy ltx-2.3-22b-distilled_transformer_only_fp8_input_scaled.safetensors "$COMFYUI_DIR/models/diffusion_models"

info "  [2/6] spatial upscaler"
download_with_retry Lightricks/LTX-2.3 ltx-2.3-spatial-upscaler-x2-1.1.safetensors "$COMFYUI_DIR/models/latent_upscale_models"

info "  [3/6] text encoder (gemma)"
download_with_retry Comfy-Org/ltx-2 split_files/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors "$COMFYUI_DIR/models/text_encoders"
# 移动可能多出的目录层级
if [ -f "$COMFYUI_DIR/models/text_encoders/split_files/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors" ]; then
    mv "$COMFYUI_DIR/models/text_encoders/split_files/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors" "$COMFYUI_DIR/models/text_encoders/ltx2/"
    rmdir -p "$COMFYUI_DIR/models/text_encoders/split_files/text_encoders/" 2>/dev/null || true
fi

info "  [4/6] text projection"
download_with_retry Kijai/LTX2.3_comfy ltx-2.3_text_projection_bf16.safetensors "$COMFYUI_DIR/models/text_encoders/ltx2.3"

info "  [5/6] video VAE"
download_with_retry Kijai/LTX2.3_comfy LTX23_video_vae_bf16.safetensors "$COMFYUI_DIR/models/vae"
info "  [6/6] audio VAE"
download_with_retry Kijai/LTX2.3_comfy LTX23_audio_vae_bf16.safetensors "$COMFYUI_DIR/models/vae"

# 移动 VAE 文件到 ltx2.3 子目录
mv "$COMFYUI_DIR/models/vae/LTX23_video_vae_bf16.safetensors" "$COMFYUI_DIR/models/vae/ltx2.3/" 2>/dev/null || true
mv "$COMFYUI_DIR/models/vae/LTX23_audio_vae_bf16.safetensors" "$COMFYUI_DIR/models/vae/ltx2.3/" 2>/dev/null || true

# LoRA 模型（换脸必需）
info "下载 LoRA 模型..."
download_with_retry Alissonerdx/BFS-Best-Face-Swap-Video ltx-2.3/head_swap_v3_rank_64.safetensors "$COMFYUI_DIR/models/loras"
download_with_retry Alissonerdx/BFS-Best-Face-Swap-Video ltx-2.3/head_swap_v3_rank_adaptive_fro_098.safetensors "$COMFYUI_DIR/models/loras"

info "所有模型下载完成。"

# ----------------------------- 7. 启动 ComfyUI -----------------------------
info "启动 ComfyUI..."
pkill -9 -f "python main.py" 2>/dev/null || true
sleep 2

nohup bash -c "
    export http_proxy=http://127.0.0.1:$CLASH_PORT
    export https_proxy=http://127.0.0.1:$CLASH_PORT
    export all_proxy=http://127.0.0.1:$CLASH_PORT
    export HSA_OVERRIDE_GFX_VERSION=11.0.0
    cd $COMFYUI_DIR
    python main.py --listen 0.0.0.0 --port $COMFYUI_PORT --enable-manager --enable-cors-header '*'
" > "$WORKDIR/comfyui.log" 2>&1 &
sleep 5

if ! curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$COMFYUI_PORT | grep -q 200; then
    error "ComfyUI 启动失败，查看日志: tail -30 $WORKDIR/comfyui.log"
fi
info "ComfyUI 已在后台运行，端口: $COMFYUI_PORT"

# ----------------------------- 8. 创建公网隧道 -----------------------------
info "建立 Cloudflare 隧道..."
cd "$WORKDIR"
wget -c "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -O cloudflared
chmod +x cloudflared

nohup ./cloudflared tunnel --url http://127.0.0.1:$COMFYUI_PORT > "$WORKDIR/tunnel.log" 2>&1 &
sleep 8

TUNNEL_URL=$(grep -o 'https://[^ ]*trycloudflare.com' "$WORKDIR/tunnel.log" | tail -1)
if [ -z "$TUNNEL_URL" ]; then
    warn "获取隧道地址失败，请稍后执行：grep -o 'https://[^ ]*trycloudflare.com' $WORKDIR/tunnel.log"
else
    info "公网访问地址：$TUNNEL_URL"
fi

# ----------------------------- 完成 -----------------------------
echo ""
echo "=============================================="
echo " BFS ComfyUI 部署完成！"
echo " 工作目录: $COMFYUI_DIR"
echo " 本地地址: http://127.0.0.1:$COMFYUI_PORT"
echo " 公网地址: $TUNNEL_URL"
echo ""
echo " 首次使用请务必："
echo " 1. 打开上面网址，在 Manager → Install Missing Custom Nodes 安装缺失节点"
echo " 2. 重启 ComfyUI 后，加载 BFS 工作流即可开始使用"
echo "=============================================="