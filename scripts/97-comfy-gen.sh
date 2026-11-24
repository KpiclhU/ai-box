#!/usr/bin/env bash
# 97-comfy-gen.sh — render one image through ComfyUI from the terminal.
#
#   ./scripts/97-comfy-gen.sh "a corgi astronaut, cinematic lighting"
#   ./scripts/97-comfy-gen.sh "prompt" -W 1216 -H 832 --steps 30 --seed 7 -o ~/ai/images
#   ./scripts/97-comfy-gen.sh "prompt" -m juggernautXL_v9.safetensors
#
# This is also how Llama Chat gets image generation: llama.cpp has no image tool of its own
# (its built-in tools are only the file/shell set), but with
#   LLAMA_EXTRA_ARGS="... --tools exec_shell_command"
# the model can run this script, and the chat shows the PNG path it prints.
#
# Workflow: workflows/sdxl.api.json, nodes found by class type (not hard-coded ids).
set -euo pipefail

AI_HOME="${AI_HOME:-$HOME/ai}"
COMFY="${COMFYUI_DIR:-$AI_HOME/comfyui}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${COMFY_WORKFLOW:-$REPO/workflows/sdxl.api.json}"
BASE="${COMFY_URL:-http://127.0.0.1:8188}"
OUT="${COMFY_OUT:-$AI_HOME/images}"

die()   { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

PROMPT=""
NEGATIVE=""
WIDTH=1024
HEIGHT=1024
STEPS=""
CFG=""
SEED=""
CHECKPOINT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--negative) NEGATIVE="${2:-}"; shift 2 ;;
    -W|--width)    WIDTH="${2:-}";    shift 2 ;;
    -H|--height)   HEIGHT="${2:-}";   shift 2 ;;
    -s|--steps)    STEPS="${2:-}";    shift 2 ;;
    -c|--cfg)      CFG="${2:-}";      shift 2 ;;
    --seed)        SEED="${2:-}";     shift 2 ;;
    -m|--model)    CHECKPOINT="${2:-}"; shift 2 ;;
    -o|--out)      OUT="${2:-}";      shift 2 ;;
    -h|--help)     usage 0 ;;
    -*)            die "unknown option: $1 (try --help)" ;;
    *)             PROMPT="$1"; shift ;;
  esac
done

[ -n "$PROMPT" ] || usage 1
[ -f "$WORKFLOW" ] || die "workflow not found: $WORKFLOW (set COMFY_WORKFLOW)"
command -v python3 >/dev/null 2>&1 || die "python3 missing"
mkdir -p "$OUT"

COMFY_BASE="$BASE" COMFY_WORKFLOW="$WORKFLOW" COMFY_OUT="$OUT" \
COMFY_PROMPT="$PROMPT" COMFY_NEGATIVE="$NEGATIVE" COMFY_CHECKPOINT="$CHECKPOINT" \
COMFY_WIDTH="$WIDTH" COMFY_HEIGHT="$HEIGHT" COMFY_STEPS="$STEPS" COMFY_CFG="$CFG" \
COMFY_SEED="$SEED" COMFY_TIMEOUT="${COMFY_TIMEOUT:-900}" \
python3 - <<'PY'
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

SAMPLERS = {"KSampler", "KSamplerAdvanced"}
LATENTS = {"EmptyLatentImage", "EmptySD3LatentImage", "EmptyLatentImagePresets"}
CHECKPOINTS = {"CheckpointLoaderSimple", "CheckpointLoader"}

base = os.environ["COMFY_BASE"].rstrip("/")
workflow_path = os.environ["COMFY_WORKFLOW"]
out_dir = os.environ["COMFY_OUT"]
timeout_s = float(os.environ["COMFY_TIMEOUT"] or 900)


def fail(message):
    print("error: " + message, file=sys.stderr)
    raise SystemExit(1)


def request(path, payload=None, timeout=120):
    url = base + path
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:800]
        fail("%s %s -> HTTP %s: %s" % ("POST" if data else "GET", path, exc.code, body))
    except urllib.error.URLError as exc:
        fail("cannot reach ComfyUI at %s (%s)" % (base, exc.reason))


def get_json(path, timeout=30):
    return json.loads(request(path, timeout=timeout).decode() or "{}")


