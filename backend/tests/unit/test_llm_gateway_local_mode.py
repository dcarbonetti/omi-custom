"""Local-AI mode: every gateway lane is served by one OpenAI-compatible server on this machine."""

from __future__ import annotations

import json

import httpx
import pytest

from llm_gateway.gateway.auth import ServiceCaller
from llm_gateway.gateway.config_loader import ConfigValidationError, load_gateway_config
from llm_gateway.gateway.credentials import build_omi_managed_credential_context
from llm_gateway.gateway.executor import ProviderRegistry, execute_chat_completion
from llm_gateway.gateway.local_mode import (
    LOCAL_DISABLED_PROVIDER,
    LOCAL_PROVIDER,
    LocalModeConfigError,
    apply_local_llm_mode,
    local_llm_settings,
)
from llm_gateway.gateway.providers import OpenAICompatibleChatCompletionProvider
from llm_gateway.gateway.resolver import resolve_chat_completion_route
from llm_gateway.gateway.schemas import Surface

BASE_ENV = {
    'OMI_LOCAL_LLM_BASE_URL': 'http://127.0.0.1:11434/v1/',
    'OMI_LOCAL_LLM_MODEL': 'qwen3:8b',
}


def test_off_without_base_url():
    assert local_llm_settings({}) is None
    config = load_gateway_config(prod_mode=True)
    assert apply_local_llm_mode(config, None) is config


def test_settings_parse_and_defaults():
    settings = local_llm_settings({**BASE_ENV, 'OMI_LOCAL_EMBEDDING_MODEL': 'nomic-embed-text'})
    assert settings is not None
    assert settings.base_url == 'http://127.0.0.1:11434/v1'
    assert settings.model == 'qwen3:8b'
    assert settings.embedding_model == 'nomic-embed-text'
    assert settings.api_key == 'local'
    assert settings.timeout_ms == 300_000


@pytest.mark.parametrize(
    'env',
    [
        {'OMI_LOCAL_LLM_BASE_URL': 'http://127.0.0.1:11434/v1'},  # no model
        {**BASE_ENV, 'OMI_LOCAL_LLM_BASE_URL': 'https://api.openai.com/v1'},  # not loopback
        {**BASE_ENV, 'OMI_LOCAL_LLM_BASE_URL': 'ftp://127.0.0.1/v1'},
        {**BASE_ENV, 'OMI_LOCAL_LLM_TIMEOUT_MS': 'soon'},
    ],
)
def test_invalid_settings_fail_closed(env):
    with pytest.raises(LocalModeConfigError):
        local_llm_settings(env)
    assert issubclass(LocalModeConfigError, ConfigValidationError)


def test_remote_server_needs_explicit_opt_in():
    env = {**BASE_ENV, 'OMI_LOCAL_LLM_BASE_URL': 'http://192.168.1.20:11434/v1', 'OMI_LOCAL_LLM_ALLOW_REMOTE': 'true'}
    settings = local_llm_settings(env)
    assert settings is not None and settings.base_url.startswith('http://192.168.1.20')


def test_every_route_leaves_its_cloud_provider():
    settings = local_llm_settings(BASE_ENV)
    original = load_gateway_config(prod_mode=True)
    localized = apply_local_llm_mode(original, settings)

    assert localized.route_artifacts.keys() == original.route_artifacts.keys()
    for artifact_id, artifact in localized.route_artifacts.items():
        assert artifact.primary.provider in {LOCAL_PROVIDER, LOCAL_DISABLED_PROVIDER}, artifact_id
        assert artifact.fallbacks == [], artifact_id
        assert artifact.provider_options == {}, artifact_id
        assert artifact.timeouts.request_ms >= 300_000, artifact_id
        if original.route_artifacts[artifact_id].primary.provider == 'perplexity':
            # Web search is a search product: a local model would invent results.
            assert artifact.primary.provider == LOCAL_DISABLED_PROVIDER, artifact_id
        elif artifact.surface == Surface.OPENAI_CHAT_COMPLETIONS:
            assert artifact.primary == artifact.primary.model_copy(update={'provider': 'local', 'model': 'qwen3:8b'})
        else:
            # Anthropic Messages / SystemOne cannot be served locally, and embeddings need an
            # explicit local model: all fail closed.
            assert artifact.primary.provider == LOCAL_DISABLED_PROVIDER, artifact_id


