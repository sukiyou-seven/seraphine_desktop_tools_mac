#!/usr/bin/env python3
"""Seraphim MCP 桥：把 stdio 上的 MCP 请求转发给面板的 HTTPS 端点。

很多 AI 客户端只会用 stdio 方式启动 MCP 服务，而面板本身是 HTTPS 服务。
这个脚本就干一件事：把 stdin 上按行进来的 JSON-RPC 原样发给面板的 /v1/mcp，
再把响应按行写回 stdout。它不含任何业务逻辑，也不需要装任何第三方包。

用法（配置在 AI 客户端的 MCP 设置里）：

    {
      "mcpServers": {
        "seraphim": {
          "command": "python3",
          "args": ["/path/to/seraphim-mcp.py"],
          "env": {
            "SERAPHIM_ENDPOINT": "https://192.168.0.103:27520",
            "SERAPHIM_TOKEN": "在面板「API 设置」里生成的令牌",
            "SERAPHIM_FINGERPRINT": "服务端证书的 SHA-256 指纹，可选"
          }
        }
      }
    }

也用命令行参数：--endpoint / --token / --fingerprint，环境变量优先。
"""

import json
import os
import socket
import ssl
import sys
from hashlib import sha256

DEFAULT_TIMEOUT = 130.0
# 面板给 MCP 的路径。写在常量里，改了服务端要一起改。
MCP_PATH = "/v1/mcp"


def log(message):
    """诊断信息一律走 stderr：stdout 是协议通道，混进一行非 JSON 就废了。"""
    sys.stderr.write("[seraphim-mcp] %s\n" % message)
    sys.stderr.flush()


def parse_arguments(argv):
    options = {}
    index = 0
    while index < len(argv):
        item = argv[index]
        if item in ("--endpoint", "--token", "--fingerprint") and index + 1 < len(argv):
            options[item[2:]] = argv[index + 1]
            index += 2
            continue
        if item in ("-h", "--help"):
            sys.stdout.write(__doc__)
            raise SystemExit(0)
        index += 1
    endpoint = os.environ.get("SERAPHIM_ENDPOINT") or options.get("endpoint") or ""
    token = os.environ.get("SERAPHIM_TOKEN") or options.get("token") or ""
    fingerprint = (os.environ.get("SERAPHIM_FINGERPRINT") or options.get("fingerprint") or "").lower()
    return endpoint.strip(), token.strip(), fingerprint.replace(":", "").replace(" ", "")


def split_endpoint(endpoint):
    if not endpoint.startswith("https://"):
        raise ValueError("地址要以 https:// 开头，例如 https://192.168.0.103:27520")
    rest = endpoint[len("https://"):].rstrip("/")
    if "/" in rest:
        rest = rest.split("/")[0]
    if rest.startswith("["):  # IPv6 字面量
        host, _, tail = rest[1:].partition("]")
        port = int(tail[1:]) if tail.startswith(":") else 27520
        return host, port
    if ":" in rest:
        host, _, raw = rest.partition(":")
        return host, int(raw)
    return rest, 27520


def open_connection(host, port, fingerprint, timeout):
    """自签证书场景：自己握手，按指纹校验，再把它交给 HTTP 客户端复用。

    ssl 模块没有「校验完继续用这个连接」的钩子，所以先 wrap 一遍拿到对端证书，
    比对指纹通过后把这个 socket 直接挂到 HTTPSConnection 上。
    """
    raw = socket.create_connection((host, port), timeout=timeout)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    wrapped = context.wrap_socket(raw, server_hostname=host)
    if fingerprint:
        der = wrapped.getpeercert(binary_form=True)
        actual = sha256(der).hexdigest()
        if actual != fingerprint:
            wrapped.close()
            raise ValueError("服务端证书指纹不匹配：期望 %s，实际 %s" % (fingerprint, actual))
    return wrapped


def forward(payload, endpoint, token, fingerprint, timeout):
    import http.client

    host, port = split_endpoint(endpoint)
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    sock = open_connection(host, port, fingerprint, timeout)
    connection = http.client.HTTPSConnection(host, port, timeout=timeout)
    connection.sock = sock
    try:
        connection.request("POST", MCP_PATH, body, {
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Content-Length": str(len(body)),
        })
        response = connection.getresponse()
        data = response.read().decode("utf-8", "replace")
        if response.status == 401:
            raise ValueError("令牌无效或已被吊销，请在面板「API 设置」里重新签发")
        if response.status != 200:
            raise ValueError("面板返回 HTTP %d：%s" % (response.status, data[:400]))
        return json.loads(data)
    finally:
        connection.close()


def failure(request_id, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": str(message)}}


def main():
    endpoint, token, fingerprint = parse_arguments(sys.argv[1:])
    if not endpoint or not token:
        log("缺少 SERAPHIM_ENDPOINT 或 SERAPHIM_TOKEN，请在 AI 客户端的 MCP 配置里补齐")
        return 2
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except ValueError:
            log("收到一行不是 JSON 的输入，已忽略")
            continue
        # 通知没有 id，按 JSON-RPC 规范不需要回任何东西。
        if isinstance(payload, dict) and payload.get("id") is None and "method" in payload:
            continue
        try:
            answer = forward(payload, endpoint, token, fingerprint, DEFAULT_TIMEOUT)
        except Exception as error:  # noqa: BLE001 - 任何异常都要变成协议错误，不能让桥崩掉
            log("转发失败：%s" % error)
            request_id = payload.get("id") if isinstance(payload, dict) else None
            answer = failure(request_id, error)
        sys.stdout.write(json.dumps(answer, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
