#!/usr/bin/env bash
# Tüm bileşenleri sırayla doğrular ve derler (CI ve yerel için tek giriş); ilk hatada durur.
set -euo pipefail
cd "$(dirname "$0")"
echo "==> docker build"; docker compose build
echo "==> lint";         make lint
echo "==> unit test";    make test.unit
echo "==> web build";    (cd web && ./build-wasm.sh)
echo "build.sh tamam"
