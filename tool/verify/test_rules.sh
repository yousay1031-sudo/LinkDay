#!/usr/bin/env bash
# firestore.rules のテストを、起動中のローカル Firestore エミュレータで実行する。
#   前提: tool/verify/start_emulators.sh で 127.0.0.1:8080 が起動していること。
#   プロジェクトIDは demo-linkday-rules（検証データ demo-linkday は消さない）。
#   本番には接続しない。firebase deploy もしない。
set -euo pipefail
cd "$(dirname "$0")/../.."
unset GOOGLE_APPLICATION_CREDENTIALS FIREBASE_TOKEN
if ! curl -s -m 2 http://127.0.0.1:8080/ | grep -q Ok; then
  echo "Firestore エミュレータ(127.0.0.1:8080)が起動していません。tool/verify/start_emulators.sh を先に実行してください" >&2
  exit 1
fi
cd test_rules
if [ ! -d node_modules ]; then
  npm ci --no-audit --no-fund
fi
npm test
