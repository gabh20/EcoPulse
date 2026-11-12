from datetime import datetime, timezone
import httpx
from fastapi import HTTPException
from . import cache
from .geo import region_for


async def conditions(latitude, longitude):
    key = "environment:" + region_for(latitude, longitude)
    stored = cache.read(key)
    if stored:
        return stored
    params = {"latitude": latitude, "longitude": longitude, "timezone": "UTC"}
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            weather = await client.get("https://api.open-meteo.com/v1/forecast", params={**params, "current": "temperature_2m"})
            weather.raise_for_status()
            air = await client.get("https://air-quality-api.open-meteo.com/v1/air-quality", params={**params, "current": "european_aqi", "domains": "cams_global"})
            air.raise_for_status()
        w, a = weather.json()["current"], air.json()["current"]
        result = {
            "temperature_celsius": w["temperature_2m"], "european_aqi": a["european_aqi"],
            "weather_time": w["time"] + "Z", "air_time": a["time"] + "Z",
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "source": "Open-Meteo / CAMS", "kind": "Estimativas de modelos ambientais",
            "latitude": latitude, "longitude": longitude,
        }
        cache.write(key, result, ttl=600)
        return result
    except (httpx.HTTPError, KeyError, ValueError) as error:
        raise HTTPException(503, "Dados ambientais temporariamente indisponíveis.") from error
