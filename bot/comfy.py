"""ComfyUI HTTP client.

Nodes are located by class type rather than hard-coded ids, so re-exporting the
workflow from the ComfyUI UI (or swapping in a similar graph) does not break the
bot: find the KSampler, follow its links to the prompt, latent and checkpoint.

The API contract used here:
    POST /prompt            -> {"prompt_id": ...}
    GET  /history/<id>      -> {"<id>": {"outputs": {...}, "status": {...}}}
    GET  /view              -> image bytes
    POST /free              -> drop cached allocations between jobs
"""

from __future__ import annotations

import asyncio
import copy
import json
import random
import time
import uuid
from pathlib import Path
from typing import Any

import httpx

SAMPLER_CLASSES = {"KSampler", "KSamplerAdvanced"}
LATENT_CLASSES = {"EmptyLatentImage", "EmptySD3LatentImage", "EmptyLatentImagePresets"}
CHECKPOINT_CLASSES = {"CheckpointLoaderSimple", "CheckpointLoader", "UNETLoader"}


class ComfyError(RuntimeError):
    """ComfyUI refused the job or never finished it."""


class ComfyClient:
    def __init__(
        self,
        base_url: str,
        workflow_path: Path,
        checkpoint: str | None = None,
        timeout_s: int = 900,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.workflow_path = Path(workflow_path)
        self.checkpoint = checkpoint or None
        self.timeout_s = timeout_s
        if not self.workflow_path.is_file():
            raise ComfyError(f"workflow not found: {self.workflow_path}")
        self._template: dict[str, Any] = json.loads(self.workflow_path.read_text(encoding="utf-8"))

    # -- workflow shaping -----------------------------------------------------
    @staticmethod
    def _first_of(wf: dict[str, Any], classes: set[str]) -> tuple[str | None, dict | None]:
        for node_id, node in wf.items():
            if isinstance(node, dict) and node.get("class_type") in classes:
                return node_id, node
        return None, None

    def build_workflow(
        self,
        prompt: str,
        *,
        negative: str | None = None,
        steps: int | None = None,
        cfg: float | None = None,
        width: int | None = None,
        height: int | None = None,
        seed: int | None = None,
    ) -> tuple[dict[str, Any], int, int]:
        wf = copy.deepcopy(self._template)

        sampler_id, sampler = self._first_of(wf, SAMPLER_CLASSES)
        if sampler is None:
            raise ComfyError("workflow has no KSampler node")
        inputs = sampler.setdefault("inputs", {})

        positive_id = (inputs.get("positive") or [None])[0]
        negative_id = (inputs.get("negative") or [None])[0]
        if positive_id in wf:
            wf[positive_id].setdefault("inputs", {})["text"] = prompt
        else:
            raise ComfyError("KSampler.positive does not link to a prompt node")
        if negative and negative_id in wf:
            wf[negative_id].setdefault("inputs", {})["text"] = negative

        actual_seed = int(seed) if seed is not None else random.randint(0, 2**31 - 1)
        inputs["seed"] = actual_seed
        if steps is not None:
            inputs["steps"] = int(steps)
        if cfg is not None:
            inputs["cfg"] = float(cfg)

        latent_id = (inputs.get("latent_image") or [None])[0]
        if latent_id in wf and (width or height):
            latent_inputs = wf[latent_id].setdefault("inputs", {})
            # SDXL/Flux want multiples of 8; clamp instead of failing the job.
            if width:
                latent_inputs["width"] = max(64, min(2048, int(width) // 8 * 8))
            if height:
                latent_inputs["height"] = max(64, min(2048, int(height) // 8 * 8))

        if self.checkpoint:
            ckpt_id, ckpt = self._first_of(wf, {"CheckpointLoaderSimple", "CheckpointLoader"})
            if ckpt is not None:
                ckpt.setdefault("inputs", {})["ckpt_name"] = self.checkpoint
            unet_id, unet = self._first_of(wf, {"UNETLoader"})
            if ckpt is None and unet is not None:
                unet.setdefault("inputs", {})["unet_name"] = self.checkpoint

        actual_steps = int(inputs.get("steps", 0))
        return wf, actual_seed, actual_steps

    # -- execution ------------------------------------------------------------
    async def generate(
        self,
        prompt: str,
        *,
        negative: str | None = None,
        steps: int | None = None,
        cfg: float | None = None,
        width: int | None = None,
        height: int | None = None,
        seed: int | None = None,
        free_after: bool = True,
    ) -> dict[str, Any]:
        """Queue one job and wait for its first output image.

        Returns a dict with the PNG bytes plus the metadata Discord shows back.
        """
        workflow, actual_seed, actual_steps = self.build_workflow(
            prompt,
            negative=negative,
            steps=steps,
            cfg=cfg,
            width=width,
            height=height,
            seed=seed,
        )
        client_id = str(uuid.uuid4())
        timeout = httpx.Timeout(connect=10.0, read=None, write=120.0, pool=10.0)

        async with httpx.AsyncClient(base_url=self.base_url, timeout=timeout) as client:
            try:
                response = await client.post(
                    "/prompt", json={"prompt": workflow, "client_id": client_id}
                )
            except httpx.HTTPError as exc:
                raise ComfyError(f"could not reach ComfyUI at {self.base_url}: {exc}") from exc

            body = _json_or_text(response)
            if response.status_code >= 400 or (isinstance(body, dict) and body.get("error")):
                detail = body
                if isinstance(body, dict) and body.get("node_errors"):
                    detail = {"error": body.get("error"), "node_errors": body["node_errors"]}
                raise ComfyError(f"ComfyUI rejected the job: {detail}")

            prompt_id = body.get("prompt_id") if isinstance(body, dict) else None
            if not prompt_id:
                raise ComfyError(f"no prompt_id in response: {body}")

            history = await self._wait_for(client, prompt_id)
            images = [
                image
                for node_output in history.get("outputs", {}).values()
                for image in node_output.get("images", [])
                if image.get("type") != "temp"
            ]
            if not images:
                raise ComfyError("job finished but produced no images")

            image = images[0]
            try:
                view = await client.get(
                    "/view",
                    params={
                        "filename": image["filename"],
                        "subfolder": image.get("subfolder", ""),
                        "type": image.get("type", "output"),
                    },
                )
                view.raise_for_status()
            except httpx.HTTPError as exc:
                raise ComfyError(f"could not fetch the image: {exc}") from exc

            if free_after:
                try:
                    await client.post(
                        "/free", json={"unload_models": False, "free_memory": True}
                    )
                except httpx.HTTPError:
                    pass  # cosmetic: a failed flush must not fail the request

            return {
                "bytes": view.content,
                "filename": image["filename"],
                "seed": actual_seed,
                "steps": actual_steps,
                "prompt_id": prompt_id,
            }

    async def _wait_for(self, client: httpx.AsyncClient, prompt_id: str) -> dict:
        deadline = time.monotonic() + self.timeout_s
        while time.monotonic() < deadline:
            await asyncio.sleep(0.75)
            try:
                response = await client.get(f"/history/{prompt_id}")
                payload = response.json()
            except (httpx.HTTPError, ValueError):
                continue
            entry = payload.get(prompt_id)
            if not entry:
                continue
            status = entry.get("status") or {}
            if status.get("status_str") == "error":
                messages = status.get("messages") or []
                raise ComfyError(f"ComfyUI execution error: {messages[-1:] or 'unknown'}")
            if entry.get("outputs") or status.get("completed"):
                return entry
        raise ComfyError(
            f"job {prompt_id} did not finish within {self.timeout_s}s "
            "(first run compiles kernels and can be very slow)"
        )

    async def queue(self) -> dict:
        try:
            async with httpx.AsyncClient(base_url=self.base_url, timeout=5.0) as client:
                payload = (await client.get("/queue")).json()
            return {
                "running": len(payload.get("queue_running", [])),
                "pending": len(payload.get("queue_pending", [])),
            }
        except (httpx.HTTPError, ValueError):
            return {"running": 0, "pending": 0}

    async def stats(self) -> dict:
        try:
            async with httpx.AsyncClient(base_url=self.base_url, timeout=5.0) as client:
                payload = (await client.get("/system_stats")).json()
            device = (payload.get("devices") or [{}])[0]
            return {
                "device": device.get("name", "?"),
                "vram_total": device.get("vram_total", 0),
                "vram_free": device.get("vram_free", 0),
            }
        except (httpx.HTTPError, ValueError, IndexError):
            return {}


def _json_or_text(response: httpx.Response) -> Any:
    try:
        return response.json()
    except ValueError:
        return response.text[:500]