with open(workflow_path, encoding="utf-8") as handle:
    workflow = json.load(handle)


def first_of(classes):
    for node_id, node in workflow.items():
        if isinstance(node, dict) and node.get("class_type") in classes:
            return node_id, node
    return None, None


sampler_id, sampler = first_of(SAMPLERS)
if sampler is None:
    fail("workflow has no KSampler node: %s" % workflow_path)
inputs = sampler.setdefault("inputs", {})

prompt = os.environ["COMFY_PROMPT"]
negative = os.environ.get("COMFY_NEGATIVE") or ""
positive_id = (inputs.get("positive") or [None])[0]
if positive_id not in workflow:
    fail("KSampler.positive does not link to a prompt node")
workflow[positive_id].setdefault("inputs", {})["text"] = prompt
if negative:
    negative_id = (inputs.get("negative") or [None])[0]
    if negative_id in workflow:
        workflow[negative_id].setdefault("inputs", {})["text"] = negative

seed = os.environ.get("COMFY_SEED") or ""
seed = int(seed) if seed.strip() else random.randint(0, 2**31 - 1)
inputs["seed"] = seed
if os.environ.get("COMFY_STEPS", "").strip():
    inputs["steps"] = int(os.environ["COMFY_STEPS"])
if os.environ.get("COMFY_CFG", "").strip():
    inputs["cfg"] = float(os.environ["COMFY_CFG"])

latent_id = (inputs.get("latent_image") or [None])[0]
if latent_id in workflow:
    latent = workflow[latent_id].setdefault("inputs", {})
    for key, value in (("width", os.environ["COMFY_WIDTH"]), ("height", os.environ["COMFY_HEIGHT"])):
        if str(value).strip():
            latent[key] = max(64, min(2048, int(value) // 8 * 8))

checkpoint = os.environ.get("COMFY_CHECKPOINT") or ""
if checkpoint:
    _, loader = first_of(CHECKPOINTS)
    if loader is not None:
        loader.setdefault("inputs", {})["ckpt_name"] = checkpoint
    else:
        _, unet = first_of({"UNETLoader"})
        if unet is not None:
            unet.setdefault("inputs", {})["unet_name"] = checkpoint

print("queued %dx%d, %s steps, seed %d"
      % (int(workflow[latent_id]["inputs"]["width"]) if latent_id in workflow else 0,
         int(workflow[latent_id]["inputs"]["height"]) if latent_id in workflow else 0,
         inputs.get("steps", "default"), seed), file=sys.stderr)

body = json.loads(request("/prompt", {"prompt": workflow, "client_id": str(uuid.uuid4())}).decode())
prompt_id = body.get("prompt_id")
if not prompt_id:
    fail("ComfyUI returned no prompt_id: %r" % body)

deadline = time.monotonic() + timeout_s
entry = None
while time.monotonic() < deadline:
    time.sleep(0.75)
    try:
        payload = get_json("/history/%s" % prompt_id)
    except SystemExit:
        raise
    except Exception:
        continue
    entry = payload.get(prompt_id)
    if not entry:
        continue
    status = entry.get("status") or {}
    if status.get("status_str") == "error":
        fail("ComfyUI execution error: %s" % (status.get("messages") or "unknown"))
    if entry.get("outputs") or status.get("completed"):
        break
else:
    fail("job %s did not finish within %ss (the first run compiles kernels; retry, it is cached)"
         % (prompt_id, int(timeout_s)))

images = [image
          for node_output in (entry or {}).get("outputs", {}).values()
          for image in node_output.get("images", [])
          if image.get("type") != "temp"]
if not images:
    fail("job finished but produced no image")

image = images[0]
query = urllib.parse.urlencode({
    "filename": image["filename"],
    "subfolder": image.get("subfolder", ""),
    "type": image.get("type", "output"),
})
data = request("/view?" + query, timeout=180)

stamp = time.strftime("%Y%m%d-%H%M%S")
path = os.path.join(out_dir, "comfy-%s-%d.png" % (stamp, seed))
with open(path, "wb") as handle:
    handle.write(data)

try:
    request("/free", {"unload_models": False, "free_memory": True}, timeout=20)
except SystemExit:
    print("note: /free failed; ComfyUI keeps its cached weights", file=sys.stderr)

print(path)
PY
