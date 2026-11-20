#!/bin/bash
# Сборка AgentHUD.app из исходников (нужны только Command Line Tools).
#
#   scripts/build-app.sh            собрать build/AgentHUD.app
#   scripts/build-app.sh --install  ещё и положить в ~/Applications + симлинк ~/.local/bin/agenthud-hook
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AgentHUD
swift build -c release --product agenthud-hook
BIN="$(swift build -c release --show-bin-path)"

APP=build/AgentHUD.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/AgentHUD" "$APP/Contents/MacOS/AgentHUD"
cp "$BIN/agenthud-hook" "$APP/Contents/Helpers/agenthud-hook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Шрифты (OFL): Golos Text, IBM Plex Mono
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# Ресурсы SwiftPM (если появятся)
for b in "$BIN"/*.bundle; do [ -e "$b" ] && case "$b" in *Tests*) ;; *) cp -R "$b" "$APP/Contents/Resources/";; esac; done
# Подпись ad-hoc: без неё macOS не запомнит разрешение на управление Терминалом.
codesign --force --sign - "$APP/Contents/Helpers/agenthud-hook"
codesign --force --sign - "$APP"
echo "Собрано: $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications" "$HOME/.local/bin"
    pkill -x AgentHUD 2>/dev/null || true
    rm -rf "$HOME/Applications/AgentHUD.app"
    cp -R "$APP" "$HOME/Applications/AgentHUD.app"
    ln -sfn "$HOME/Applications/AgentHUD.app/Contents/Helpers/agenthud-hook" "$HOME/.local/bin/agenthud-hook"
    echo "Установлено: ~/Applications/AgentHUD.app, хук: ~/.local/bin/agenthud-hook"
    echo "Запуск: open ~/Applications/AgentHUD.app"
fi
