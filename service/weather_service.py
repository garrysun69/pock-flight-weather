#!/usr/bin/env python3
"""
Flight Weather Service для Pock-віджета.

Локальний HTTP-сервіс: тягне погоду з Open-Meteo (без API-ключа),
рахує flight-safe статус і віддає компактний JSON на http://127.0.0.1:8787/weather

Ендпоінти:
  GET /weather  -> дані погоди + статус (good | marginal | no-go)
  GET /health   -> {"ok": true}
"""

import json
import os
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------- Конфіг (можна перекрити змінними оточення) ----------
LAT = float(os.environ.get("FWS_LAT", "50.5583"))    # Нові Петрівці
LON = float(os.environ.get("FWS_LON", "30.4383"))
PORT = int(os.environ.get("FWS_PORT", "8787"))
TTL = int(os.environ.get("FWS_TTL", "300"))          # кеш, секунд

# Пороги для оцінки польотних умов (м/с, мм/год, метри)
LIMITS = {
    "wind_marginal": float(os.environ.get("FWS_WIND_MARGINAL", "8")),
    "wind_nogo": float(os.environ.get("FWS_WIND_NOGO", "12")),
    "gust_marginal": float(os.environ.get("FWS_GUST_MARGINAL", "10")),
    "gust_nogo": float(os.environ.get("FWS_GUST_NOGO", "15")),
    "precip_marginal": float(os.environ.get("FWS_PRECIP_MARGINAL", "0.2")),
    "precip_nogo": float(os.environ.get("FWS_PRECIP_NOGO", "1.0")),
    "vis_marginal": float(os.environ.get("FWS_VIS_MARGINAL", "5000")),
    "vis_nogo": float(os.environ.get("FWS_VIS_NOGO", "1500")),
    "cloud_marginal": float(os.environ.get("FWS_CLOUD_MARGINAL", "85")),
}

API = (
    "https://api.open-meteo.com/v1/forecast"
    "?latitude={lat}&longitude={lon}"
    "&current=temperature_2m,apparent_temperature,relative_humidity_2m,"
    "precipitation,cloud_cover,visibility,wind_speed_10m,wind_direction_10m,"
    "wind_gusts_10m,weather_code,is_day"
    "&hourly=temperature_2m,precipitation_probability,wind_speed_10m,wind_gusts_10m"
    "&forecast_hours=6"
    "&wind_speed_unit=ms&timezone=auto"
)

DIRS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

WMO = {
    0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast",
    45: "fog", 48: "rime fog", 51: "light drizzle", 53: "drizzle",
    55: "heavy drizzle", 61: "light rain", 63: "rain", 65: "heavy rain",
    71: "light snow", 73: "snow", 75: "heavy snow", 80: "rain showers",
    81: "rain showers", 82: "violent showers", 95: "thunderstorm",
    96: "thunderstorm + hail", 99: "thunderstorm + hail",
}

_lock = threading.Lock()
_cache = {"payload": None, "ts": None}


def deg_to_dir(deg):
    return DIRS[int((float(deg) % 360) / 22.5 + 0.5) % 16]


def assess(wind, gust, precip, vis, cloud, code):
    """Повертає (status, reasons)."""
    reasons = []
    status = "good"

    def bump(level, why):
        nonlocal status
        reasons.append(why)
        order = {"good": 0, "marginal": 1, "no-go": 2}
        if order[level] > order[status]:
            status = level

    if wind >= LIMITS["wind_nogo"]:
        bump("no-go", f"вітер {wind:.1f} м/с")
    elif wind >= LIMITS["wind_marginal"]:
        bump("marginal", f"вітер {wind:.1f} м/с")

    if gust >= LIMITS["gust_nogo"]:
        bump("no-go", f"пориви {gust:.1f} м/с")
    elif gust >= LIMITS["gust_marginal"]:
        bump("marginal", f"пориви {gust:.1f} м/с")

    if precip >= LIMITS["precip_nogo"]:
        bump("no-go", f"опади {precip:.1f} мм/год")
    elif precip >= LIMITS["precip_marginal"]:
        bump("marginal", f"опади {precip:.1f} мм/год")

    if vis is not None:
        if vis <= LIMITS["vis_nogo"]:
            bump("no-go", f"видимість {vis/1000:.1f} км")
        elif vis <= LIMITS["vis_marginal"]:
            bump("marginal", f"видимість {vis/1000:.1f} км")

    if code in (95, 96, 99):
        bump("no-go", "гроза")
    elif code in (45, 48):
        bump("marginal", "туман")

    # Хмарність — інформативно, на статус не впливає (VLOS не залежить від overcast)

    return status, reasons


