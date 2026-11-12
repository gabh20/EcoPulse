from uuid import UUID, uuid4
from datetime import datetime, timezone
import psycopg
from psycopg.types.json import Jsonb
from fastapi import Depends, FastAPI, HTTPException, Query, Response
from .auth import create_token, current_user, password_hash
from .contracts import DeviceInput, LoginInput, RegisterInput, ReportInput
from .db import database, json_row, REPORT_COLUMNS
from .geo import region_for, shard_for
from . import broker, cache
from .environment import conditions
from .temperature import temperature_grid
from .reports import nearby

app = FastAPI(title="EcoPulse", version="1.0.0", description="Relatos ambientais colaborativos. Sem cálculo de rotas.")


@app.get("/health")
def health():
    return {"status": "ok", "service": "api"}


@app.post("/auth/register", status_code=201)
def register(data: RegisterInput):
    user_id = uuid4()
    hashed = password_hash.hash(data.password)
    try:
        with database() as connection:
            connection.execute("INSERT INTO users(id,name,email,password_hash) VALUES (%s,%s,%s,%s)",
                               (user_id, data.name.strip(), data.email, hashed))
    except psycopg.errors.UniqueViolation as error:
        raise HTTPException(409, "Este e-mail já está cadastrado.") from error
    return {"id": str(user_id), "name": data.name.strip()}


@app.post("/auth/login")
def login(data: LoginInput):
    with database() as connection:
        user = connection.execute("SELECT * FROM users WHERE email=%s", (data.email.strip().lower(),)).fetchone()
    if user is None:
        password_hash.hash(data.password)
        raise HTTPException(401, "E-mail ou senha incorretos.")
    if not password_hash.verify(data.password, user["password_hash"]):
        raise HTTPException(401, "E-mail ou senha incorretos.")
    return {"access_token": create_token(user["id"]), "token_type": "bearer", "user_id": str(user["id"])}


@app.post("/reports", status_code=202)
async def submit(data: ReportInput, response: Response, user_id=Depends(current_user)):
    payload = data.model_dump(mode="json")
    with database() as connection:
        connection.execute("INSERT INTO submissions(id,user_id,payload) VALUES (%s,%s,%s) ON CONFLICT DO NOTHING",
                           (data.id, user_id, Jsonb(payload)))
        submission = connection.execute("SELECT * FROM submissions WHERE id=%s", (data.id,)).fetchone()
        if submission["user_id"] != user_id or submission["payload"] != payload:
            raise HTTPException(409, "Identificador já utilizado com outro conteúdo.")
        if submission["state"] in ("PROCESSED", "EXPIRED", "RESOLVED"):
            response.status_code = 200
            return {"id": str(data.id), "state": submission["state"]}
    try:
        queue = f"reports.{shard_for(region_for(data.latitude, data.longitude))}"
        await broker.publish(queue, {"user_id": str(user_id), "report": payload})
    except Exception as error:
        raise HTTPException(503, "Fila indisponível. Mantenha o relato pendente e tente novamente.") from error
    with database() as connection:
        connection.execute("UPDATE submissions SET state='QUEUED' WHERE id=%s AND state IN ('PENDING','FAILED')", (data.id,))
    return {"id": str(data.id), "state": "QUEUED"}


@app.post("/reports/{report_id}/resolve")
def resolve_report(report_id: UUID, user_id=Depends(current_user)):
    with database() as connection:
        report = connection.execute(
            f"SELECT {REPORT_COLUMNS} FROM reports WHERE id=%s FOR UPDATE", (report_id,)
        ).fetchone()
        if report is None:
            raise HTTPException(404, "Ocorrência ainda não processada ou inexistente.")
        if report["user_id"] != user_id:
            raise HTTPException(403, "Somente quem criou o relato pode marcar como resolvido.")
        if report["status"] == "RESOLVED":
            result = json_row(report)
        else:
            if report["status"] != "ACTIVE" or report["expires_at"] <= datetime.now(timezone.utc):
                raise HTTPException(409, "Esta ocorrência já expirou.")
            row = connection.execute(
                f"UPDATE reports SET status='RESOLVED' WHERE id=%s RETURNING {REPORT_COLUMNS}",
                (report_id,),
            ).fetchone()
            connection.execute("UPDATE submissions SET state='RESOLVED' WHERE id=%s", (report_id,))
            result = json_row(row)
            event_id = uuid4()
            connection.execute("INSERT INTO outbox(id,body) VALUES (%s,%s)", (event_id, Jsonb({
                "event_id": str(event_id), "type": "report.removed", "report": result})))
    cache.invalidate_reports()
    return {"id": str(report_id), "state": "RESOLVED", "report": result}


@app.get("/reports/nearby")
def get_nearby(lat: float = Query(ge=-90, le=90), lng: float = Query(ge=-180, le=180),
               radius_meters: int = Query(default=3000, ge=100, le=10000), user_id=Depends(current_user)):
    return nearby(lat, lng, radius_meters)


@app.get("/reports/{report_id}")
def get_report(report_id: UUID, user_id=Depends(current_user)):
    with database() as connection:
        submission = connection.execute("SELECT state FROM submissions WHERE id=%s AND user_id=%s", (report_id, user_id)).fetchone()
        if submission is None:
            raise HTTPException(404, "Relato não encontrado.")
        report = connection.execute(f"SELECT {REPORT_COLUMNS} FROM reports WHERE id=%s", (report_id,)).fetchone()
    return {"id": str(report_id), "state": submission["state"], "report": json_row(report) if report else None}


@app.put("/devices")
def register_device(data: DeviceInput, user_id=Depends(current_user)):
    with database() as connection:
        connection.execute("""INSERT INTO devices(id,user_id,fcm_token,latitude,longitude,location,updated_at)
            VALUES (%s,%s,%s,%s,%s,ST_SetSRID(ST_MakePoint(%s,%s),4326)::geography,%s)
            ON CONFLICT(id) DO UPDATE SET user_id=EXCLUDED.user_id, fcm_token=EXCLUDED.fcm_token,
            latitude=EXCLUDED.latitude, longitude=EXCLUDED.longitude, location=EXCLUDED.location,updated_at=EXCLUDED.updated_at
            """, (data.device_id,user_id,data.fcm_token,data.latitude,data.longitude,data.longitude,data.latitude,data.located_at))
    return {"status": "registered"}


@app.delete("/devices/{device_id}", status_code=204)
def unregister_device(device_id: UUID, user_id=Depends(current_user)):
    with database() as connection:
        connection.execute("DELETE FROM push_deliveries WHERE device_id IN (SELECT id FROM devices WHERE id=%s AND user_id=%s)", (device_id,user_id))
        connection.execute("DELETE FROM devices WHERE id=%s AND user_id=%s", (device_id,user_id))
    return Response(status_code=204)


@app.get("/environment")
async def get_environment(lat: float = Query(ge=-90, le=90), lng: float = Query(ge=-180, le=180), user_id=Depends(current_user)):
    return await conditions(lat, lng)


@app.get("/environment/temperature-map")
async def get_temperature_map(lat: float = Query(ge=-90, le=90), lng: float = Query(ge=-180, le=180), user_id=Depends(current_user)):
    return await temperature_grid(lat, lng)
