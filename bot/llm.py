"""Thin async client for llama-server's OpenAI-compatible API.

Only what the bot needs: streaming chat completions, a health probe and the model
list. llama-server ignores the API key, but it is sent so this also works against
an OpenAI-compatible proxy.
"""

from __future__ import annotations

import json
from typing import AsyncIterator, Iterable

import httpx


class LLMError(RuntimeError):
    """Anything that stops a completion from being delivered."""


def _client(base_url: str, api_key: str, connect_timeout: float) -> httpx.AsyncClient:
    # read=None is deliberate: prompt processing on a long context can be silent for
    # a minute, and a short read timeout kills perfectly healthy streams.
    timeout = httpx.Timeout(connect=connect_timeout, read=None, write=120.0, pool=10.0)
    return httpx.AsyncClient(
        base_url=base_url.rstrip("/"),
        timeout=timeout,
        headers={"Authorization": f"Bearer {api_key}"},
    )


async def stream_chat(
    *,
    base_url: str,
    api_key: str,
    model: str,
    messages: Iterable[dict],
    max_tokens: int,
    temperature: float,
    top_p: float,
    enable_thinking: bool = False,
    connect_timeout: float = 10.0,
) -> AsyncIterator[str]:
    """Yield content deltas as they arrive.

    Reasoning models emit ``reasoning_content`` deltas separately; those are
    dropped on purpose so chain-of-thought never lands in a Discord message.
    """
    payload: dict = {
        "model": model,
        "messages": list(messages),
        "stream": True,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": top_p,
    }
    if not enable_thinking:
        payload["chat_template_kwargs"] = {"enable_thinking": False}

    async with _client(base_url, api_key, connect_timeout) as client:
        try:
            async with client.stream("POST", "/v1/chat/completions", json=payload) as response:
                if response.status_code >= 400:
                    body = (await response.aread()).decode("utf-8", "replace")
                    raise LLMError(f"llama-server returned {response.status_code}: {body[:800]}")
                async for line in response.aiter_lines():
                    if not line or line.startswith(":"):
                        continue  # keep-alive ping
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    choices = chunk.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    text = delta.get("content")
                    if text:
                        yield text
        except httpx.HTTPError as exc:
            raise LLMError(f"could not reach llama-server at {base_url}: {exc}") from exc


async def health(base_url: str, api_key: str, connect_timeout: float = 4.0) -> dict:
    """llama-server answers 503 while a model is still loading."""
    try:
        async with httpx.AsyncClient(
            base_url=base_url.rstrip("/"), timeout=connect_timeout
        ) as client:
            response = await client.get("/health")
            return {"status_code": response.status_code, "body": _safe_json(response)}
    except httpx.HTTPError as exc:
        return {"status_code": 0, "body": {"error": str(exc)}}


async def models(base_url: str, api_key: str, connect_timeout: float = 4.0) -> list[str]:
    try:
        async with _client(base_url, api_key, connect_timeout) as client:
            response = await client.get("/v1/models")
            response.raise_for_status()
            data = response.json()
            return [entry.get("id", "?") for entry in data.get("data", [])]
    except (httpx.HTTPError, ValueError):
        return []


def _safe_json(response: httpx.Response) -> dict:
    try:
        value = response.json()
        return value if isinstance(value, dict) else {"value": value}
    except ValueError:
        return {"text": response.text[:200]}
