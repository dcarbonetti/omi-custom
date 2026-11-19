"""Self-hosted AI mode: serve every gateway lane from one model the stack's owner controls.

Two backends (``OMI_LOCAL_LLM_BACKEND``):

- ``openai`` (default): an OpenAI-compatible server on this machine, ``OMI_LOCAL_LLM_BASE_URL``
  (``http://127.0.0.1:11434/v1`` for Ollama, ``http://127.0.0.1:1234/v1`` for LM Studio) with
  ``OMI_LOCAL_LLM_MODEL``. Nothing leaves the machine.
- ``claude-cli``: the Claude Code CLI (``claude -p``) signed in to the owner's Claude
  subscription, ``OMI_LOCAL_LLM_MODEL`` a CLI model alias (default ``sonnet``). Content goes to
  Anthropic under the owner's account; see ``claude_cli_provider.py``.

Used by ``scripts/local-first/omi-local`` for a self-hosted desktop stack.

Coverage is the point. The rewrite happens after the whole config is loaded, so every route
artifact is covered: generated ``omi:auto:*`` lanes, explicit lanes, desktop Vertex lanes and
dream lanes. A lane the local server cannot serve (Anthropic Messages, OpenRouter SystemOne,
web search, or embeddings without ``OMI_LOCAL_EMBEDDING_MODEL``) is pointed at an unregistered provider and
fails closed with ``invalid_config``. It is never left on its cloud provider.

The base URL must be loopback unless ``OMI_LOCAL_LLM_ALLOW_REMOTE=true`` (a self-hosted box on
the user's own network).
"""

from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass
from urllib.parse import urlparse

from llm_gateway.gateway.config_loader import ConfigValidationError, GatewayConfig
from llm_gateway.gateway.schemas import ProviderRef, RouteArtifact, Surface

LOCAL_LLM_BASE_URL_ENV_VAR = 'OMI_LOCAL_LLM_BASE_URL'
LOCAL_LLM_MODEL_ENV_VAR = 'OMI_LOCAL_LLM_MODEL'
LOCAL_EMBEDDING_MODEL_ENV_VAR = 'OMI_LOCAL_EMBEDDING_MODEL'
LOCAL_LLM_API_KEY_ENV_VAR = 'OMI_LOCAL_LLM_API_KEY'
LOCAL_LLM_TIMEOUT_MS_ENV_VAR = 'OMI_LOCAL_LLM_TIMEOUT_MS'
LOCAL_LLM_ALLOW_REMOTE_ENV_VAR = 'OMI_LOCAL_LLM_ALLOW_REMOTE'
LOCAL_LLM_BACKEND_ENV_VAR = 'OMI_LOCAL_LLM_BACKEND'

BACKEND_OPENAI = 'openai'
BACKEND_CLAUDE_CLI = 'claude-cli'
BACKENDS = frozenset({BACKEND_OPENAI, BACKEND_CLAUDE_CLI})
CLAUDE_CLI_PROVIDER = 'claude-cli'
DEFAULT_CLAUDE_CLI_MODEL = 'sonnet'

LOCAL_PROVIDER = 'local'
# Never registered: a lane pointed here fails closed instead of reaching a cloud provider.
LOCAL_DISABLED_PROVIDER = 'local-disabled'
DEFAULT_LOCAL_LLM_TIMEOUT_MS = 300_000
# Ollama and LM Studio ignore the key, but the OpenAI wire requires the header.
DEFAULT_LOCAL_LLM_API_KEY = 'local'


class LocalModeConfigError(ConfigValidationError):
    pass


@dataclass(frozen=True)
class LocalLLMSettings:
    base_url: str
    model: str
    embedding_model: str | None
    api_key: str
    timeout_ms: int
    backend: str = BACKEND_OPENAI

    @property
    def provider_name(self) -> str:
        return CLAUDE_CLI_PROVIDER if self.backend == BACKEND_CLAUDE_CLI else LOCAL_PROVIDER


def _is_loopback(host: str) -> bool:
    if host in {'localhost'}:
        return True
    try:
        return ipaddress.ip_address(host.strip('[]')).is_loopback
    except ValueError:
        return False


