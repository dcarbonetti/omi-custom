"""Helpers for the local-first Omi stack (see scripts/local-first/README.md).

Run through ``scripts/local-first/omi-local``; it sets PYTHONPATH so ``dev_harness`` imports.

Commands:
  check-llm     verify the local OpenAI-compatible server answers and serves the model
  ensure-user   create the personal account in the local Firebase Auth emulator (idempotent)
  app           build and launch the omi-local desktop bundle against the local stack
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

from dev_harness import config, desktop_profile, safety

REPO = Path(__file__).resolve().parents[2]
APP_NAME = os.environ.get("OMI_LOCAL_APP_NAME", "omi-local")
USER = os.environ.get("OMI_LOCAL_USER", "me")
DISPLAY_NAME = os.environ.get("OMI_LOCAL_DISPLAY_NAME", "Me")


def _cfg() -> config.HarnessConfig:
    return config.load_config(REPO, create_layout=False)


def _http_json(url: str, payload: dict | None = None, timeout: float = 10.0) -> tuple[int, dict]:
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    request.add_header("Content-Type", "application/json")
    # Loopback only: never route through a proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=timeout) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        body = exc.read()
        try:
            return exc.code, json.loads(body or b"{}")
        except json.JSONDecodeError:
            return exc.code, {"raw": body.decode(errors="replace")}


def _uses_claude_cli() -> bool:
    return os.environ.get("OMI_LOCAL_LLM_BACKEND", "").strip().lower() == "claude-cli"


def check_claude_cli() -> int:
    """One tiny `claude -p` call, run exactly the way the gateway runs it."""

    binary = os.environ.get("OMI_CLAUDE_CLI_PATH") or shutil.which("claude")
    if not binary:
        print("`claude` is not on PATH. Install Claude Code (https://claude.com/claude-code), then run `claude` once")
        print("and sign in with your Claude subscription (/login).")
        return 1
    model = os.environ.get("OMI_LOCAL_LLM_MODEL") or "sonnet"
    env = {k: v for k, v in os.environ.items() if k not in {"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"}}
    args = [binary, "-p", "--output-format", "json", "--model", model, "--tools", "", "--strict-mcp-config",
            "--safe-mode", "--no-session-persistence", "--disable-slash-commands"]
    with tempfile.TemporaryDirectory(prefix="omi-claude-check-") as workdir:
        try:
            done = subprocess.run(args, input="Reply with the single word OK.", capture_output=True, text=True,
                                  cwd=workdir, env=env, timeout=120)
        except subprocess.TimeoutExpired:
            print("`claude -p` did not answer within 2 minutes.")
            return 1
    try:
        payload = json.loads(done.stdout or "{}")
    except json.JSONDecodeError:
        payload = {}
    if payload.get("type") == "result" and not payload.get("is_error"):
        served = ", ".join(payload.get("modelUsage", {})) or model
        print(f"Claude Code CLI OK ({binary}, model {served}). AI lanes will use your Claude subscription.")
        return 0
    print("`claude -p` failed: " + str(payload.get("result") or done.stderr.strip() or "no output"))
    print("Run `claude` in a terminal and sign in with /login (choose your Claude subscription, not an API key).")
    return 1


def check_llm() -> int:
    if _uses_claude_cli():
        return check_claude_cli()
    base = os.environ.get("OMI_LOCAL_LLM_BASE_URL", "").rstrip("/")
    model = os.environ.get("OMI_LOCAL_LLM_MODEL", "")
    if not base or not model:
        print("OMI_LOCAL_LLM_BASE_URL and OMI_LOCAL_LLM_MODEL must be set (see scripts/local-first/omi-local.env)")
        return 2
    try:
        status, body = _http_json(f"{base}/models")
    except (urllib.error.URLError, OSError) as exc:
        print(f"Local LLM server is not reachable at {base}: {exc}")
        print("Start Ollama (`ollama serve`) or LM Studio's server, then try again.")
        return 1
    if status != 200:
        print(f"{base}/models answered HTTP {status}")
        return 1
    ids = sorted(str(item.get("id")) for item in body.get("data", []) if isinstance(item, dict))
    wanted = [model] + [m for m in [os.environ.get("OMI_LOCAL_EMBEDDING_MODEL", "")] if m]
    missing = [m for m in wanted if m not in ids]
    print(f"Local LLM server: {base} ({len(ids)} models)")
    if missing:
        print(f"Missing model(s): {', '.join(missing)}. Available: {', '.join(ids) or 'none'}")
        print("For Ollama: ollama pull " + " && ollama pull ".join(missing))
        return 1
    print(f"Chat model OK: {model}")
    return 0


def _credentials() -> tuple[str, str]:
    email = os.environ.get("OMI_LOCAL_EMAIL") or f"{USER}@local.omi.invalid"
    # Only ever used against the loopback Auth emulator.
    password = os.environ.get("OMI_LOCAL_PASSWORD") or f"{USER}-local-password-030"
    return email, password


def ensure_user() -> int:
    cfg = _cfg()
    email, password = _credentials()
    base = f"http://{cfg.auth_host}/identitytoolkit.googleapis.com/v1"
    key = config.LOCAL_FIREBASE_API_KEY
    status, body = _http_json(
        f"{base}/accounts:signUp?key={key}",
        {"email": email, "password": password, "displayName": DISPLAY_NAME, "returnSecureToken": True},
    )
    if status == 200:
        print(f"Created local account {email} (uid {body.get('localId')})")
        return 0
    message = str(body.get("error", {}).get("message", body))
    if "EMAIL_EXISTS" in message:
        print(f"Local account {email} already exists")
        return 0
    print(f"Could not create local account {email}: HTTP {status} {message}")
    return 1


def _seed_defaults(bundle_id: str) -> None:
    """First-run defaults for the bundle; never overwrites a value the user already set."""

    base = os.environ.get("OMI_LOCAL_LLM_BASE_URL", "")
    model = os.environ.get("OMI_LOCAL_LLM_MODEL", "")
    seeds = {
        # AI Provider → Local (your model), or Claude (your subscription) with the claude-cli backend.
        "chatBridgeMode": "claudeCode" if _uses_claude_cli() else "local",
        "localLLMBaseURL": "" if _uses_claude_cli() else base,
        "localLLMModelID": "" if _uses_claude_cli() else model,
        "localFirst_transcriptionRoute": "local",
        "localFirst_processingRoute": "local",
    }
    for key, value in seeds.items():
        if not value:
            continue
        exists = subprocess.run(["defaults", "read", bundle_id, key], capture_output=True).returncode == 0
        if not exists:
            subprocess.run(["defaults", "write", bundle_id, key, "-string", value], check=True)
            print(f"  seeded {key}={value}")


def app() -> int:
    cfg = _cfg()
    safety.read_and_validate_sentinel(cfg.layout.state_root, repo_root=cfg.repo_root, instance=cfg.instance)
    env = dict(os.environ)
    env["OMI_APP_NAME"] = APP_NAME
    profile = desktop_profile.resolve_profile(cfg, user=USER, seeded_users=[USER], env=env)
    errors = desktop_profile.validate_profile(profile)
    if errors:
        print("Local desktop profile failed its safety scan:")
        for error in errors:
            print(f"  - {error}")
        return 2
    email, password = _credentials()
    launch_env = {
        **profile.env,
        "OMI_LOCAL_AUTH_EMAIL": email,
        "OMI_LOCAL_AUTH_PASSWORD": password,
        "OMI_LOCAL_AUTH_DISPLAY_NAME": DISPLAY_NAME,
        # Never clone a cloud Omi session or settings into this bundle.
        "OMI_SKIP_AUTH_SEED": "1",
        "OMI_SKIP_SETTINGS_SEED": "1",
    }
    print(f"App: {profile.app_name}.app ({profile.bundle_id})")
    print(f"Backend: {profile.python_api_url}  Desktop backend: {profile.desktop_api_url}")
    print(f"Account: {email} (local Auth emulator {profile.firebase_auth_emulator_host})")
    if platform.system() != "Darwin":
        print("Not macOS: the desktop app can only be built and launched on a Mac.")
        return 0
    _seed_defaults(profile.bundle_id)
    subprocess.run(["./run.sh"], cwd=REPO / "desktop" / "macos", env={**env, **launch_env}, check=True)
    return 0


def main(argv: list[str]) -> int:
    commands = {"check-llm": check_llm, "ensure-user": ensure_user, "app": app}
    if len(argv) != 1 or argv[0] not in commands:
        print(__doc__)
        return 2
    return commands[argv[0]]()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
