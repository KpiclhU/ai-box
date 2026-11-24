#!/usr/bin/env python3
"""comfy-mcp.py — a stdio MCP server that gives a model ComfyUI image generation.

Stdlib only: no `mcp` SDK, no httpx, no venv to create. MCP's stdio transport is JSON-RPC
2.0 as newline-delimited JSON, which is exactly what this speaks — one object per line in
on stdin, one per line out on stdout. Everything human-readable goes to stderr, because a
stray print() on stdout corrupts the protocol and llama-server drops the server.

Tools (llama.cpp prefixes them with the key from mcp.json, so `comfyui_generate_image`):
    generate_image   prompt/negative/size/steps/cfg/seed/checkpoint -> PNG path + view URL
    list_models      checkpoints / diffusion models ComfyUI can actually load
    status           device, VRAM, queue depth
    free_memory      POST /free: drop ComfyUI's cached weights, keep the queue

The graph is shaped the same way as 97-comfy-gen.sh: nodes are found by class type rather
than id, so a workflow re-exported from the UI keeps working.

Environment:
    COMFY_URL        default http://127.0.0.1:8188
    COMFY_PUBLIC_URL base of the link handed back to the model, e.g.
                     https://ai-image.example.com (default: COMFY_URL)
    COMFY_WORKFLOW   default <repo>/workflows/sdxl.api.json
    COMFY_CHECKPOINT override the ckpt_name baked into the workflow (empty = leave it)
    COMFY_PREFIX     SaveImage filename_prefix, default "chat"
    COMFY_TIMEOUT    seconds to wait for a job, default 900
    COMFYUI_DIR      default ~/ai/comfyui (only used to print the on-disk path)
"""

from __future__ import annotations

import copy
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

NAME = "comfyui"
VERSION = "1.0.0"
DEFAULT_PROTOCOL = "2025-06-18"

REPO = Path(__file__).resolve().parent.parent
BASE = os.environ.get("COMFY_URL", "http://127.0.0.1:8188").rstrip("/")
# The API call is from this box; the link the user clicks may be opened elsewhere.
# Set COMFY_PUBLIC_URL when the browser reaches ComfyUI at a different address.
PUBLIC = (os.environ.get("COMFY_PUBLIC_URL") or BASE).rstrip("/")
WORKFLOW = Path(os.environ.get("COMFY_WORKFLOW") or REPO / "workflows" / "sdxl.api.json")
COMFY_DIR = Path(os.environ.get("COMFYUI_DIR") or Path.home() / "ai" / "comfyui")
CHECKPOINT = (os.environ.get("COMFY_CHECKPOINT") or "").strip()
PREFIX = os.environ.get("COMFY_PREFIX") or "chat"
TIMEOUT = float(os.environ.get("COMFY_TIMEOUT") or 900)

SAMPLERS = {"KSampler", "KSamplerAdvanced"}
LATENTS = {"EmptyLatentImage", "EmptySD3LatentImage", "EmptyLatentImagePresets"}
CHECKPOINTS = {"CheckpointLoaderSimple", "CheckpointLoader"}
UNETS = {"UNETLoader", "UnetLoaderGGUF"}
SAVERS = {"SaveImage", "SaveImageWebP"}


class ToolError(RuntimeError):
    """A tool call that failed in a way the model should read and react to."""


class RPCError(RuntimeError):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def log(message: str) -> None:
    print("comfy-mcp: " + message, file=sys.stderr, flush=True)


# -- HTTP ---------------------------------------------------------------------
def http(path: str, payload=None, timeout: float = 60.0) -> bytes:
    url = BASE + path
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace").strip()
        raise ToolError(
            "ComfyUI %s %s -> HTTP %s: %s"
            % ("POST" if data else "GET", path, exc.code, body[:600] or "(empty body)")
        ) from None
    except urllib.error.URLError as exc:
        raise ToolError(
            "cannot reach ComfyUI at %s (%s) — is comfyui.service running?" % (BASE, exc.reason)
        ) from None
    except OSError as exc:
        raise ToolError("cannot reach ComfyUI at %s (%s)" % (BASE, exc)) from None


def http_json(path: str, payload=None, timeout: float = 30.0):
    raw = http(path, payload, timeout=timeout)
    try:
        return json.loads(raw.decode("utf-8") or "{}")
    except ValueError:
        raise ToolError("ComfyUI returned non-JSON from %s: %r" % (path, raw[:200])) from None


