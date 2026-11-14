#!/usr/bin/env python3
"""Tests for scripts/zim-claude-numes-proxy.

Run directly:

    python3 tests/test-numes-proxy.py

The unit tests load the proxy as a module and check the translation tables.
The integration tests start a fake Numes endpoint and the real proxy in a
subprocess, then speak Anthropic Messages to it over loopback -- the same path
Claude Code takes.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.machinery import SourceFileLoader

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PROXY_PATH = os.path.join(REPO, "scripts", "zim-claude-numes-proxy")

loader = SourceFileLoader("numes_proxy", PROXY_PATH)
spec = importlib.util.spec_from_loader("numes_proxy", loader)
proxy = importlib.util.module_from_spec(spec)
loader.exec_module(proxy)


def anthropic_request(stream=False):
    return {
        "model": "claude-sonnet-4-5",  # a tier name, not a Numes id
        "max_tokens": 99999,
        "system": [{"type": "text", "text": "You are a test."}],
        "messages": [
            {"role": "user", "content": "read a.txt"},
            {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "Reading it."},
                    {
                        "type": "tool_use",
                        "id": "call_0",
                        "name": "read_file",
                        "input": {"path": "a.txt"},
                    },
                ],
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "call_0",
                        "content": "hello",
                    }
                ],
            },
        ],
        "tools": [
            {
                "name": "read_file",
                "description": "Read a file",
                "input_schema": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            }
        ],
        "tool_choice": {"type": "auto", "disable_parallel_tool_use": True},
        "temperature": 0.2,
        "stop_sequences": ["STOP"],
        "stream": stream,
    }


class TranslationTests(unittest.TestCase):
    def test_payload_maps_system_messages_tools_and_caps(self):
        payload = proxy.build_payload(anthropic_request(), "deepseek/deepseek-v4.1-flash", 8192)
        self.assertEqual(payload["model"], "deepseek/deepseek-v4.1-flash")
        self.assertEqual(payload["max_tokens"], 8192)  # capped to the model
        self.assertEqual(payload["messages"][0],
                         {"role": "system", "content": "You are a test."})
        self.assertEqual(payload["messages"][1],
                         {"role": "user", "content": "read a.txt"})
        assistant = payload["messages"][2]
        self.assertEqual(assistant["role"], "assistant")
        self.assertEqual(assistant["content"], "Reading it.")
        self.assertEqual(assistant["tool_calls"][0]["id"], "call_0")
        self.assertEqual(assistant["tool_calls"][0]["function"]["name"],
                         "read_file")
        self.assertEqual(json.loads(
            assistant["tool_calls"][0]["function"]["arguments"]),
            {"path": "a.txt"})
        self.assertEqual(payload["messages"][3],
                         {"role": "tool", "tool_call_id": "call_0",
                          "content": "hello"})
        self.assertEqual(payload["tools"][0]["type"], "function")
        self.assertEqual(payload["tools"][0]["function"]["parameters"]["type"],
                         "object")
        self.assertEqual(payload["tool_choice"], "auto")
        self.assertFalse(payload["parallel_tool_calls"])
        self.assertEqual(payload["temperature"], 0.2)
        self.assertEqual(payload["stop"], ["STOP"])

    def test_payload_preserves_a_real_numes_id(self):
        body = anthropic_request()
        body["model"] = "moonshotai/kimi-k3.1-pro"
        payload = proxy.build_payload(body, "deepseek/deepseek-v4.1-flash")
        self.assertEqual(payload["model"], "moonshotai/kimi-k3.1-pro")

    def test_tool_result_and_text_in_one_turn_are_ordered(self):
        body = {
            "model": "deepseek/deepseek-v4.1-flash",
            "messages": [
                {"role": "assistant", "content": [
                    {"type": "tool_use", "id": "call_9", "name": "x",
                     "input": {}}]},
                {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "call_9",
                     "content": "ok"},
                    {"type": "text", "text": "now continue"}]},
            ],
        }
        payload = proxy.build_payload(body, "deepseek/deepseek-v4.1-flash")
        roles = [m["role"] for m in payload["messages"]]
        self.assertEqual(roles, ["assistant", "tool", "user"])

    def test_response_maps_text_tool_calls_and_finish(self):
        data = {
            "choices": [{
                "message": {
                    "content": "Here you go.",
                    "tool_calls": [{
                        "id": "call_1", "type": "function",
                        "function": {"name": "read_file",
                                     "arguments": "{\"path\": \"b.txt\"}"},
                    }],
                },
                "finish_reason": "tool_calls",
            }],
            "usage": {"prompt_tokens": 12, "completion_tokens": 4},
        }
        result = proxy.openai_to_anthropic(data, "deepseek/deepseek-v4.1-flash")
        self.assertEqual(result["stop_reason"], "tool_use")
        self.assertEqual(result["usage"]["input_tokens"], 12)
        self.assertEqual(result["usage"]["output_tokens"], 4)
        self.assertEqual(result["content"][0],
                         {"type": "text", "text": "Here you go."})
        tool = result["content"][1]
        self.assertEqual(tool["type"], "tool_use")
        self.assertEqual(tool["id"], "call_1")
        self.assertEqual(tool["input"], {"path": "b.txt"})

    def test_finish_length_is_max_tokens(self):
        data = {"choices": [{"message": {"content": "cut"},
                             "finish_reason": "length"}]}
        result = proxy.openai_to_anthropic(data, "m/x")
        self.assertEqual(result["stop_reason"], "max_tokens")

    def test_errors_are_actionable(self):
        self.assertIn("numes.ai/dashboard/keys",
                      proxy.explain_failure(401, '{"error":{"message":"bad"}}'))
        self.assertIn("dashboard/billing", proxy.explain_failure(
            402, '{"error":{"metadata":{"error_type":"funding_held"}}}'))
        self.assertIn("tool-capable", proxy.explain_failure(
            503, '{"error":{"metadata":{"error_type":"provider_unavailable"}}}'))


class FakeUpstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _json(self, status, payload):
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection = True

    def do_GET(self):
        if self.path.split("?")[0].endswith("/models"):
            self.server.seen_auth = self.headers.get("Authorization")
            self._json(200, {"data": [{"id": "deepseek/deepseek-v4.1-flash"}]})
            return
        self._json(404, {"error": {"message": "no route"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        self.server.seen_body = body
        self.server.seen_auth = self.headers.get("Authorization")
        if getattr(self.server, "fail", False):
            self._json(401, {"error": {"message": "bad key",
                                       "code": 401}})
            return
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            chunks = [
                {"choices": [{"delta": {"content": "Let me read it."},
                              "finish_reason": None}]},
                {"choices": [{"delta": {"tool_calls": [{
                    "index": 0, "id": "call_1",
                    "function": {"name": "read_file",
                                 "arguments": "{\"path\": "}}]},
                    "finish_reason": None}]},
                {"choices": [{"delta": {"tool_calls": [{
                    "index": 0,
                    "function": {"arguments": "\"a.txt\"}"}}]},
                    "finish_reason": "tool_calls"}]},
                {"choices": [],
                 "usage": {"prompt_tokens": 10, "completion_tokens": 6}},
            ]
            for chunk in chunks:
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return
        self._json(200, {
            "choices": [{
                "message": {"content": "done"},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 5, "completion_tokens": 2},
        })


class LiveProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 0), FakeUpstream)
        cls.upstream.daemon_threads = True
        cls.upstream.fail = False
        cls.upstream_thread = threading.Thread(
            target=cls.upstream.serve_forever, daemon=True)
        cls.upstream_thread.start()

        cls.tmp = tempfile.mkdtemp(prefix="zim-proxy-test-")
        cls.port_file = os.path.join(cls.tmp, "port")
        cls.proc = subprocess.Popen([
            sys.executable, PROXY_PATH,
            "--port", "0",
            "--port-file", cls.port_file,
            "--upstream", "http://127.0.0.1:%d/api/v1"
                         % cls.upstream.server_address[1],
            "--model", "deepseek/deepseek-v4.1-flash",
            "--max-output", "8192",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.time() + 10
        while time.time() < deadline:
            if os.path.exists(cls.port_file) and os.path.getsize(cls.port_file):
                break
            if cls.proc.poll() is not None:
                raise RuntimeError("proxy exited: %s"
                                   % cls.proc.stderr.read().decode())
            time.sleep(0.05)
        else:
            raise RuntimeError("proxy did not write a port")
        with open(cls.port_file, encoding="utf-8") as handle:
            cls.port = int(handle.read().strip())
        cls.base = "http://127.0.0.1:%d" % cls.port

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        try:
            cls.proc.wait(5)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
        cls.upstream.shutdown()
        cls.upstream.server_close()

    def url(self, path):
        return self.base + path

    def post(self, path, body, headers=None):
        request = urllib.request.Request(
            self.url(path), data=json.dumps(body).encode(),
            headers=headers or {"Content-Type": "application/json",
                                "Authorization": "Bearer sk-test"},
            method="POST")
        return urllib.request.urlopen(request, timeout=10)

    def test_health(self):
        with urllib.request.urlopen(self.url("/health"), timeout=5) as response:
            data = json.loads(response.read())
        self.assertTrue(data["ok"])

    def test_non_streaming_turn(self):
        self.upstream.fail = False
        request = anthropic_request()
        with self.post("/v1/messages", request) as response:
            data = json.loads(response.read())
        self.assertEqual(data["type"], "message")
        self.assertEqual(data["content"][0], {"type": "text", "text": "done"})
        self.assertEqual(data["usage"]["input_tokens"], 5)
        self.assertEqual(self.upstream.seen_auth, "Bearer sk-test")
        body = self.upstream.seen_body
        self.assertEqual(body["model"], "deepseek/deepseek-v4.1-flash")
        self.assertEqual(body["max_tokens"], 8192)
        self.assertEqual(body["tools"][0]["function"]["name"], "read_file")
        self.assertEqual(body["messages"][-1]["role"], "tool")

    def test_streaming_turn_emits_anthropic_events(self):
        self.upstream.fail = False
        with self.post("/v1/messages", anthropic_request(stream=True)) as response:
            raw = response.read().decode()
        self.assertIn("event: message_start", raw)
        self.assertIn('"text_delta"', raw)
        self.assertIn("event: content_block_start", raw)
        self.assertIn('"type": "tool_use"', raw)
        self.assertIn('"partial_json"', raw)
        self.assertIn('"stop_reason": "tool_use"', raw)
        self.assertIn("event: message_stop", raw)

    def test_upstream_auth_failure_is_an_anthropic_error(self):
        self.upstream.fail = True
        try:
            self.post("/v1/messages", anthropic_request())
        except urllib.error.HTTPError as error:
            self.assertEqual(error.code, 401)
            body = json.loads(error.read())
            error.close()
        else:
            self.fail("expected an HTTP error")
        self.assertEqual(body["type"], "error")
        self.assertEqual(body["error"]["type"], "authentication_error")

    def test_models_route_is_forwarded(self):
        with urllib.request.urlopen(urllib.request.Request(
                self.url("/v1/models"),
                headers={"Authorization": "Bearer sk-test"}), timeout=5) as response:
            data = json.loads(response.read())
        self.assertEqual(data["data"][0]["id"], "deepseek/deepseek-v4.1-flash")
        self.assertEqual(self.upstream.seen_auth, "Bearer sk-test")

    def test_count_tokens(self):
        with self.post("/v1/messages/count_tokens",
                       anthropic_request()) as response:
            data = json.loads(response.read())
        self.assertGreater(data["input_tokens"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
