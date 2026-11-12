import hashlib
import math
import pygeohash


def region_for(latitude, longitude):
    return pygeohash.encode(latitude, longitude, precision=5)


def shard_for(region):
    return hashlib.sha256(region.encode()).digest()[0] % 2


def distance_meters(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    delta_lat = p2 - p1
    delta_lon = math.radians(lon2 - lon1)
    value = math.sin(delta_lat / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(delta_lon / 2) ** 2
    return 6371008.8 * 2 * math.asin(min(1, math.sqrt(value)))