# -- workflow shaping ---------------------------------------------------------
def first_of(workflow: dict, classes: set[str]):
    for node_id, node in workflow.items():
        if isinstance(node, dict) and node.get("class_type") in classes:
            return node_id, node
    return None, None


def build_workflow(args: dict):
    if not WORKFLOW.is_file():
        raise ToolError("workflow not found: %s (set COMFY_WORKFLOW)" % WORKFLOW)
    try:
        workflow = json.loads(WORKFLOW.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise ToolError("workflow is not valid JSON: %s (%s)" % (WORKFLOW, exc)) from None

    prompt = str(args.get("prompt") or "").strip()
    if not prompt:
        raise ToolError("prompt is required — pass a concrete visual description")

    _, sampler = first_of(workflow, SAMPLERS)
    if sampler is None:
        raise ToolError("workflow has no KSampler node: %s" % WORKFLOW)
    inputs = sampler.setdefault("inputs", {})

    positive_id = (inputs.get("positive") or [None])[0]
    if positive_id not in workflow:
        raise ToolError("KSampler.positive does not link to a prompt node")
    workflow[positive_id].setdefault("inputs", {})["text"] = prompt

    negative = str(args.get("negative") or "").strip()
    if negative:
        negative_id = (inputs.get("negative") or [None])[0]
        if negative_id in workflow:
            workflow[negative_id].setdefault("inputs", {})["text"] = negative

    seed = args.get("seed")
    seed = int(seed) if seed not in (None, "") else random.randint(0, 2**31 - 1)
    inputs["seed"] = seed
    if args.get("steps") not in (None, ""):
        inputs["steps"] = max(1, min(150, int(args["steps"])))
    if args.get("cfg") not in (None, ""):
        inputs["cfg"] = max(0.0, min(30.0, float(args["cfg"])))

    width = height = None
    latent_id = (inputs.get("latent_image") or [None])[0]
    if latent_id in workflow:
        latent = workflow[latent_id].setdefault("inputs", {})
        for key in ("width", "height"):
            value = args.get(key)
            if value not in (None, ""):
                # SDXL/Flux want multiples of 8; clamp rather than fail the job.
                latent[key] = max(64, min(2048, int(value) // 8 * 8))
        width, height = latent.get("width"), latent.get("height")

    checkpoint = str(args.get("checkpoint") or CHECKPOINT or "").strip()
    if checkpoint:
        _, loader = first_of(workflow, CHECKPOINTS)
        if loader is not None:
            loader.setdefault("inputs", {})["ckpt_name"] = checkpoint
        else:
            _, unet = first_of(workflow, UNETS)
            if unet is None:
                raise ToolError("workflow has no checkpoint or UNET loader node")
            unet.setdefault("inputs", {})["unet_name"] = checkpoint

    _, saver = first_of(workflow, SAVERS)
    if saver is not None:
        saver.setdefault("inputs", {})["filename_prefix"] = PREFIX

    meta = {
        "seed": seed,
        "steps": inputs.get("steps"),
        "cfg": inputs.get("cfg"),
        "width": width,
        "height": height,
        "checkpoint": checkpoint or (first_of(workflow, CHECKPOINTS)[1] or {}).get("inputs", {}).get("ckpt_name"),
    }
    return workflow, meta


def wait_for(prompt_id: str) -> dict:
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        time.sleep(0.75)
        payload = http_json("/history/%s" % prompt_id, timeout=30)
        entry = payload.get(prompt_id)
        if not entry:
            continue
        status = entry.get("status") or {}
        if status.get("status_str") == "error":
            raise ToolError("ComfyUI execution error: %s" % (status.get("messages") or "unknown"))
        if entry.get("outputs") or status.get("completed"):
            return entry
    raise ToolError(
        "job %s did not finish within %ss. The first run after an install compiles kernels "
        "and can take many minutes; retry it once, the cache makes it a one-off."
        % (prompt_id, int(TIMEOUT))
    )


# -- tools --------------------------------------------------------------------
def tool_generate_image(args: dict) -> str:
    workflow, meta = build_workflow(args)
    body = http_json("/prompt", {"prompt": workflow, "client_id": str(uuid.uuid4())}, timeout=180)
    if body.get("error") or body.get("node_errors"):
        raise ToolError("ComfyUI rejected the job: %s" % json.dumps(body)[:700])
    prompt_id = body.get("prompt_id")
    if not prompt_id:
        raise ToolError("ComfyUI returned no prompt_id: %r" % body)

    entry = wait_for(prompt_id)
    images = [
        image
        for node_output in (entry.get("outputs") or {}).values()
        for image in node_output.get("images", [])
        if image.get("type") != "temp"
    ]
    if not images:
        raise ToolError("job finished but produced no image")

    image = images[0]
    query = urllib.parse.urlencode(
        {
            "filename": image["filename"],
            "subfolder": image.get("subfolder", ""),
            "type": image.get("type", "output"),
        }
    )
    url = "%s/view?%s" % (PUBLIC, query)
    path = COMFY_DIR / "output" / (image.get("subfolder") or "") / image["filename"]
    size = "%sx%s" % (meta["width"] or "workflow", meta["height"] or "workflow")

    return "\n".join(
        [
            "Rendered 1 image: %s, %s steps, cfg %s, seed %s."
            % (size, meta["steps"], meta["cfg"], meta["seed"]),
            "file: %s" % path,
            "url: %s" % url,
            "![generated image](%s)" % url,
            "",
            "Reply with one short sentence and the markdown image line above so the user sees "
            "the picture. Do not describe the image as if you had looked at it.",
        ]
    )


def node_options(node: str, field: str):
    try:
        info = http_json("/object_info/%s" % node, timeout=20)
    except ToolError:
        return None
    spec = (((info.get(node) or {}).get("input") or {}).get("required") or {}).get(field)
    if not isinstance(spec, list) or not spec or not isinstance(spec[0], list):
        return None
    return [value for value in spec[0] if isinstance(value, str)]


def disk_models(*folders: str):
    found = []
    for folder in folders:
        directory = COMFY_DIR / "models" / folder
        if not directory.is_dir():
            continue
        for item in sorted(directory.rglob("*")):
            if item.suffix.lower() in {".safetensors", ".ckpt", ".pt", ".pth", ".gguf"}:
                try:
                    size = item.stat().st_size / 2**30
                except OSError:
                    size = 0.0
                found.append("%s (%.1f GB)" % (item.relative_to(directory), size))
    return found


def tool_list_models(args: dict) -> str:
    kind = str(args.get("kind") or "").strip().lower()
    groups = []
    if kind in ("", "checkpoints", "checkpoint"):
        names = node_options("CheckpointLoaderSimple", "ckpt_name")
        if names is None:
            names = disk_models("checkpoints")
            if names:
                names = [name.split(" (")[0] for name in names]
        groups.append(("checkpoints", names))
    if kind in ("", "diffusion", "diffusion_models", "unet"):
        names = node_options("UNETLoader", "unet_name") or node_options("UnetLoaderGGUF", "unet_name")
        if names is None:
            names = [name.split(" (")[0] for name in disk_models("diffusion_models", "unet")]
        groups.append(("diffusion_models", names))

    lines = []
    for label, names in groups:
        if not names:
            lines.append("%s: (none on disk — ./scripts/96-comfy-models.sh download ...)" % label)
            continue
        lines.append("%s (%d):" % (label, len(names)))
        lines.extend("  - %s" % name for name in names[:40])
        if len(names) > 40:
            lines.append("  ... and %d more" % (len(names) - 40))
    return "\n".join(lines)


def tool_status(args: dict) -> str:
    stats = http_json("/system_stats", timeout=15)
    device = (stats.get("devices") or [{}])[0]
    total = int(device.get("vram_total") or 0)
    free = int(device.get("vram_free") or 0)
    queue = http_json("/queue", timeout=15)
    lines = ["device: %s" % (device.get("name") or "unknown")]
    if total:
        lines.append("memory: %.1f GiB free of %.1f GiB" % (free / 2**30, total / 2**30))
    else:
        lines.append("memory: not reported (unified memory — watch amdgpu_top instead)")
    lines.append(
        "queue: %d running, %d pending"
        % (len(queue.get("queue_running") or []), len(queue.get("queue_pending") or []))
    )
    return "\n".join(lines)


def tool_free_memory(args: dict) -> str:
    http_json("/free", {"unload_models": True, "free_memory": True}, timeout=60)
    return "ComfyUI dropped its cached weights and freed memory. The queue is untouched."


TOOLS = [
    {
        "name": "generate_image",
        "description": (
            "Render one image with ComfyUI on this machine (SDXL by default; 15-30 s). "
            "Use it whenever the user asks for a picture, drawing, logo mock-up or art. "
            "Write a concrete visual prompt: subject, style, lighting, composition. "
            "Returns the file path and a URL plus a markdown image line to include in your reply."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "What to draw. Concrete and visual."},
                "negative": {
                    "type": "string",
                    "description": "What to avoid, e.g. 'text, watermark, blurry'.",
                },
                "width": {"type": "integer", "description": "Pixels, 64-2048, rounded to 8."},
                "height": {"type": "integer", "description": "Pixels, 64-2048, rounded to 8."},
                "steps": {"type": "integer", "description": "Sampling steps, 1-150 (SDXL: 20-30)."},
                "cfg": {"type": "number", "description": "Guidance scale (SDXL: 5-8)."},
                "seed": {"type": "integer", "description": "Fix it to reproduce a previous image."},
                "checkpoint": {
                    "type": "string",
                    "description": "Checkpoint file name; omit for the workflow default.",
                },
            },
            "required": ["prompt"],
        },
    },
    {
        "name": "list_models",
        "description": (
            "List the model files ComfyUI can load right now. Use it before naming a "
            "checkpoint in generate_image, so you never ask for a file that is not there."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "kind": {
                    "type": "string",
                    "enum": ["checkpoints", "diffusion_models"],
                    "description": "Restrict to one folder; omit for both.",
                }
            },
        },
    },
    {
        "name": "status",
        "description": (
            "ComfyUI device, free/total memory and queue depth. Check it before a heavy job "
            "if the machine is also serving the language model."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "free_memory",
        "description": (
            "Tell ComfyUI to unload its cached weights and free memory. Use after a job if "
            "the user is about to run the language model or something else needing memory."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
]

HANDLERS = {
    "generate_image": tool_generate_image,
    "list_models": tool_list_models,
    "status": tool_status,
    "free_memory": tool_free_memory,
}


# -- JSON-RPC -----------------------------------------------------------------
def dispatch(method: str, params: dict):
    if method == "initialize":
        requested = params.get("protocolVersion")
        return {
            # Echo the client's version: every revision so far uses this same shape, and
            # llama.cpp rejects a reply that does not match what it asked for.
            "protocolVersion": requested if isinstance(requested, str) and requested else DEFAULT_PROTOCOL,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": NAME, "version": VERSION},
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        name = params.get("name") or ""
        arguments = params.get("arguments") or {}
        handler = HANDLERS.get(name)
        if handler is None:
            raise RPCError(-32602, "unknown tool: %s" % name)
        try:
            text = handler(arguments if isinstance(arguments, dict) else {})
        except ToolError as exc:
            # Tool failures are results, not protocol errors: the model reads them and retries.
            return {"content": [{"type": "text", "text": "error: %s" % exc}], "isError": True}
        except Exception as exc:  # noqa: BLE001 - never take the server down mid-session
            log("tool %s crashed: %r" % (name, exc))
            return {"content": [{"type": "text", "text": "error: %s" % exc}], "isError": True}
        return {"content": [{"type": "text", "text": text}], "isError": False}
    raise RPCError(-32601, "method not found: %s" % method)


def send(message: dict) -> None:
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> int:
    for stream in (sys.stdin, sys.stdout):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    log("ready: ComfyUI at %s, links %s, workflow %s" % (BASE, PUBLIC, WORKFLOW))
    while True:
        line = sys.stdin.readline()
        if not line:
            return 0
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            log("ignoring non-JSON line: %r" % line[:120])
            continue
        if not isinstance(message, dict):
            continue
        method = message.get("method")
        if not isinstance(method, str):
            continue
        if "id" not in message:
            continue  # notification: initialized/cancelled — nothing to answer
        try:
            send({"jsonrpc": "2.0", "id": message["id"], "result": dispatch(method, message.get("params") or {})})
        except RPCError as exc:
            send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": exc.code, "message": exc.message}})
        except Exception as exc:  # noqa: BLE001
            log("internal error in %s: %r" % (method, exc))
            send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32603, "message": str(exc)}})


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0) from None