def local_llm_settings(env: dict[str, str] | None = None) -> LocalLLMSettings | None:
    """The configured local server, or ``None`` when local-AI mode is off."""

    source = os.environ if env is None else env
    backend = source.get(LOCAL_LLM_BACKEND_ENV_VAR, '').strip().lower() or BACKEND_OPENAI
    if backend not in BACKENDS:
        raise LocalModeConfigError(f'{LOCAL_LLM_BACKEND_ENV_VAR} must be one of {sorted(BACKENDS)}, got {backend!r}')
    timeout_ms = _timeout_ms(source)
    if backend == BACKEND_CLAUDE_CLI:
        return LocalLLMSettings(
            base_url='',
            model=source.get(LOCAL_LLM_MODEL_ENV_VAR, '').strip() or DEFAULT_CLAUDE_CLI_MODEL,
            # The CLI has no embeddings endpoint: those lanes fail closed.
            embedding_model=None,
            api_key='',
            timeout_ms=timeout_ms,
            backend=BACKEND_CLAUDE_CLI,
        )
    base_url = source.get(LOCAL_LLM_BASE_URL_ENV_VAR, '').strip().rstrip('/')
    if not base_url:
        if source.get(LOCAL_LLM_BACKEND_ENV_VAR, '').strip():
            raise LocalModeConfigError(f'{LOCAL_LLM_BACKEND_ENV_VAR}=openai needs {LOCAL_LLM_BASE_URL_ENV_VAR}')
        return None
    model = source.get(LOCAL_LLM_MODEL_ENV_VAR, '').strip()
    if not model:
        raise LocalModeConfigError(f'{LOCAL_LLM_BASE_URL_ENV_VAR} is set but {LOCAL_LLM_MODEL_ENV_VAR} is empty')
    parsed = urlparse(base_url)
    if parsed.scheme not in {'http', 'https'} or not parsed.hostname:
        raise LocalModeConfigError(f'{LOCAL_LLM_BASE_URL_ENV_VAR} must be an http(s) URL, got {base_url!r}')
    allow_remote = source.get(LOCAL_LLM_ALLOW_REMOTE_ENV_VAR, '').strip().lower() in {'1', 'true', 'yes'}
    if not allow_remote and not _is_loopback(parsed.hostname):
        raise LocalModeConfigError(
            f'{LOCAL_LLM_BASE_URL_ENV_VAR} must point at this machine (loopback); '
            f'set {LOCAL_LLM_ALLOW_REMOTE_ENV_VAR}=true for a server on your own network'
        )
    return LocalLLMSettings(
        base_url=base_url,
        model=model,
        embedding_model=source.get(LOCAL_EMBEDDING_MODEL_ENV_VAR, '').strip() or None,
        api_key=source.get(LOCAL_LLM_API_KEY_ENV_VAR, '').strip() or DEFAULT_LOCAL_LLM_API_KEY,
        timeout_ms=timeout_ms,
    )


def _timeout_ms(source) -> int:
    raw_timeout = source.get(LOCAL_LLM_TIMEOUT_MS_ENV_VAR, '').strip()
    try:
        timeout_ms = int(raw_timeout) if raw_timeout else DEFAULT_LOCAL_LLM_TIMEOUT_MS
    except ValueError as exc:
        raise LocalModeConfigError(f'{LOCAL_LLM_TIMEOUT_MS_ENV_VAR} must be an integer') from exc
    if timeout_ms <= 0:
        raise LocalModeConfigError(f'{LOCAL_LLM_TIMEOUT_MS_ENV_VAR} must be positive')
    return timeout_ms


# Providers that are search products, not language models. A local chat model asked to stand in
# for one invents "search results" with fake sources, so these lanes fail closed instead and
# their callers report web search as unavailable.
SEARCH_PRODUCT_PROVIDERS = frozenset({'perplexity'})


def _local_primary(artifact: RouteArtifact, settings: LocalLLMSettings) -> ProviderRef:
    if artifact.primary.provider in SEARCH_PRODUCT_PROVIDERS:
        return ProviderRef(provider=LOCAL_DISABLED_PROVIDER, model=artifact.primary.model)
    if artifact.surface == Surface.OPENAI_CHAT_COMPLETIONS:
        return ProviderRef(provider=settings.provider_name, model=settings.model)
    if artifact.surface == Surface.OPENAI_EMBEDDINGS and settings.embedding_model:
        return ProviderRef(provider=settings.provider_name, model=settings.embedding_model)
    return ProviderRef(provider=LOCAL_DISABLED_PROVIDER, model=artifact.primary.model)


def localize_route_artifact(artifact: RouteArtifact, settings: LocalLLMSettings) -> RouteArtifact:
    # Credential policy is left as-is: the local provider uses its own static key and never
    # reads a forwarded BYOK key, so a user's cloud keys never reach the local server.
    return artifact.model_copy(
        update={
            'primary': _local_primary(artifact, settings),
            'fallbacks': [],
            # Provider options are cloud-model specific (reasoning_effort, Anthropic effort).
            'provider_options': {},
            'timeouts': artifact.timeouts.model_copy(
                update={'request_ms': max(artifact.timeouts.request_ms, settings.timeout_ms)}
            ),
            # The digest pinned the cloud route; this artifact is a local projection of it.
            'artifact_digest': None,
        }
    )


def apply_local_llm_mode(config: GatewayConfig, settings: LocalLLMSettings | None) -> GatewayConfig:
    if settings is None:
        return config
    route_artifacts = {
        artifact_id: localize_route_artifact(artifact, settings)
        for artifact_id, artifact in config.route_artifacts.items()
    }
    return config.model_copy(update={'route_artifacts': route_artifacts})
