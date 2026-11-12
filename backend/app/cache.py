import json
import logging
from functools import lru_cache
from redis import Redis, RedisCluster
from .config import settings

log = logging.getLogger(__name__)


@lru_cache
def client():
    options = dict(decode_responses=True, socket_connect_timeout=1, socket_timeout=1)
    config = settings()
    if config.redis_cluster:
        return RedisCluster.from_url(config.redis_url, **options)
    return Redis.from_url(config.redis_url, **options)


def read(key):
    try:
        value = client().get(key)
        return json.loads(value) if value else None
    except Exception:
        log.warning("Cache indisponível: consulta continuará pelo banco.")
        return None


def write(key, value, ttl=30):
    try:
        client().setex(key, ttl, json.dumps(value))
    except Exception:
        log.warning("Resultado não foi armazenado no cache.")


def reports_version():
    try:
        return client().get("reports:version") or "0"
    except Exception:
        return None


def invalidate_reports():
    try:
        client().incr("reports:version")
    except Exception:
        log.warning("Cache será renovado por TTL; evento de remoção tentará invalidar novamente.")
