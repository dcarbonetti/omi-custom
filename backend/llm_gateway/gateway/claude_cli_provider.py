"""Serve gateway chat lanes through the Claude Code CLI (``claude -p``) on this machine.

For a self-hosted desktop stack whose owner has a Claude subscription but no API key: the CLI
uses its own sign-in (``claude`` → ``/login``), so requests bill to the subscription's usage
limits. Content goes to Anthropic, so this is the "my own cloud account" option, not on-device.

Each request runs one isolated, tool-less ``claude -p`` process:

- ``--tools ""`` and ``--strict-mcp-config``: the model cannot run commands, read files or call MCP
  servers; it only writes text (or JSON for ``--json-schema``).
- ``--safe-mode``: the user's CLAUDE.md, hooks, plugins and custom agents are not loaded; sign-in
  still works. (``--bare`` is deliberately not used: it never reads the subscription login.)
- ``--no-session-persistence`` and an empty temporary working directory: nothing is saved and no
  project context is picked up.
- ``ANTHROPIC_API_KEY`` and other provider overrides are removed from the child environment, so
  the subscription login is what authenticates.

Supported: text messages, ``response_format`` json_schema / json_object, and streaming (as one
chunk). Tool calls and images are a capability mismatch and fail closed.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import tempfile
import time
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from llm_gateway.gateway.provider_types import ProviderFailure, ProviderResponse
from llm_gateway.gateway.schemas import FailureClass, ProviderRef, ProviderRejection

CLAUDE_CLI_PATH_ENV_VAR = 'OMI_CLAUDE_CLI_PATH'
CLAUDE_CLI_CONCURRENCY_ENV_VAR = 'OMI_CLAUDE_CLI_CONCURRENCY'
DEFAULT_CLAUDE_CLI_MODEL = 'sonnet'
DEFAULT_SYSTEM_PROMPT = 'You are a helpful assistant.'
JSON_OBJECT_INSTRUCTION = 'Reply with a single JSON object and nothing else.'

# Removed from the CLI's environment so the subscription login authenticates and no other
# provider or proxy is silently used.
_STRIPPED_CHILD_ENV = (
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_MODEL',
    'CLAUDE_CODE_USE_BEDROCK',
    'CLAUDE_CODE_USE_VERTEX',
    'CLAUDE_CODE_USE_FOUNDRY',
    'CLAUDE_CODE_SIMPLE',
)


@dataclass(frozen=True)
class CliInvocation:
    args: list[str]
    stdin: str
    system_prompt: str
    wants_structured: bool


@dataclass(frozen=True)
class CliResult:
    returncode: int
    stdout: bytes
    stderr: bytes


Runner = Callable[[CliInvocation, Mapping[str, str], str, float], Awaitable[CliResult]]


def _mismatch(rejection: ProviderRejection) -> ProviderFailure:
    return ProviderFailure(FailureClass.CAPABILITY_MISMATCH, provider_rejection=rejection)


def _text_of(content: Any) -> str:
    if content is None:
        return ''
    if isinstance(content, str):
        return content
    if isinstance(content, Sequence):
        parts: list[str] = []
        for part in content:
            if not isinstance(part, Mapping):
                continue
            kind = part.get('type')
            if kind == 'text':
                parts.append(str(part.get('text', '')))
            elif kind in {'image_url', 'input_image', 'image', 'input_audio', 'file'}:
                # The CLI's prompt input is text here; images would need stream-json input.
                raise _mismatch(ProviderRejection.INVALID_MESSAGES)
        return '\n'.join(parts)
    return str(content)


def build_invocation(request: Mapping[str, Any], *, binary: str, model: str) -> CliInvocation:
    """Translate an OpenAI chat-completions request into one ``claude -p`` call."""

    if request.get('tools') or request.get('functions'):
        raise _mismatch(ProviderRejection.INVALID_TOOLS)
    messages = request.get('messages')
    if not isinstance(messages, Sequence) or not messages:
        raise ProviderFailure(FailureClass.PROVIDER_INVALID_REQUEST, provider_rejection=ProviderRejection.INVALID_MESSAGES)

    system_parts: list[str] = []
    turns: list[tuple[str, str]] = []
    for message in messages:
        if not isinstance(message, Mapping):
            continue
        role = str(message.get('role', 'user'))
        text = _text_of(message.get('content'))
        if role in {'system', 'developer'}:
            if text:
                system_parts.append(text)
        else:
            turns.append(('Assistant' if role == 'assistant' else 'User', text))

    if len(turns) == 1 and turns[0][0] == 'User':
        prompt = turns[0][1]
    else:
        rendered = '\n\n'.join(f'{who}: {text}' for who, text in turns)
        prompt = f'Conversation so far:\n\n{rendered}\n\nWrite the assistant\'s next reply.'

    args = [
        binary,
        '-p',
        '--output-format',
        'json',
        '--model',
        model,
        '--tools',
        '',
        '--strict-mcp-config',
        '--safe-mode',
        '--no-session-persistence',
        '--disable-slash-commands',
    ]
    wants_structured = False
    response_format = request.get('response_format')
    if isinstance(response_format, Mapping):
        kind = response_format.get('type')
        if kind == 'json_schema':
            wrapper = response_format.get('json_schema')
            schema = wrapper.get('schema') if isinstance(wrapper, Mapping) else None
            if not isinstance(schema, Mapping):
                raise ProviderFailure(
                    FailureClass.PROVIDER_INVALID_REQUEST, provider_rejection=ProviderRejection.INVALID_RESPONSE_FORMAT
                )
            args += ['--json-schema', json.dumps(schema, separators=(',', ':'))]
            wants_structured = True
        elif kind == 'json_object':
            system_parts.append(JSON_OBJECT_INSTRUCTION)

    system_prompt = '\n\n'.join(system_parts) or DEFAULT_SYSTEM_PROMPT
    return CliInvocation(args=args, stdin=prompt, system_prompt=system_prompt, wants_structured=wants_structured)


def child_environment(parent: Mapping[str, str] | None = None) -> dict[str, str]:
    source = dict(os.environ if parent is None else parent)
    for key in _STRIPPED_CHILD_ENV:
        source.pop(key, None)
    return source


def _classify_error(payload: Mapping[str, Any]) -> ProviderFailure:
    status = payload.get('api_error_status')
    message = str(payload.get('result') or '').lower()
    if status == 429 or 'usage limit' in message or 'rate limit' in message:
        return ProviderFailure(FailureClass.PROVIDER_429_OMI_PAID, upstream_http_status=429)
    if status in {401, 403} or '/login' in message or 'not logged in' in message or 'api key' in message:
        return ProviderFailure(FailureClass.INVALID_CONFIG, upstream_http_status=status if isinstance(status, int) else None)
    if status == 404:
        return ProviderFailure(
            FailureClass.PROVIDER_INVALID_REQUEST,
            provider_rejection=ProviderRejection.MODEL_NOT_FOUND,
            upstream_http_status=404,
        )
    if status == 400:
        return ProviderFailure(
            FailureClass.PROVIDER_INVALID_REQUEST,
            provider_rejection=ProviderRejection.INVALID_REQUEST,
            upstream_http_status=400,
        )
    return ProviderFailure(
        FailureClass.PROVIDER_5XX_OMI_PAID, upstream_http_status=status if isinstance(status, int) else None
    )


def parse_result(stdout: bytes, *, invocation: CliInvocation, model: str) -> dict[str, Any]:
    """The CLI's ``--output-format json`` result as an OpenAI chat.completion body."""

    try:
        payload = json.loads(stdout.decode('utf-8', errors='replace').strip() or '{}')
    except ValueError as exc:
        raise ProviderFailure(FailureClass.PROVIDER_5XX_OMI_PAID) from exc
    if not isinstance(payload, Mapping) or payload.get('type') != 'result':
        raise ProviderFailure(FailureClass.PROVIDER_5XX_OMI_PAID)
    if payload.get('is_error') or payload.get('subtype') != 'success':
        raise _classify_error(payload)

    structured = payload.get('structured_output')
    if invocation.wants_structured and structured is not None:
        content = json.dumps(structured, ensure_ascii=False)
    else:
        content = str(payload.get('result') or '')

    usage = payload.get('usage') if isinstance(payload.get('usage'), Mapping) else {}
    prompt_tokens = sum(
        int(usage.get(key) or 0)
        for key in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')
    )
    completion_tokens = int(usage.get('output_tokens') or 0)
    served = next(iter(payload.get('modelUsage') or {}), model)
    return {
        'id': f'claude-cli-{payload.get("session_id") or uuid.uuid4()}',
        'object': 'chat.completion',
        'created': int(time.time()),
        'model': served,
        'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': content}, 'finish_reason': 'stop'}],
        'usage': {
            'prompt_tokens': prompt_tokens,
            'completion_tokens': completion_tokens,
            'total_tokens': prompt_tokens + completion_tokens,
        },
    }


