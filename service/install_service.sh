#!/bin/bash
#
# Встановлює Flight Weather Service як LaunchAgent (автозапуск при вході в систему).
# Запуск:  bash install_service.sh
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Library/Application Support/FlightWeather"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LABEL="com.garrysun.flightweather.service"
PLIST="$AGENTS_DIR/$LABEL.plist"

echo "==> Копіюю сервіс у $APP_DIR"
mkdir -p "$APP_DIR" "$AGENTS_DIR" "$HOME/Library/Logs"
cp "$SRC_DIR/weather_service.py" "$APP_DIR/weather_service.py"
chmod +x "$APP_DIR/weather_service.py"

echo "==> Готую LaunchAgent"
sed "s|__HOME__|$HOME|g" "$SRC_DIR/$LABEL.plist" > "$PLIST"

echo "==> Перезавантажую агент"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "==> Перевірка (чекаю 3 с)"
sleep 3
if curl -sf "http://127.0.0.1:8787/health" >/dev/null; then
  echo "OK: сервіс працює"
  curl -s "http://127.0.0.1:8787/weather" | python3 -m json.tool | head -20
else
  echo "ПОМИЛКА: сервіс не відповідає. Дивіться ~/Library/Logs/flightweather.err.log"
  exit 1
fi

cat <<'EOF'

Готово. Керування:
  launchctl kickstart -k gui/$(id -u)/com.garrysun.flightweather.service   # перезапуск
  launchctl bootout gui/$(id -u)/com.garrysun.flightweather.service        # вимкнути
  tail -f ~/Library/Logs/flightweather.err.log                            # логи

Змінити локацію/пороги: відредагуйте ~/Library/LaunchAgents/com.garrysun.flightweather.service.plist
і перезапустіть агент.
EOF
