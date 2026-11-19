from __future__ import annotations

from functools import lru_cache

from llm_gateway.gateway.config_loader import GatewayConfig, load_gateway_config
from llm_gateway.gateway.executor import ProviderRegistry
from llm_gateway.gateway.claude_cli_provider import ClaudeCodeCLIProvider
from llm_gateway.gateway.local_mode import (
    BACKEND_CLAUDE_CLI,
    CLAUDE_CLI_PROVIDER,
    LOCAL_PROVIDER,
    apply_local_llm_mode,
    local_llm_settings,
)
from llm_gateway.gateway.providers import (
    AnthropicMessagesProvider,
    OpenAICompatibleChatCompletionProvider,
    VertexGeminiProvider,
)


@lru_cache(maxsize=1)
def get_gateway_config() -> GatewayConfig:
    # Local-AI mode (OMI_LOCAL_LLM_BASE_URL) re-points every lane at the local server.
    return apply_local_llm_mode(load_gateway_config(prod_mode=True), local_llm_settings())


@lru_cache(maxsize=1)
def get_provider_registry() -> ProviderRegistry:
    local = local_llm_settings()
    if local is not None and local.backend == BACKEND_CLAUDE_CLI:
        # Only the Claude Code CLI (the owner's subscription) is registered.
        return ProviderRegistry({CLAUDE_CLI_PROVIDER: ClaudeCodeCLIProvider()})
    if local is not None:
        # Only the local server is registered: a lane that still names a cloud provider has
        # nothing to dispatch to and fails closed.
        return ProviderRegistry(
            {
                LOCAL_PROVIDER: OpenAICompatibleChatCompletionProvider(
                    base_url=local.base_url,
                    static_api_key=local.api_key,
                ),
            }
        )
    return ProviderRegistry(
        {
            'openai': OpenAICompatibleChatCompletionProvider(),
            'openrouter': OpenAICompatibleChatCompletionProvider(
                api_key_env='OPENROUTER_API_KEY',
                base_url='https://openrouter.ai/api/v1',
                default_headers={'X-Title': 'Omi Chat'},
            ),
            'perplexity': OpenAICompatibleChatCompletionProvider(
                api_key_env='PERPLEXITY_API_KEY',
                base_url='https://api.perplexity.ai',
            ),
            'gemini': VertexGeminiProvider(),
            'anthropic': AnthropicMessagesProvider(),
        }
    )


async def close_provider_registry() -> None:
    await get_provider_registry().aclose()
    get_provider_registry.cache_clear()
