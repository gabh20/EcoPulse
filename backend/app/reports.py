from datetime import datetime, timezone
import pygeohash
from . import cache
from .db import database, json_row, REPORT_COLUMNS
from .geo import distance_meters, region_for


def nearby(latitude, longitude, radius_meters):
    region = region_for(latitude, longitude)
    version = cache.reports_version()
    key = f"reports:{version}:{region}:{radius_meters}"
    candidates = cache.read(key) if version is not None else None
    if candidates is None:
        cell = pygeohash.decode_exactly(region)
        center_lat, center_lon, lat_error, lon_error = cell
        margin = distance_meters(center_lat, center_lon, center_lat + lat_error, center_lon + lon_error) + 10
        with database() as connection:
            rows = connection.execute(f"""
                SELECT {REPORT_COLUMNS} FROM reports
                WHERE status='ACTIVE' AND expires_at > now()
                AND ST_DWithin(location, ST_SetSRID(ST_MakePoint(%s,%s),4326)::geography,%s)
                ORDER BY observed_at DESC
            """, (center_lon, center_lat, radius_meters + margin)).fetchall()
        candidates = [json_row(row) for row in rows]
        if version is not None:
            cache.write(key, candidates)
    now = datetime.now(timezone.utc)
    return [row for row in candidates
            if datetime.fromisoformat(row["expires_at"]) > now
            and distance_meters(latitude, longitude, row["latitude"], row["longitude"]) <= radius_meters]
