#!/usr/bin/env bash
# 検証構成の Web ビルド。出力は build/verify_web（本番 Hosting の public=build/web とは別）。
#   既定は release。profile を使う場合: MODE=profile tool/verify/build_verify.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
MODE=${MODE:-release}
case "$MODE" in release|profile) ;; *) echo "MODE は release か profile"; exit 2;; esac
flutter build web --$MODE -o build/verify_web \
  --dart-define=LINKDAY_VERIFY=true \
  --dart-define=LINKDAY_VERIFY_PROJECT=demo-linkday \
  --dart-define=LINKDAY_VERIFY_HOST=127.0.0.1 \
  --dart-define=LINKDAY_VERIFY_AUTH_PORT=9099 \
  --dart-define=LINKDAY_VERIFY_FIRESTORE_PORT=8080
echo "検証ビルド完了 ($MODE): build/verify_web  ※ firebase deploy には使わないこと"