def build_payload():
    url = API.format(lat=LAT, lon=LON)
    req = urllib.request.Request(url, headers={"User-Agent": "FlightWeatherService/1.0"})
    with urllib.request.urlopen(req, timeout=12) as resp:
        raw = json.loads(resp.read().decode("utf-8"))

    cur = raw.get("current", {})
    temp = float(cur.get("temperature_2m", 0) or 0)
    feels = float(cur.get("apparent_temperature", temp) or temp)
    wind = float(cur.get("wind_speed_10m", 0) or 0)
    gust = float(cur.get("wind_gusts_10m", 0) or 0)
    wdir = float(cur.get("wind_direction_10m", 0) or 0)
    cloud = float(cur.get("cloud_cover", 0) or 0)
    precip = float(cur.get("precipitation", 0) or 0)
    hum = float(cur.get("relative_humidity_2m", 0) or 0)
    code = int(cur.get("weather_code", 0) or 0)
    vis = cur.get("visibility")
    vis = float(vis) if vis is not None else None

    status, reasons = assess(wind, gust, precip, vis, cloud, code)

    hourly = raw.get("hourly", {})
    times = hourly.get("time", []) or []
    forecast = []
    for i in range(min(6, len(times))):
        forecast.append({
            "time": times[i],
            "temperature": hourly.get("temperature_2m", [None] * 6)[i],
            "wind_speed": hourly.get("wind_speed_10m", [None] * 6)[i],
            "wind_gusts": hourly.get("wind_gusts_10m", [None] * 6)[i],
            "precip_probability": hourly.get("precipitation_probability", [None] * 6)[i],
        })

    wind_dir = deg_to_dir(wdir)
    short = f"{temp:.0f}°  {wind_dir} {wind:.0f}/{gust:.0f} m/s"

    return {
        "status": status,
        "reasons": reasons,
        "short": short,
        "temperature": round(temp, 1),
        "apparent_temperature": round(feels, 1),
        "humidity": round(hum),
        "wind_speed": round(wind, 1),
        "wind_gusts": round(gust, 1),
        "wind_direction": round(wdir),
        "wind_direction_text": wind_dir,
        "cloud_cover": round(cloud),
        "visibility": vis,
        "precipitation": round(precip, 2),
        "condition": WMO.get(code, f"code {code}"),
        "is_day": bool(cur.get("is_day", 1)),
        "location": {"lat": LAT, "lon": LON},
        "forecast": forecast,
        "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }


def get_weather():
    now = datetime.now(timezone.utc)
    with _lock:
        fresh = (
            _cache["payload"] is not None
            and _cache["ts"] is not None
            and (now - _cache["ts"]).total_seconds() < TTL
        )
        if fresh:
            return _cache["payload"], True
    try:
        payload = build_payload()
        with _lock:
            _cache["payload"] = payload
            _cache["ts"] = now
        return payload, False
    except Exception as exc:  # мережа впала — віддаємо старе, якщо є
        with _lock:
            if _cache["payload"] is not None:
                stale = dict(_cache["payload"])
                stale["stale"] = True
                stale["error"] = str(exc)
                return stale, True
        return {"status": "unknown", "short": "n/a", "error": str(exc)}, False


class Handler(BaseHTTPRequestHandler):
    server_version = "FlightWeatherService/1.0"

    def log_message(self, fmt, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path in ("/weather", "/"):
            payload, _ = get_weather()
            self._json(200, payload)
        elif path == "/health":
            self._json(200, {"ok": True, "port": PORT})
        else:
            self._json(404, {"error": "not found"})


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Flight Weather Service -> http://127.0.0.1:{PORT}/weather")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
