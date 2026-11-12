from datetime import datetime, timedelta, timezone
from uuid import uuid4
import jwt
import pytest
from fastapi import HTTPException
from pydantic import ValidationError
from app.auth import create_token, decode_token, password_hash
from app.config import settings
from app.contracts import ReportInput, RegisterInput
from app.geo import distance_meters, region_for, shard_for
from app.worker import expires_at
from app.alerts import is_near
from app.contracts import LocationInput, DeviceInput


def test_device_preserves_actual_gps_time():
    old = datetime.now(timezone.utc) - timedelta(hours=1)
    device = DeviceInput(device_id=uuid4(), latitude=0, longitude=0, located_at=old)
    assert device.located_at == old


@pytest.mark.parametrize("stamp", [datetime(2026, 1, 1), datetime.now(timezone.utc) + timedelta(hours=1)])
def test_device_rejects_invalid_location_time(stamp):
    with pytest.raises(ValidationError):
        DeviceInput(device_id=uuid4(), latitude=0, longitude=0, located_at=stamp)


def payload(**changes):
    return {"id": str(uuid4()), "type": "FLOOD", "description": "Rua alagada",
            "latitude": -23.5505, "longitude": -46.6333, "accuracy_meters": 10,
            "observed_at": datetime.now(timezone.utc).isoformat(), **changes}


@pytest.mark.parametrize("changes", [{"latitude": 91}, {"longitude": -181}, {"latitude": float('nan')},
    {"type": "UNKNOWN"}, {"accuracy_meters": -1}, {"description": "x" * 501},
    {"observed_at": "2026-01-01T12:00:00"},
    {"observed_at": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()}])
def test_reject_invalid_report(changes):
    with pytest.raises(ValidationError):
        ReportInput.model_validate(payload(**changes))


@pytest.mark.parametrize("kind,hours", [("FLOOD",6),("BLOCKED_ROAD",4),("SMOKE",3),("AIR_QUALITY",3),("HEAT",3)])
def test_validity_starts_at_observation(kind, hours):
    observed = datetime.now(timezone.utc) - timedelta(days=1)
    report = ReportInput.model_validate(payload(type=kind,observed_at=observed))
    assert expires_at(report) == observed + timedelta(hours=hours)
    assert expires_at(report) < datetime.now(timezone.utc)


def test_authentication():
    user_id = uuid4()
    assert decode_token(create_token(user_id)) == user_id
    hashed = password_hash.hash("senha-com-oito-caracteres")
    assert hashed != "senha-com-oito-caracteres"
    assert password_hash.verify("senha-com-oito-caracteres", hashed)
    assert not password_hash.verify("errada", hashed)
    expired = jwt.encode({"sub": str(user_id), "exp": datetime.now(timezone.utc)-timedelta(seconds=1)}, settings().jwt_secret, algorithm="HS256")
    for token in (expired, "invalid"):
        with pytest.raises(HTTPException) as error:
            decode_token(token)
        assert error.value.status_code == 401


def test_email_normalization():
    assert RegisterInput(name="Maria", email="MARIA@example.com",password="12345678").email == "maria@example.com"


def test_geographical_distance_and_alert_radius():
    assert distance_meters(0,0,0,0) == 0
    assert 111000 < distance_meters(0,0,0,1) < 112000
    location = LocationInput(latitude=0,longitude=0,radius_meters=3000)
    assert is_near(location, {"latitude":0,"longitude":0.01})
    assert not is_near(location, {"latitude":0,"longitude":0.1})
    assert not is_near(None, {"latitude":0,"longitude":0})


def test_partition_is_stable_and_uses_both_workers():
    region = region_for(-23.5505,-46.6333)
    assert len(region) == 5
    assert shard_for(region) == shard_for(region)
    assert {shard_for(region_for(lat,0)) for lat in range(-80,81,5)} == {0,1}
