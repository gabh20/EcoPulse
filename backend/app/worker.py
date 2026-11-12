import asyncio
import logging
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from psycopg.types.json import Jsonb
from . import broker, cache
from .config import settings
from .contracts import ReportEvent
from .db import database, json_row, REPORT_COLUMNS
from .geo import region_for

log = logging.getLogger(__name__)
VALIDITY_HOURS = {"FLOOD": 6, "BLOCKED_ROAD": 4, "SMOKE": 3, "AIR_QUALITY": 3, "HEAT": 3}


def expires_at(report):
    return report.observed_at + timedelta(hours=VALIDITY_HOURS[report.type])


async def process(body):
    event = ReportEvent.model_validate(body)
    report = event.report
    expiry = expires_at(report)
    status = "ACTIVE" if expiry > datetime.now(timezone.utc) else "EXPIRED"
    with database() as connection:
        submission = connection.execute("SELECT * FROM submissions WHERE id=%s FOR UPDATE", (report.id,)).fetchone()
        if submission is None or submission["user_id"] != event.user_id or submission["payload"] != report.model_dump(mode="json"):
            raise ValueError("Evento não corresponde ao relato recebido pela API.")
        row = connection.execute(f"""INSERT INTO reports(id,user_id,type,description,latitude,longitude,
            accuracy_meters,location,region,observed_at,expires_at,status)
            VALUES (%s,%s,%s,%s,%s,%s,%s,ST_SetSRID(ST_MakePoint(%s,%s),4326)::geography,%s,%s,%s,%s)
            ON CONFLICT(id) DO NOTHING RETURNING {REPORT_COLUMNS}
            """, (report.id,event.user_id,report.type,report.description,report.latitude,report.longitude,
                  report.accuracy_meters,report.longitude,report.latitude,region_for(report.latitude,report.longitude),
                  report.observed_at,expiry,status)).fetchone()
        if row:
            state = "PROCESSED" if status == "ACTIVE" else "EXPIRED"
            connection.execute("UPDATE submissions SET state=%s WHERE id=%s", (state,report.id))
            if status == "ACTIVE":
                event_id = uuid4()
                connection.execute("INSERT INTO outbox(id,body) VALUES (%s,%s)", (event_id, Jsonb({
                    "event_id": str(event_id), "type": "report.created", "report": json_row(row)})))
    if row:
        cache.invalidate_reports()


async def mark_failed(raw):
    try:
        report_id = ReportEvent.model_validate_json(raw).report.id
    except ValueError:
        return
    with database() as connection:
        connection.execute("UPDATE submissions SET state='FAILED' WHERE id=%s AND state NOT IN ('PROCESSED','EXPIRED','RESOLVED')", (report_id,))


async def dispatch_outbox():
    with database() as connection:
        rows = connection.execute("SELECT * FROM outbox WHERE published_at IS NULL ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 20").fetchall()
        for row in rows:
            await broker.publish("alerts", row["body"])
            connection.execute("UPDATE outbox SET published_at=now() WHERE id=%s", (row["id"],))


def expire_reports():
    with database() as connection:
        rows = connection.execute(f"""UPDATE reports SET status='EXPIRED'
            WHERE id IN (SELECT id FROM reports WHERE status='ACTIVE' AND expires_at <= now()
            FOR UPDATE SKIP LOCKED LIMIT 100) RETURNING {REPORT_COLUMNS}""").fetchall()
        for row in rows:
            event_id = uuid4()
            connection.execute("UPDATE submissions SET state='EXPIRED' WHERE id=%s", (row["id"],))
            connection.execute("INSERT INTO outbox(id,body) VALUES (%s,%s)", (event_id,Jsonb({
                "event_id": str(event_id), "type": "report.removed", "report": json_row(row)})))


async def maintenance():
    while True:
        try:
            expire_reports()
            await dispatch_outbox()
        except Exception:
            log.exception("Manutenção será repetida; eventos permanecem no banco.")
        await asyncio.sleep(5)


async def main():
    logging.basicConfig(level=logging.INFO)
    await asyncio.gather(broker.consume(f"reports.{settings().worker_shard}", process, mark_failed), maintenance())


if __name__ == "__main__":
    asyncio.run(main())
