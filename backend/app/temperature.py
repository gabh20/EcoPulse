from datetime import datetime, timezone
import math
import httpx
from fastapi import HTTPException
from . import cache

STEP = 0.05


def grid_for(latitude, longitude):
    row = min(3599, max(0, math.floor((latitude + 90) / STEP)))
    column = min(7199, max(0, math.floor((longitude + 180) / STEP)))
    cells = []
    for r in range(max(0, row - 2), min(3600, row + 3)):
        for c in range(max(0, column - 2), min(7200, column + 3)):
            south, west = round(r * STEP - 90, 6), round(c * STEP - 180, 6)
            cells.append({"south": south, "west": west,
                          "north": round(south + STEP, 6), "east": round(west + STEP, 6)})
    anchor = {"south": round(row * STEP - 90, 6), "west": round(column * STEP - 180, 6),
              "north": round((row + 1) * STEP - 90, 6), "east": round((column + 1) * STEP - 180, 6)}
    return f"{row}:{column}", anchor, cells


async def temperature_grid(latitude, longitude):
    grid_id, anchor, cells = grid_for(latitude, longitude)
    key = "temperature:v1:" + grid_id
    stored = cache.read(key)
    if stored is not None:
        return stored
    params = {
        "latitude": ",".join(str(round((c["south"] + c["north"]) / 2, 6)) for c in cells),
        "longitude": ",".join(str(round((c["west"] + c["east"]) / 2, 6)) for c in cells),
        "current": "temperature_2m", "temperature_unit": "celsius", "timezone": "UTC",
        "forecast_days": 1,
    }
    try:
        async with httpx.AsyncClient(timeout=12) as client:
            response = await client.get("https://api.open-meteo.com/v1/forecast", params=params)
            response.raise_for_status()
        data = response.json()
        if not isinstance(data, list) or len(data) != len(cells):
            raise ValueError("Quantidade de pontos inesperada.")
        valid = []
        for bounds, point in zip(cells, data):
            current = point["current"]
            value = current["temperature_2m"]
            if value is None:
                continue
            if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
                raise ValueError("Temperatura inválida.")
            if point["current_units"]["temperature_2m"] != "°C":
                raise ValueError("Unidade inesperada.")
            timestamp = datetime.fromisoformat(current["time"])
            if timestamp.tzinfo is None:
                timestamp = timestamp.replace(tzinfo=timezone.utc)
            valid.append({**bounds, "temperature_celsius": value, "weather_time": timestamp.isoformat()})
        if not valid:
            raise ValueError("Sem temperatura disponível.")
        result = {"grid_id": grid_id, "anchor": anchor, "cells": valid,
                  "fetched_at": datetime.now(timezone.utc).isoformat(),
                  "source": "Open-Meteo", "source_url": "https://open-meteo.com/",
                  "kind": "Temperatura do ar estimada a 2 m; modelos meteorológicos regionais",
                  "sampling_degrees": STEP, "missing_cells": len(cells) - len(valid)}
        cache.write(key, result, ttl=600)
        return result
    except (httpx.HTTPError, KeyError, ValueError, TypeError) as error:
        raise HTTPException(503, "Camada de temperatura temporariamente indisponível. Tente novamente.") from error
