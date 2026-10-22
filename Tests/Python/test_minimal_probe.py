"""목적: 실제 모델 호출 없이 Python 최소 Ping 계약 검증."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from codex_quota_monitor.probe import MODEL, parse_probe, probe_arguments, run_probe
from codex_quota_monitor.protocol import ServiceError


class MinimalProbeTests(unittest.TestCase):
    """빈 응답·격리·카탈로그 생성과 실패 판정 검증."""

    def test_empty_completion_and_failures(self):
        """응답 문구 독립 성공 및 오류·미완료·비정상 종료 검증."""
        complete = {"type": "turn.completed", "usage": {"input_tokens": 170, "output_tokens": 4}}
        self.assertEqual(parse_probe([complete], 0)["status"], "success")
        for events, status in [([], 0), ([complete], 1), ([complete, {"type": "turn.failed"}], 0)]:
            self.assertEqual(parse_probe(events, status)["status"], "error")

    def test_catalog_isolation_and_empty_reply(self):
        """임시 카탈로그 수정·전달·삭제와 인증 링크 유지 검증."""
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            home = root / "account"
            home.mkdir()
            (home / "auth.json").write_text("synthetic fixture")
            capture = root / "capture.json"
            executable = root / "codex"
            executable.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1] == "debug":
    print(json.dumps({"models": [{"slug": "gpt-5.6-luna", "tool_mode": "code_mode_only", "apply_patch_tool_type": "freeform", "use_responses_lite": True}]}))
    sys.exit(0)
arguments = sys.argv[1:]
instruction = pathlib.Path(json.loads(next(x.split("=", 1)[1] for x in arguments if x.startswith("model_instructions_file="))))
catalog = pathlib.Path(json.loads(next(x.split("=", 1)[1] for x in arguments if x.startswith("model_catalog_json="))))
pathlib.Path(os.environ["CAPTURE"]).write_text(json.dumps({"args": arguments, "instruction": instruction.read_text(), "catalog": json.loads(catalog.read_text()), "root": str(catalog.parent), "auth_link": (pathlib.Path(os.environ["CODEX_HOME"]) / "auth.json").is_symlink(), "cwd_empty": not list(pathlib.Path.cwd().iterdir())}))
print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 170, "output_tokens": 4}}))
''')
            executable.chmod(0o755)
            with mock.patch.dict(os.environ, {"CAPTURE": str(capture)}):
                result = run_probe(str(home), executable=str(executable), timeout=5)
            self.assertEqual(result["status"], "success")
            observed = json.loads(capture.read_text())
            model = observed["catalog"]["models"][0]
            self.assertEqual(model["tool_mode"], "direct")
            self.assertIsNone(model["apply_patch_tool_type"])
            self.assertFalse(model["use_responses_lite"])
            self.assertEqual(observed["instruction"], "Silence")
            self.assertEqual(observed["args"][-1], ".")
            self.assertTrue(observed["auth_link"])
            self.assertTrue(observed["cwd_empty"])
            self.assertFalse(Path(observed["root"]).exists())

    def test_catalog_failure_does_not_fall_back(self):
        """미지원 CLI에서 추가 모델 요청 없이 명시적 구성 실패 검증."""
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "auth.json").write_text("fixture")
            executable = root / "codex"
            executable.write_text("#!/bin/sh\nexit 1\n")
            executable.chmod(0o755)
            with self.assertRaises(ServiceError) as raised:
                run_probe(str(root), executable=str(executable), timeout=1)
            self.assertEqual(raised.exception.status, "configuration")
