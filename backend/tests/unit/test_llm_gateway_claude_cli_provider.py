"""Claude Code CLI provider: gateway chat lanes served by `claude -p` and the owner's subscription."""

from __future__ import annotations

import json

import pytest

from llm_gateway.gateway.claude_cli_provider import (
    JSON_OBJECT_INSTRUCTION,
    ClaudeCodeCLIProvider,
    CliResult,
    build_invocation,
    child_environment,
)
from llm_gateway.gateway.config_loader import load_gateway_config
from llm_gateway.gateway.local_mode import (
    CLAUDE_CLI_PROVIDER,
    LOCAL_DISABLED_PROVIDER,
    LocalModeConfigError,
    apply_local_llm_mode,
    local_llm_settings,
)
from llm_gateway.gateway.provider_types import ProviderFailure
from llm_gateway.gateway.schemas import FailureClass, ProviderRef, ProviderRejection, Surface

REF = ProviderRef(provider='claude-cli', model='sonnet')
SCHEMA = {'type': 'object', 'properties': {'title': {'type': 'string'}}, 'required': ['title']}


def _success(result: str = 'hello', structured=None) -> bytes:
    payload = {
        'type': 'result',
        'subtype': 'success',
        'is_error': False,
        'result': result,
        'session_id': 'sess-1',
        'usage': {'input_tokens': 3, 'cache_creation_input_tokens': 10, 'cache_read_input_tokens': 0, 'output_tokens': 4},
        'modelUsage': {'claude-sonnet-5-5': {}},
    }
    if structured is not None:
        payload['structured_output'] = structured
    return json.dumps(payload).encode()


class FakeRunner:
    def __init__(self, stdout: bytes, returncode: int = 0):
        self.stdout = stdout
        self.returncode = returncode
        self.calls = []

    async def __call__(self, invocation, env, cwd, timeout_s):
        with open(invocation.args[invocation.args.index('--system-prompt-file') + 1], encoding='utf-8') as handle:
            system_prompt = handle.read()
        self.calls.append({'invocation': invocation, 'env': dict(env), 'cwd': cwd, 'system': system_prompt})
        return CliResult(returncode=self.returncode, stdout=self.stdout, stderr=b'')


def _provider(runner, env=None):
    return ClaudeCodeCLIProvider(binary='/usr/local/bin/claude', runner=runner, env=env or {'HOME': '/Users/me'})


def test_invocation_is_isolated_and_toolless():
    invocation = build_invocation(
        {'messages': [{'role': 'system', 'content': 'Be brief.'}, {'role': 'user', 'content': 'Hi'}]},
        binary='claude',
        model='haiku',
    )
    args = invocation.args
    assert args[:2] == ['claude', '-p']
    assert args[args.index('--tools') + 1] == ''
    assert args[args.index('--model') + 1] == 'haiku'
    for flag in ('--strict-mcp-config', '--safe-mode', '--no-session-persistence', '--disable-slash-commands'):
        assert flag in args
    # Never --bare: it refuses subscription (OAuth) sign-in.
    assert '--bare' not in args
    assert invocation.stdin == 'Hi'
    assert invocation.system_prompt == 'Be brief.'


def test_multi_turn_is_rendered_as_a_transcript():
    invocation = build_invocation(
        {
            'messages': [
                {'role': 'user', 'content': 'What is 2+2?'},
                {'role': 'assistant', 'content': '4'},
                {'role': 'user', 'content': [{'type': 'text', 'text': 'And doubled?'}]},
            ]
        },
        binary='claude',
        model='sonnet',
    )
    assert 'User: What is 2+2?' in invocation.stdin
    assert 'Assistant: 4' in invocation.stdin
    assert invocation.stdin.endswith("User: And doubled?\n\nWrite the assistant's next reply.")


def test_json_schema_and_json_object_modes():
    structured = build_invocation(
        {
            'messages': [{'role': 'user', 'content': 'x'}],
            'response_format': {'type': 'json_schema', 'json_schema': {'name': 'n', 'schema': SCHEMA}},
        },
        binary='claude',
        model='sonnet',
    )
    assert json.loads(structured.args[structured.args.index('--json-schema') + 1]) == SCHEMA
    assert structured.wants_structured

    loose = build_invocation(
        {'messages': [{'role': 'user', 'content': 'x'}], 'response_format': {'type': 'json_object'}},
        binary='claude',
        model='sonnet',
    )
    assert JSON_OBJECT_INSTRUCTION in loose.system_prompt
    assert '--json-schema' not in loose.args


@pytest.mark.parametrize(
    'request_body,rejection',
    [
        ({'messages': [{'role': 'user', 'content': 'x'}], 'tools': [{'type': 'function'}]}, ProviderRejection.INVALID_TOOLS),
        (
            {'messages': [{'role': 'user', 'content': [{'type': 'image_url', 'image_url': {'url': 'data:,'}}]}]},
            ProviderRejection.INVALID_MESSAGES,
        ),
    ],
)
def test_tools_and_images_fail_closed(request_body, rejection):
    with pytest.raises(ProviderFailure) as raised:
        build_invocation(request_body, binary='claude', model='sonnet')
    assert raised.value.failure_class == FailureClass.CAPABILITY_MISMATCH
    assert raised.value.provider_rejection == rejection


