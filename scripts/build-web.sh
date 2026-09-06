#!/usr/bin/env bash
# Builds the browser app into ./web-build, ready for the web container.
#
# Needs Flutter (>=3.44, per pubspec.lock). If you would rather not install it,
# take the web-app artifact from the Analyze workflow in GitHub Actions and
# unzip it into web-build/ instead -- the result is identical.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null; then
  echo "flutter not found. Use the CI artifact instead; see docs/selfhosting.md." >&2
  exit 1
fi

flutter pub get
# -t is not optional: the Android entry point reaches files importing dart:io,
# which cannot compile for web.
flutter build web --release -t lib/main_web.dart

rm -rf web-build
cp -r build/web web-build
echo "Built into web-build/. Now: docker compose up -d --build web"
