#!/usr/bin/env bash
# =============================================================================
#  setup-vllm-cpu.sh  -  run a small local vLLM (CPU only) for APEX testing
#
#  Starts the official vLLM CPU image on the host network, listening on
#  127.0.0.1:${VLLM_PORT} (default 8000), OpenAI-compatible API under /v1.
#  The Oracle container (DB_NETWORK=host) reaches it as http://localhost:8000.
#
#  Usage:  sudo ./setup-vllm-cpu.sh            # start / restart
#          sudo ./setup-vllm-cpu.sh --stop     # stop and remove
#  Env:    VLLM_MODEL (default Qwen/Qwen3.5-0.8B), VLLM_PORT, VLLM_DTYPE,
#          VLLM_MAX_LEN, VLLM_KV_GB, VLLM_IMAGE, VLLM_API_KEY, HF_TOKEN
# =============================================================================
set -Eeuo pipefail

VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai-cpu:latest-x86_64}"
VLLM_CONTAINER="${VLLM_CONTAINER:-vllm}"
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen3.5-0.8B}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_DTYPE="${VLLM_DTYPE:-bfloat16}"
VLLM_MAX_LEN="${VLLM_MAX_LEN:-4096}"
VLLM_KV_GB="${VLLM_KV_GB:-1}"
VLLM_API_KEY="${VLLM_API_KEY:-}"
HF_CACHE="${HF_CACHE:-/opt/vllm/hf-cache}"
READY_TIMEOUT="${READY_TIMEOUT:-1200}"

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker is required (run install-oracle-26ai.sh first)." >&2; exit 1; }

if [[ "${1:-}" == "--stop" ]]; then
  docker rm -f "$VLLM_CONTAINER" >/dev/null 2>&1 || true
  echo "vLLM stopped."; exit 0
fi

[[ "$(uname -m)" == "x86_64" ]] || VLLM_IMAGE="${VLLM_IMAGE/x86_64/arm64}"
grep -qw avx2 /proc/cpuinfo || { echo "CPU lacks AVX2; vLLM CPU backend needs AVX2 or AVX512." >&2; exit 1; }
grep -qw avx512f /proc/cpuinfo || echo "Note: no AVX512 - vLLM runs in AVX2 mode (slower, limited features)."

mkdir -p "$HF_CACHE"
docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 || docker pull "$VLLM_IMAGE"
docker rm -f "$VLLM_CONTAINER" >/dev/null 2>&1 || true

extra=()
[[ -n "$VLLM_API_KEY" ]] && extra+=(--api-key "$VLLM_API_KEY")

echo "Starting ${VLLM_MODEL} on 127.0.0.1:${VLLM_PORT} (dtype ${VLLM_DTYPE}, KV ${VLLM_KV_GB} GiB)"
docker run -d --name "$VLLM_CONTAINER" \
  --restart unless-stopped \
  --network host \
  --cap-add SYS_NICE --security-opt seccomp=unconfined --shm-size=2g \
  -e VLLM_CPU_KVCACHE_SPACE="$VLLM_KV_GB" \
  -e VLLM_CPU_NUM_OF_RESERVED_CPU=1 \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  "$VLLM_IMAGE" \
  --model "$VLLM_MODEL" \
  --host 127.0.0.1 --port "$VLLM_PORT" \
  --dtype "$VLLM_DTYPE" \
  --max-model-len "$VLLM_MAX_LEN" \
  --served-model-name "$VLLM_MODEL" \
  --enforce-eager \
  --limit-mm-per-prompt '{"image":0,"video":0}' \
  "${extra[@]}" >/dev/null

echo "Waiting for vLLM (model download + load, timeout ${READY_TIMEOUT}s)..."
auth=(); [[ -n "$VLLM_API_KEY" ]] && auth=(-H "Authorization: Bearer ${VLLM_API_KEY}")
for ((t = 0; t < READY_TIMEOUT; t += 10)); do
  if curl -sf "${auth[@]}" "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null; then
    echo "vLLM is ready:"; curl -s "${auth[@]}" "http://127.0.0.1:${VLLM_PORT}/v1/models"; echo
    exit 0
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$VLLM_CONTAINER" 2>/dev/null)" != "true" ]]; then
    docker logs --tail 60 "$VLLM_CONTAINER" >&2; echo "vLLM container exited." >&2; exit 1
  fi
  sleep 10
done
docker logs --tail 60 "$VLLM_CONTAINER" >&2
echo "vLLM not ready after ${READY_TIMEOUT}s." >&2; exit 1
