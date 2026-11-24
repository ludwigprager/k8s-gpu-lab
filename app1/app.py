"""app1: minimal test client for model1 (standard library only).

GET /healthz          -> "ok"
GET /ask?q=<question> -> {"answer": "..."}  (waits for a cold model1, see MODEL_WAIT_SECONDS)
"""
import json
import os
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE_URL = os.environ["OPENAI_BASE_URL"].rstrip("/")
API_KEY = os.environ.get("OPENAI_API_KEY", "")
MODEL = os.environ.get("OPENAI_MODEL", "model1")
WAIT_SECONDS = int(os.environ.get("MODEL_WAIT_SECONDS", "900"))


def ask(question: str) -> str:
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": question}],
        "max_tokens": 200,
    }).encode()
    deadline = time.time() + WAIT_SECONDS
    while True:
        req = urllib.request.Request(
            f"{BASE_URL}/chat/completions",
            data=body,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.load(resp)["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as e:
            if e.code < 500:          # 4xx (wrong key, bad request): retrying won't help
                raise
            err = e
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            err = e                   # model1 scaled to 0 or still loading
        if time.time() > deadline:
            raise TimeoutError(f"model1 not ready after {WAIT_SECONDS}s: {err}")
        print(f"model1 not ready yet ({err}), retrying in 5s", flush=True)
        time.sleep(5)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload) -> None:
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/healthz":
            return self._send(200, "ok")
        if url.path == "/ask":
            question = parse_qs(url.query).get("q", ["Say hello in one sentence."])[0]
            started = time.time()
            try:
                answer = ask(question)
            except Exception as e:  # noqa: BLE001 - report any failure to the caller
                return self._send(502, {"error": str(e)})
            return self._send(200, {"answer": answer, "seconds": round(time.time() - started, 1)})
        return self._send(404, {"error": "not found"})


if __name__ == "__main__":
    print(f"app1 listening on :8080, model1 at {BASE_URL}", flush=True)
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
