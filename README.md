# Flight Weather — власний погодний віджет для Pock

Заміна зламаному вбудованому Weather-віджету. Показує в Touch Bar погоду з оцінкою
польотних умов: **good / marginal / no-go** (кольоровий індикатор).

```
● 19°  ↖ 2/6 m/s
```

## Архітектура

| Частина | Що робить |
|---|---|
| `service/weather_service.py` | локальний HTTP-сервіс на `127.0.0.1:8787`, тягне Open-Meteo (без API-ключа), рахує flight-safe статус, кешує 5 хв |
| `widget/FlightWeatherWidget.swift` | Pock-віджет (PockKit): опитує сервіс раз на 2 хв, малює індикатор + текст |

Логіка оцінки живе в Python — можна правити пороги без перезбирання Swift-віджета.

## Крок 1. Сервіс

Швидка перевірка:

```bash
cd service
python3 weather_service.py
# в іншому терміналі:
curl -s http://127.0.0.1:8787/weather | python3 -m json.tool
```

Автозапуск (LaunchAgent):

```bash
bash service/install_service.sh
```

### Пороги (змінні оточення)

| Змінна | Дефолт | Значення |
|---|---|---|
| `FWS_LAT` / `FWS_LON` | 50.5583 / 30.4383 | Нові Петрівці |
| `FWS_PORT` | 8787 | порт сервісу |
| `FWS_TTL` | 300 | кеш, с |
| `FWS_WIND_MARGINAL` / `FWS_WIND_NOGO` | 8 / 12 | вітер, м/с |
| `FWS_GUST_MARGINAL` / `FWS_GUST_NOGO` | 10 / 15 | пориви, м/с |
| `FWS_PRECIP_MARGINAL` / `FWS_PRECIP_NOGO` | 0.2 / 1.0 | опади, мм/год |
| `FWS_VIS_MARGINAL` / `FWS_VIS_NOGO` | 5000 / 1500 | видимість, м |

Гроза (WMO 95/96/99) → одразу `no-go`, туман (45/48) → `marginal`.
Хмарність не впливає на статус, лише показується в деталях.

## Крок 2. Віджет

1. Xcode → New Project → macOS → **Bundle**, Bundle Extension = `pock`, ім'я `FlightWeatherWidget`.
2. Скопіюйте в проект `widget/FlightWeatherWidget.swift`, `widget/Info.plist`, `widget/Podfile`.
3. `pod install` у папці проекту, далі відкривайте `.xcworkspace`.
4. Переконайтесь, що в `Info.plist` `NSPrincipalClass` = `FlightWeatherWidget.FlightWeatherWidget`
   (модуль.клас — якщо перейменуєте таргет, поправте обидві частини).
5. Build. У `Products` з'явиться `FlightWeatherWidget.pock`.
6. Pock → menu → **Install Widget…** → перетягніть `.pock` (або просто двічі клікніть файл), потім Reload.
7. Pock → **Customize** → перетягніть Flight Weather у Touch Bar.

### Жести

| Жест | Дія |
|---|---|
| tap | перемикає режим: compact → wind (напрямок, пориви, видимість) → detail (статус + причини) |
| long press (0.6 с) | примусове оновлення |

## Формат JSON сервісу

```json
{
  "status": "marginal",
  "reasons": ["пориви 11.2 м/с"],
  "short": "19°  SSE 2/6 m/s",
  "temperature": 19.0,
  "apparent_temperature": 20.4,
  "wind_speed": 1.9,
  "wind_gusts": 5.6,
  "wind_direction": 148,
  "wind_direction_text": "SSE",
  "cloud_cover": 100,
  "visibility": 22620.0,
  "precipitation": 0.0,
  "condition": "overcast",
  "forecast": [{ "time": "...", "wind_gusts": 4.5, "precip_probability": 45 }],
  "updated_at": "2026-08-30T09:53:47+00:00"
}
```

## Діагностика

| Симптом | Причина / рішення |
|---|---|
| `wx: service offline` у Touch Bar | сервіс не запущено: `curl http://127.0.0.1:8787/health` |
| Віджет не з'являється в Customize | не співпадає `NSPrincipalClass` (потрібно `Модуль.Клас`) |
| HTTP-запити блокуються | перевірте блок `NSAppTransportSecurity` в `Info.plist` віджета |
| `"stale": true` у відповіді | немає інтернету, віддається останнє успішне значення |

## Джерела

- [Pock](https://pock.app/) і [документація PockKit](https://pock.app/docs/) — офіційний сайт
- [pock/pockkit](https://github.com/pock/pockkit) — фреймворк, встановлення через CocoaPods (`pod 'PockKit'`)
- [Розбір розробки плагінів для Pock](https://qiita.com/p_x9/items/b75cacfcf99cbad8c485) — вимоги `PKWidget` (`identifier`, `customizationLabel`, `view`), ключі `Info.plist`, збірка `.pock`
- [Open-Meteo Forecast API](https://open-meteo.com/en/docs) — джерело погодних даних