def test_child_environment_drops_api_keys_so_the_subscription_authenticates():
    env = child_environment(
        {'HOME': '/Users/me', 'PATH': '/usr/bin', 'ANTHROPIC_API_KEY': 'placeholder', 'CLAUDE_CODE_USE_BEDROCK': '1'}
    )
    assert env == {'HOME': '/Users/me', 'PATH': '/usr/bin'}


@pytest.mark.asyncio
async def test_completion_returns_openai_shape_and_structured_output():
    runner = FakeRunner(_success(result='{"title":"x"}', structured={'title': 'Ship Friday'}))
    response = await _provider(runner, env={'HOME': '/Users/me', 'ANTHROPIC_API_KEY': 'nope'}).create_chat_completion(
        {
            'messages': [{'role': 'system', 'content': 'Extract.'}, {'role': 'user', 'content': 'Transcript...'}],
            'response_format': {'type': 'json_schema', 'json_schema': {'name': 'n', 'schema': SCHEMA}},
        },
        provider_ref=REF,
        credentials=None,
        timeout_ms=60_000,
    )
    body = response.response
    assert body['object'] == 'chat.completion'
    assert body['model'] == 'claude-sonnet-5-5'
    assert json.loads(body['choices'][0]['message']['content']) == {'title': 'Ship Friday'}
    assert body['usage'] == {'prompt_tokens': 13, 'completion_tokens': 4, 'total_tokens': 17}
    call = runner.calls[0]
    assert call['system'] == 'Extract.'
    assert call['invocation'].stdin == 'Transcript...'
    assert 'ANTHROPIC_API_KEY' not in call['env']


@pytest.mark.asyncio
@pytest.mark.parametrize(
    'payload,failure_class',
    [
        ({'api_error_status': 429, 'result': 'Rate limited'}, FailureClass.PROVIDER_429_OMI_PAID),
        ({'result': 'Claude AI usage limit reached|1763600000'}, FailureClass.PROVIDER_429_OMI_PAID),
        ({'result': 'Not logged in · Please run /login'}, FailureClass.INVALID_CONFIG),
        ({'api_error_status': 404, 'result': 'model not found'}, FailureClass.PROVIDER_INVALID_REQUEST),
        ({'api_error_status': 529, 'result': 'Overloaded'}, FailureClass.PROVIDER_5XX_OMI_PAID),
    ],
)
async def test_errors_map_to_gateway_failure_classes(payload, failure_class):
    stdout = json.dumps({'type': 'result', 'subtype': 'success', 'is_error': True, **payload}).encode()
    with pytest.raises(ProviderFailure) as raised:
        await _provider(FakeRunner(stdout, returncode=1)).create_chat_completion(
            {'messages': [{'role': 'user', 'content': 'x'}]}, provider_ref=REF, credentials=None, timeout_ms=1000
        )
    assert raised.value.failure_class == failure_class


@pytest.mark.asyncio
async def test_missing_cli_and_timeout():
    async def missing(*_args):
        raise FileNotFoundError('claude')

    async def slow(*_args):
        import asyncio

        raise asyncio.TimeoutError()

    for runner, failure_class in ((missing, FailureClass.INVALID_CONFIG), (slow, FailureClass.TIMEOUT_BEFORE_OUTPUT)):
        with pytest.raises(ProviderFailure) as raised:
            await _provider(runner).create_chat_completion(
                {'messages': [{'role': 'user', 'content': 'x'}]}, provider_ref=REF, credentials=None, timeout_ms=1000
            )
        assert raised.value.failure_class == failure_class


@pytest.mark.asyncio
async def test_streaming_emits_one_chunk_and_done_marker():
    chunks = [
        chunk
        async for chunk in _provider(FakeRunner(_success('streamed'))).stream_chat_completion(
            {'messages': [{'role': 'user', 'content': 'x'}], 'stream': True},
            provider_ref=REF,
            credentials=None,
            timeout_ms=1000,
        )
    ]
    assert chunks[-1] == b'data: [DONE]\n\n'
    first = json.loads(chunks[0].decode().removeprefix('data: ').strip())
    assert first['choices'][0]['delta']['content'] == 'streamed'


def test_local_mode_claude_cli_backend_routes_chat_lanes_and_disables_the_rest():
    settings = local_llm_settings({'OMI_LOCAL_LLM_BACKEND': 'claude-cli'})
    assert settings is not None and settings.model == 'sonnet' and settings.provider_name == CLAUDE_CLI_PROVIDER
    config = apply_local_llm_mode(load_gateway_config(prod_mode=True), settings)
    original = load_gateway_config(prod_mode=True)
    for artifact_id, artifact in config.route_artifacts.items():
        if artifact.surface == Surface.OPENAI_CHAT_COMPLETIONS and original.route_artifacts[artifact_id].primary.provider != 'perplexity':
            assert artifact.primary.provider == CLAUDE_CLI_PROVIDER
            assert artifact.primary.model == 'sonnet'
        else:
            assert artifact.primary.provider == LOCAL_DISABLED_PROVIDER


def test_local_mode_backend_validation():
    with pytest.raises(LocalModeConfigError):
        local_llm_settings({'OMI_LOCAL_LLM_BACKEND': 'bogus'})
    with pytest.raises(LocalModeConfigError):
        local_llm_settings({'OMI_LOCAL_LLM_BACKEND': 'openai'})
    assert local_llm_settings({'OMI_LOCAL_LLM_BACKEND': 'claude-cli', 'OMI_LOCAL_LLM_MODEL': 'haiku'}).model == 'haiku'
