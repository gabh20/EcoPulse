from datetime import datetime, timezone
from enum import StrEnum
from uuid import UUID
from pydantic import BaseModel, Field, field_validator


class ReportType(StrEnum):
    FLOOD = "FLOOD"
    BLOCKED_ROAD = "BLOCKED_ROAD"
    SMOKE = "SMOKE"
    AIR_QUALITY = "AIR_QUALITY"
    HEAT = "HEAT"


class Coordinates(BaseModel):
    latitude: float = Field(ge=-90, le=90, allow_inf_nan=False)
    longitude: float = Field(ge=-180, le=180, allow_inf_nan=False)


class ReportInput(Coordinates):
    id: UUID
    type: ReportType
    description: str = Field(default="", max_length=500)
    accuracy_meters: float = Field(ge=0, le=100000, allow_inf_nan=False)
    observed_at: datetime

    @field_validator("observed_at")
    @classmethod
    def timestamp_has_timezone(cls, value):
        if value.tzinfo is None:
            raise ValueError("O horário precisa incluir o fuso.")
        if (value - datetime.now(timezone.utc)).total_seconds() > 300:
            raise ValueError("O relato não pode estar no futuro.")
        return value


class RegisterInput(BaseModel):
    name: str = Field(min_length=2, max_length=80)
    email: str = Field(min_length=5, max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
    password: str = Field(min_length=8, max_length=128)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value):
        return value.strip().lower()


class LoginInput(BaseModel):
    email: str
    password: str = Field(max_length=128)


class DeviceInput(Coordinates):
    device_id: UUID
    fcm_token: str | None = Field(default=None, max_length=4096)
    located_at: datetime

    @field_validator("located_at")
    @classmethod
    def valid_location_time(cls, value):
        if value.tzinfo is None or (value - datetime.now(timezone.utc)).total_seconds() > 300:
            raise ValueError("A posição precisa de horário com fuso, sem estar no futuro.")
        return value


class LocationInput(Coordinates):
    radius_meters: int = Field(default=3000, ge=100, le=10000)


class ReportEvent(BaseModel):
    user_id: UUID
    report: ReportInput