async def _run_subprocess(invocation: CliInvocation, env: Mapping[str, str], cwd: str, timeout_s: float) -> CliResult:
    process = await asyncio.create_subprocess_exec(
        *invocation.args,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=cwd,
        env=dict(env),
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(invocation.stdin.encode('utf-8')), timeout_s)
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()
        raise
    return CliResult(returncode=process.returncode or 0, stdout=stdout, stderr=stderr)


class ClaudeCodeCLIProvider:
    """OpenAI chat-completions provider backed by ``claude -p`` and the user's subscription."""

    def __init__(
        self,
        *,
        binary: str | None = None,
        max_concurrency: int | None = None,
        runner: Runner | None = None,
        env: Mapping[str, str] | None = None,
    ) -> None:
        self._binary = binary or os.getenv(CLAUDE_CLI_PATH_ENV_VAR, '').strip() or shutil.which('claude') or 'claude'
        raw_concurrency = os.getenv(CLAUDE_CLI_CONCURRENCY_ENV_VAR, '').strip()
        self._concurrency = max(1, max_concurrency or (int(raw_concurrency) if raw_concurrency.isdigit() else 2))
        # Bounds simultaneous CLI processes. Semaphores bind to their event loop, so one per loop.
        self._semaphores: dict[int, asyncio.Semaphore] = {}
        self._runner: Runner = runner or _run_subprocess
        self._env = child_environment(env)

    async def create_chat_completion(
        self,
        request: Mapping[str, Any],
        *,
        provider_ref: ProviderRef,
        credentials: Any,
        timeout_ms: int,
    ) -> ProviderResponse:
        model = provider_ref.model or DEFAULT_CLAUDE_CLI_MODEL
        invocation = build_invocation(request, binary=self._binary, model=model)
        loop_id = id(asyncio.get_running_loop())
        semaphore = self._semaphores.setdefault(loop_id, asyncio.Semaphore(self._concurrency))
        async with semaphore:
            with tempfile.TemporaryDirectory(prefix='omi-claude-cli-') as workdir:
                prompt_file = os.path.join(workdir, 'system-prompt.txt')
                with open(prompt_file, 'w', encoding='utf-8') as handle:
                    handle.write(invocation.system_prompt)
                call = CliInvocation(
                    args=[*invocation.args, '--system-prompt-file', prompt_file],
                    stdin=invocation.stdin,
                    system_prompt=invocation.system_prompt,
                    wants_structured=invocation.wants_structured,
                )
                try:
                    result = await self._runner(call, self._env, workdir, timeout_ms / 1000.0)
                except asyncio.TimeoutError as exc:
                    raise ProviderFailure(FailureClass.TIMEOUT_BEFORE_OUTPUT) from exc
                except FileNotFoundError as exc:
                    # No `claude` on PATH: configuration, not an outage.
                    raise ProviderFailure(FailureClass.INVALID_CONFIG) from exc
        return ProviderResponse(response=parse_result(result.stdout, invocation=invocation, model=model))

    async def stream_chat_completion(
        self,
        request: Mapping[str, Any],
        *,
        provider_ref: ProviderRef,
        credentials: Any,
        timeout_ms: int,
    ) -> AsyncIterator[bytes]:
        response = await self.create_chat_completion(
            request, provider_ref=provider_ref, credentials=credentials, timeout_ms=timeout_ms
        )
        body = response.response
        choice = body['choices'][0]
        chunk = {
            'id': body['id'],
            'object': 'chat.completion.chunk',
            'created': body['created'],
            'model': body['model'],
            'choices': [
                {
                    'index': 0,
                    'delta': {'role': 'assistant', 'content': choice['message']['content']},
                    'finish_reason': 'stop',
                }
            ],
            'usage': body['usage'],
        }
        yield f'data: {json.dumps(chunk, separators=(",", ":"))}\n\n'.encode()
        yield b'data: [DONE]\n\n'
