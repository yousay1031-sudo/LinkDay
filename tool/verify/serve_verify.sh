#!/usr/bin/env bash
# build/verify_web をローカル配信する（既定 127.0.0.1:8765。標準設定の Chrome で開けるポート）。
#   他経路(プレビューURL)へ出す必要がある場合のみ BIND=0.0.0.0 を指定する。
set -euo pipefail
cd "$(dirname "$0")/../.."
PORT=${LINKDAY_VERIFY_WEB_PORT:-8765}
BIND=${BIND:-127.0.0.1}
[ -f build/verify_web/index.html ] || { echo "先に tool/verify/build_verify.sh を実行"; exit 1; }
(lsof -ti:"$PORT" | xargs -r kill) 2>/dev/null || true
sleep 1
cat > /tmp/linkday_verify_server.py <<PY
import functools, http.server, socketserver
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache, must-revalidate')
        super().end_headers()
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
h = functools.partial(H, directory='$(pwd)/build/verify_web')
with socketserver.TCPServer(('$BIND', $PORT), h) as s:
    s.serve_forever()
PY
setsid -f python3 /tmp/linkday_verify_server.py > /tmp/linkday_verify_server.log 2>&1 < /dev/null
for i in $(seq 1 20); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.5; done
echo "配信中: http://127.0.0.1:$PORT/ (bind=$BIND)"
