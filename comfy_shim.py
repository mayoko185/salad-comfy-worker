import asyncio
import logging
import ssl
from urllib.parse import urlparse

from aiohttp import web, ClientSession, WSMsgType

REMOTE_BASE = "https://guava-chef-92xadpojy5duy5qu.salad.cloud"

LOCAL_HOST = "127.0.0.1"   # if needed, try "0.0.0.0" and use http://localhost:8188
LOCAL_PORT = 8188

UPSTREAM_WS_HEARTBEAT_SEC = 15
UPSTREAM_RECONNECT_DELAY_SEC = 2
UPSTREAM_RECONNECT_MAX_DELAY_SEC = 20

UPSTREAM_HOST = urlparse(REMOTE_BASE).netloc

log = logging.getLogger("comfy_shim")


def _join_url(base: str, path_qs: str) -> str:
    return base.rstrip("/") + path_qs


def _strip_req_headers(headers: dict) -> dict:
    out = dict(headers)
    for h in [
        "Host", "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
        "TE", "Trailer", "Transfer-Encoding", "Upgrade",
        "Origin",
    ]:
        out.pop(h, None)
    return out


def _upstream_headers(request_headers: dict) -> dict:
    h = _strip_req_headers(request_headers)
    h["Host"] = UPSTREAM_HOST
    h["Origin"] = REMOTE_BASE
    return h


def _strip_resp_headers(headers: dict) -> dict:
    # We are re-emitting a body we already read into memory; these headers can be wrong afterwards
    out = dict(headers)
    for h in [
        "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
        "TE", "Trailer", "Transfer-Encoding", "Upgrade",
        "Content-Encoding",   # critical: avoid saying "br/gzip" if body is already decoded
        "Content-Length",     # let aiohttp compute
    ]:
        out.pop(h, None)
    return out


def _looks_like_json_path(path: str) -> bool:
    # ComfyUI core API
    if path.startswith(("/system_stats", "/object_info", "/prompt", "/queue", "/history", "/interrupt")):
        return True

    # Krita (ETN) plugin API surface seen in your logs (/api/etn/*)
    if path.startswith("/api/etn/"):
        return True

    return False


async def proxy_http(request: web.Request) -> web.StreamResponse:
    upstream_url = _join_url(REMOTE_BASE, request.rel_url.path_qs)
    log.info("HTTP %s %s -> %s", request.method, request.rel_url.path_qs, upstream_url)

    headers = _upstream_headers(request.headers)
    body = await request.read()

    async with request.app["client"].request(
        method=request.method,
        url=upstream_url,
        headers=headers,
        data=body if body else None,
        allow_redirects=False,
    ) as resp:
        data = await resp.read()

        out_headers = _strip_resp_headers(resp.headers)

        # Optional: help strict clients by forcing JSON type on known JSON endpoints
        if _looks_like_json_path(request.rel_url.path):
            out_headers["Content-Type"] = "application/json"

        return web.Response(status=resp.status, headers=out_headers, body=data)


async def _bridge_ws_once(ws_local: web.WebSocketResponse, request: web.Request) -> bool:
    if ws_local.closed:
        return False

    upstream_ws_base = REMOTE_BASE.replace("https://", "wss://").replace("http://", "ws://")
    upstream_url = _join_url(upstream_ws_base, request.rel_url.path_qs)

    log.info("WS -> %s", upstream_url)

    headers = _upstream_headers(request.headers)

    ws_up = await request.app["client"].ws_connect(
        upstream_url,
        headers=headers,
        ssl=request.app["ssl_ctx"],
        autoping=False,
        heartbeat=UPSTREAM_WS_HEARTBEAT_SEC,
        max_msg_size=0,
    )

    async def forward(src, dst, direction: str):
        async for msg in src:
            if msg.type == WSMsgType.TEXT:
                await dst.send_str(msg.data)
            elif msg.type == WSMsgType.BINARY:
                await dst.send_bytes(msg.data)
            elif msg.type == WSMsgType.CLOSE:
                log.info("WS %s close received", direction)
                await dst.close()
                break
            elif msg.type == WSMsgType.ERROR:
                log.warning("WS %s error: %s", direction, src.exception())
                break

    try:
        t1 = asyncio.create_task(forward(ws_local, ws_up, "local->upstream"))
        t2 = asyncio.create_task(forward(ws_up, ws_local, "upstream->local"))

        done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
        for t in pending:
            t.cancel()

        if ws_local.closed:
            return False

        return True
    finally:
        await ws_up.close()


async def proxy_ws(request: web.Request) -> web.WebSocketResponse:
    log.info("WS incoming %s", request.rel_url.path_qs)

    ws_local = web.WebSocketResponse(autoping=True, max_msg_size=0)
    await ws_local.prepare(request)

    delay = UPSTREAM_RECONNECT_DELAY_SEC
    try:
        while not ws_local.closed:
            try:
                should_reconnect = await _bridge_ws_once(ws_local, request)
                if not should_reconnect:
                    break

                log.warning("WS upstream dropped; reconnecting in %ss", delay)
                await asyncio.sleep(delay)
                delay = min(delay * 2, UPSTREAM_RECONNECT_MAX_DELAY_SEC)

            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("WS bridge exception: %r; reconnecting in %ss", e, delay)
                await asyncio.sleep(delay)
                delay = min(delay * 2, UPSTREAM_RECONNECT_MAX_DELAY_SEC)
    finally:
        await ws_local.close()

    return ws_local


async def handler(request: web.Request) -> web.StreamResponse:
    log.info("IN %s %s", request.method, request.rel_url.path_qs)
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await proxy_ws(request)
    return await proxy_http(request)


async def on_startup(app: web.Application):
    # auto_decompress=True by default; that’s fine as long as we strip Content-Encoding on the way out
    app["client"] = ClientSession(timeout=None)
    app["ssl_ctx"] = ssl.create_default_context()


async def on_cleanup(app: web.Application):
    await app["client"].close()


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    app = web.Application(client_max_size=1024**3)
    app.router.add_route("*", "/{tail:.*}", handler)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)

    log.info("Starting shim on http://%s:%d -> %s", LOCAL_HOST, LOCAL_PORT, REMOTE_BASE)
    web.run_app(app, host=LOCAL_HOST, port=LOCAL_PORT)


if __name__ == "__main__":
    main()