def test_embeddings_use_local_embedding_model_when_set():
    settings = local_llm_settings({**BASE_ENV, 'OMI_LOCAL_EMBEDDING_MODEL': 'nomic-embed-text'})
    localized = apply_local_llm_mode(load_gateway_config(prod_mode=True), settings)
    embedding_routes = [a for a in localized.route_artifacts.values() if a.surface == Surface.OPENAI_EMBEDDINGS]
    assert embedding_routes
    for artifact in embedding_routes:
        assert artifact.primary.provider == LOCAL_PROVIDER
        assert artifact.primary.model == 'nomic-embed-text'


@pytest.mark.asyncio
async def test_chat_lane_dispatches_to_local_server_with_local_model():
    settings = local_llm_settings(BASE_ENV)
    assert settings is not None
    config = apply_local_llm_mode(load_gateway_config(prod_mode=True), settings)
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(
            200,
            json={
                'id': 'local-completion',
                'object': 'chat.completion',
                'model': 'qwen3:8b',
                'choices': [{'message': {'role': 'assistant', 'content': 'from ollama'}, 'finish_reason': 'stop'}],
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        registry = ProviderRegistry(
            {
                LOCAL_PROVIDER: OpenAICompatibleChatCompletionProvider(
                    base_url=settings.base_url, static_api_key=settings.api_key, http_client=client
                )
            }
        )
        resolved = resolve_chat_completion_route(
            config,
            {'model': 'omi:auto:chat-structured', 'messages': [{'role': 'user', 'content': 'synthetic'}]},
        )
        credentials = build_omi_managed_credential_context(ServiceCaller(name='backend'))
        result = await execute_chat_completion(resolved, credentials, registry)

    assert result.selected_provider == LOCAL_PROVIDER
    assert result.selected_model == 'qwen3:8b'
    assert result.response['choices'][0]['message']['content'] == 'from ollama'
    assert len(seen) == 1
    assert str(seen[0].url) == 'http://127.0.0.1:11434/v1/chat/completions'
    assert seen[0].headers['authorization'] == 'Bearer local'
    body = json.loads(seen[0].content)
    assert body['model'] == 'qwen3:8b'
    assert 'reasoning_effort' not in body


@pytest.mark.asyncio
async def test_unservable_lane_fails_closed_without_http():
    settings = local_llm_settings(BASE_ENV)
    config = apply_local_llm_mode(load_gateway_config(prod_mode=True), settings)
    anthropic_routes = [a for a in config.route_artifacts.values() if a.surface == Surface.ANTHROPIC_MESSAGES]
    for artifact in anthropic_routes:
        assert artifact.primary.provider == LOCAL_DISABLED_PROVIDER

    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover - must not run
        raise AssertionError(f'unexpected HTTP to {request.url}')

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        registry = ProviderRegistry(
            {
                LOCAL_PROVIDER: OpenAICompatibleChatCompletionProvider(
                    base_url=settings.base_url, static_api_key=settings.api_key, http_client=client
                )
            }
        )
        assert registry.provider_for(LOCAL_DISABLED_PROVIDER) is None
        assert registry.provider_for('openai') is None
        assert registry.provider_for('anthropic') is None


def test_web_search_lane_fails_closed():
    settings = local_llm_settings(BASE_ENV)
    config = apply_local_llm_mode(load_gateway_config(prod_mode=True), settings)
    lane = config.lanes['omi:auto:web-search']
    route = config.route_artifacts[lane.active_route]
    assert route.primary.provider == LOCAL_DISABLED_PROVIDER
