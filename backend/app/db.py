from contextlib import contextmanager
from datetime import datetime
from uuid import UUID
import psycopg
from psycopg.rows import dict_row
from .config import settings


@contextmanager
def database():
    with psycopg.connect(settings().database_url, row_factory=dict_row, connect_timeout=5) as connection:
        yield connection


def json_row(row):
    return {key: value.isoformat() if isinstance(value, datetime) else str(value) if isinstance(value, UUID) else value
            for key, value in row.items()}


REPORT_COLUMNS = "id, user_id, type, description, latitude, longitude, accuracy_meters, observed_at, expires_at, status, region"
