import asyncio
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import logging
import firebase_admin
from firebase_admin import credentials, messaging
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import ValidationError
from . import broker, cache
from .auth import decode_token
from .config import settings
from .contracts import LocationInput
from .db import database
from .geo import distance_meters
from .reports import nearby

log = logging.getLogger(__name__)


@dataclass
class Session:
    user_id: object
    location: LocationInput | None = None
    seen: set = field(default_factory=set)


sessions: dict[WebSocket, Session] = {}


def is_near(location, report):
    return location is not None and distance_meters(location.latitude, location.longitude,
        report["latitude"], report["longitude"]) <= location.radius_meters


def push_devices(report):
    with database() as connection:
        return connection.execute("""SELECT id,fcm_token FROM devices
            WHERE fcm_token IS NOT NULL AND updated_at > now() - interval '30 minutes'
            AND user_id <> %s
            AND ST_DWithin(location,ST_SetSRID(ST_MakePoint(%s,%s),4326)::geography,3000)
            """, (report["user_id"],report["longitude"],report["latitude"])).fetchall()


async def push(event):
    if not settings().firebase_credentials:
        return
    report = event["report"]
    for device in push_devices(report):
        remaining = datetime.fromisoformat(report['expires_at']) - datetime.now(timezone.utc)
        if remaining.total_seconds() <= 0:
            return
        with database() as connection:
            sent = connection.execute("SELECT 1 FROM push_deliveries WHERE event_id=%s AND device_id=%s",
                                      (event["event_id"],device["id"])).fetchone()
        if sent:
            continue
        try:
            await asyncio.to_thread(messaging.send, messaging.Message(
                token=device["fcm_token"],
                notification=messaging.Notification(title="EcoPulse: ocorrência próxima", body=report["description"] or report["type"]),
                data={"report_id": report["id"], "event_id": event["event_id"]},
                android=messaging.AndroidConfig(ttl=min(timedelta(minutes=30), remaining),
                    notification=messaging.AndroidNotification(tag=report["id"])),
            ))
        except messaging.UnregisteredError:
            with database() as connection:
                connection.execute("UPDATE devices SET fcm_token=NULL WHERE id=%s AND fcm_token=%s", (device["id"],device["fcm_token"]))
            continue
        with database() as connection:
            connection.execute("INSERT INTO push_deliveries(event_id,device_id) VALUES (%s,%s) ON CONFLICT DO NOTHING",
                               (event["event_id"],device["id"]))


async def deliver(event):
    report = event["report"]
    if event["type"] == "report.created" and datetime.fromisoformat(report["expires_at"]) <= datetime.now(timezone.utc):
        return
    if event["type"] == "report.created":
        with database() as connection:
            active = connection.execute(
                "SELECT 1 FROM reports WHERE id=%s AND status='ACTIVE' AND expires_at > now()",
                (report["id"],),
            ).fetchone()
        if not active:
            return
    elif event["type"] == "report.removed":
        cache.invalidate_reports()
    for socket, session in list(sessions.items()):
        try:
            if event["type"] == "report.removed":
                session.seen.discard(report["id"])
                await socket.send_json({"type": "report.removed", "report_id": report["id"], "status": report["status"]})
            elif is_near(session.location, report) and report["id"] not in session.seen:
                await socket.send_json({"type": "report.created", "report": report,
                    "notify": str(session.user_id) != report["user_id"]})
                session.seen.add(report["id"])
        except Exception:
            sessions.pop(socket, None)
    if event["type"] == "report.created":
        await push(event)


@asynccontextmanager
async def lifespan(app):
    logging.basicConfig(level=logging.INFO)
    if settings().firebase_credentials:
        firebase_admin.initialize_app(credentials.Certificate(settings().firebase_credentials))
    else:
        log.warning("Firebase não configurado: push desativado; WebSocket permanece disponível.")
    consumer = asyncio.create_task(broker.consume("alerts", deliver))
    yield
    consumer.cancel()
    await asyncio.gather(consumer, return_exceptions=True)
    if settings().firebase_credentials:
        firebase_admin.delete_app(firebase_admin.get_app())


app = FastAPI(title="EcoPulse Alertas", lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok", "service": "alerts", "push_enabled": bool(settings().firebase_credentials)}


@app.websocket("/ws/alerts")
async def websocket(socket: WebSocket):
    await socket.accept()
    try:
        auth = await asyncio.wait_for(socket.receive_json(), timeout=10)
        token = auth.get("token", "")
        user_id = decode_token(token)
        with database() as connection:
            if not connection.execute("SELECT 1 FROM users WHERE id=%s", (user_id,)).fetchone():
                raise HTTPException(401, "Usuário inexistente.")
        session = Session(user_id)
        sessions[socket] = session
        await socket.send_json({"type": "authenticated"})
        while True:
            message = await socket.receive_json()
            decode_token(token)
            if message.get("type") == "location.update":
                location = LocationInput.model_validate(message)
                session.location = location
                reports = nearby(location.latitude, location.longitude, location.radius_meters)
                new_ids = {report["id"] for report in reports}
                for report in reports:
                    if report["id"] not in session.seen and report["user_id"] != str(user_id):
                        await socket.send_json({"type": "proximity.alert", "report": report})
                session.seen = new_ids
                await socket.send_json({"type": "snapshot", "reports": reports})
    except WebSocketDisconnect:
        pass
    except (HTTPException, ValidationError, TimeoutError, ValueError, TypeError):
        await socket.close(code=1008)
    except Exception:
        log.exception("Erro na conexão WebSocket")
        try:
            await socket.close(code=1011)
        except RuntimeError:
            pass
    finally:
        sessions.pop(socket, None)
