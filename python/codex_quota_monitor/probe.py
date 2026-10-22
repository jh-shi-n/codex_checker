"""목적: 사용자 버튼으로 실행하는 격리된 최소 Ping 요청.

이용처: 계정 상세의 초기화 갱신
사용방법: run_probe(home) 호출, 실제 토큰 사용 발생 가능
"""

import json
import os
import selectors
import subprocess
import tempfile
import time
from pathlib import Path

from .models import finite_number
from .protocol import ServiceError, LineDecoder, check_home, child_environment, locate_codex, terminate

MODEL = "gpt-5.6-luna"
DISABLED_FEATURES = ("apps", "plugins", "multi_agent", "skill_search", "shell_tool", "unified_exec",
                     "sleep_tool", "browser_use", "browser_use_external", "browser_use_full_cdp_access",
                     "computer_use", "image_generation", "view_image", "goals", "workspace_dependencies",
                     "default_mode_request_user_input", "tool_suggest")


def probe_arguments(instructions, catalog=None):
    """원본 Swift와 동일한 최소 모델·도구 차단 인수 생성."""
    arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-rules",
                 "--ignore-user-config", "--enable", "skip_host_skill_discovery"]
    for feature in DISABLED_FEATURES:
        arguments += ["--disable", feature]
    configs = ["project_doc_max_bytes=0", "suppress_unstable_features_warning=true",
               "features.code_mode.enabled=false", "include_permissions_instructions=false",
               "include_apps_instructions=false", "include_collaboration_mode_instructions=false",
               "include_environment_context=false", 'web_search="disabled"',
               'model_reasoning_effort="none"', "model_instructions_file=" + json.dumps(str(instructions))]
    configs += ["skills.include_instructions=false", "skills.bundled.enabled=false",
                "tools.update_plan.enabled=false", "tools.experimental_request_user_input.enabled=false"]
    if catalog is not None:
        configs.append("model_catalog_json=" + json.dumps(str(catalog)))
    for config in configs:
        arguments += ["-c", config]
    return arguments + ["--sandbox", "read-only", "--model", MODEL, "--json", "."]


def parse_probe(messages, exit_code):
    """완료 이벤트·기대 출력·오류의 교차 검증과 토큰 수만 추출."""
    complete = expected = failed = False
    usage = {"input_tokens": None, "output_tokens": None}
    for event in messages:
        kind = event.get("type", "")
        complete |= kind == "turn.completed"
        item = event.get("item") or {}
        expected |= (kind == "item.completed" and isinstance(item, dict)
                     and item.get("type") == "agent_message" and str(item.get("text", "")).strip() == "1")
        failed |= bool(event.get("error")) or any(word in str(kind).lower() for word in ("error", "failed", "failure"))
        if kind == "turn.completed" and isinstance(event.get("usage"), dict):
            for key in usage:
                value = finite_number(event["usage"].get(key))
                if value is not None and value >= 0 and int(value) == value:
                    usage[key] = int(value)
    success = exit_code == 0 and complete and not failed
    return {"status": "success" if success else "error", **usage,
            "message": "Ping 완료" if success else "Ping 실패: CLI·모델 지원·로그인·한도를 확인해 주세요.",
            "updated_at": time.time()}


def prepare_catalog(executable, home, cwd, destination, timeout, registry=None):
    """번들 모델 카탈로그의 기한·출력 상한·취소 보장 및 최소 구성 생성."""
    process = None
    try:
        process = subprocess.Popen([executable, "debug", "models", "--bundled"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=cwd, env=child_environment(home, executable, cwd), start_new_session=True)
        if registry:
            registry.add(process)
        output = bytearray()
        consumed = 0
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            for stream in (process.stdout, process.stderr):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ServiceError("timeout", "모델 카탈로그 조회 시간 초과")
                for key, _ in selector.select(min(remaining, 0.1)):
                    data = os.read(key.fd, 65536)
                    consumed += len(data)
                    if consumed > 4 * 1024 * 1024:
                        raise ServiceError("configuration", "모델 카탈로그 크기 제한 초과")
                    if key.fileobj is process.stdout:
                        output.extend(data)
                    if not data:
                        selector.unregister(key.fileobj)
        process.wait(timeout=max(0.001, deadline - time.monotonic()))
        if process.returncode != 0:
            raise ValueError("unsupported CLI")
        catalog = json.loads(output)
        model = next(item.copy() for item in catalog["models"] if item.get("slug") == MODEL)
        if not all(key in model for key in ("tool_mode", "apply_patch_tool_type", "use_responses_lite")):
            raise ValueError("unsupported catalog")
        model.update(tool_mode="direct", apply_patch_tool_type=None, use_responses_lite=False)
        catalog["models"] = [model]
        destination.write_text(json.dumps(catalog))
        destination.chmod(0o600)
    except subprocess.TimeoutExpired:
        raise ServiceError("timeout", "모델 카탈로그 조회 시간 초과") from None
    except (OSError, ValueError, KeyError, TypeError, StopIteration):
        raise ServiceError("configuration", "CLI·모델 카탈로그 최소 Ping 구성 실패") from None
    finally:
        if process:
            terminate(process)
            if registry:
                registry.discard(process)


def run_probe(home, executable=None, timeout=60, registry=None):
    """인증 링크만 공유하는 임시 CODEX_HOME에서 기한 제한 요청."""
    check_home(home)
    executable = executable or locate_codex()
    with tempfile.TemporaryDirectory(prefix="codex-quota-ping-") as root:
        root = Path(root)
        isolated, cwd = root / "home", root / "work"
        isolated.mkdir(mode=0o700)
        cwd.mkdir(mode=0o700)
        (isolated / "auth.json").symlink_to(Path(home).absolute() / "auth.json")
        instructions = root / "ping-instructions"
        instructions.write_text("Silence")
        instructions.chmod(0o600)
        process = None
        deadline = time.monotonic() + timeout
        catalog = root / "catalog.json"
        prepare_catalog(executable, isolated, cwd, catalog, min(10, timeout), registry)
        try:
            process = subprocess.Popen([executable, *probe_arguments(instructions, catalog)], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd,
                env=child_environment(isolated, executable, cwd), start_new_session=True)
            if registry:
                registry.add(process)
            decoder, messages, consumed = LineDecoder(65536, 262144), [], 0
            with selectors.DefaultSelector() as selector:
                for stream in (process.stdout, process.stderr):
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ)
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise ServiceError("timeout", "Ping 실행 시간 초과")
                    for key, _ in selector.select(min(remaining, 0.25)):
                        data = os.read(key.fd, 65536)
                        if key.fileobj is process.stdout:
                            consumed += len(data)
                            if consumed > 262144:
                                raise ServiceError("error", "Ping 응답 크기 제한 초과")
                            messages.extend(decoder.feed(data, final=not data))
                        if not data:
                            selector.unregister(key.fileobj)
            try:
                process.wait(timeout=max(0.001, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                raise ServiceError("timeout", "Ping 실행 시간 초과") from None
            return parse_probe(messages, process.returncode)
        except OSError:
            raise ServiceError("error", "Ping 프로세스 실행 실패") from None
        finally:
            if process:
                terminate(process)
                if registry:
                    registry.discard(process)
