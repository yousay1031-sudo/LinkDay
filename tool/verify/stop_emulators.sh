#!/usr/bin/env bash
# 検証用エミュレータと検証用配信サーバーを停止する。
set -uo pipefail
PORT=${LINKDAY_VERIFY_WEB_PORT:-8765}
pkill -f "firebase emulators:start" 2>/dev/null || true
pkill -f "cloud-firestore-emulator" 2>/dev/null || true
(lsof -ti:"$PORT" | xargs -r kill) 2>/dev/null || true
sleep 1
ss -ltn | grep -E ':(9099|8080|4400|9150|'"$PORT"') ' || echo "停止しました (9099/8080/$PORT は閉じています)"
