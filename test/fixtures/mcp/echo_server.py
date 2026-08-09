#!/usr/bin/env python3
"""Minimal stdio MCP server fixture for Hwfl.Mcp.Client / Runtime.Mcp tests.

Speaks newline-delimited JSON-RPC 2.0 on stdin/stdout (spec docs/spec/13-mcp.md).
Exposes three tools:
  - echo(text: String)               -> { "echoed": text }
  - add(a: Number, b: Number)        -> { "sum": a + b }   (used to test @bind@)
  - boom(text: String)               -> tool-level isError: true

An optional "sleep_ms" tool call argument on any tool delays the response,
used by client tests to exercise the per-request timeout.
"""
import json
import sys
import time

TOOLS = [
    {
        "name": "echo",
        "description": "Echo the given text back as JSON.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
    {
        "name": "add",
        "description": "Add two numbers.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "a": {"type": "number"},
                "b": {"type": "number"},
            },
            "required": ["a", "b"],
        },
    },
    {
        "name": "boom",
        "description": "Always reports a tool-level error.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def content_result(value):
    return {"content": [{"type": "text", "text": json.dumps(value)}]}


def error_result(message):
    return {"isError": True, "content": [{"type": "text", "text": message}]}


def handle_call(params):
    name = params.get("name")
    args = params.get("arguments") or {}
    sleep_ms = args.get("sleep_ms")
    if sleep_ms:
        time.sleep(sleep_ms / 1000.0)
    if name == "echo":
        return content_result({"echoed": args.get("text", "")})
    if name == "add":
        return content_result({"sum": args.get("a", 0) + args.get("b", 0)})
    if name == "boom":
        return error_result("boom failed")
    return error_result(f"unknown tool: {name}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        method = req.get("method")
        req_id = req.get("id")
        if method == "initialize":
            send(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": "2025-06-18",
                        "capabilities": {},
                        "serverInfo": {"name": "hwfl-test-echo", "version": "0.1.0"},
                    },
                }
            )
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            result = handle_call(req.get("params") or {})
            send({"jsonrpc": "2.0", "id": req_id, "result": result})
        elif req_id is not None:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32601, "message": f"method not found: {method}"},
                }
            )


if __name__ == "__main__":
    main()
