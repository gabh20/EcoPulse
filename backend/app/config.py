from functools import lru_cache
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    database_url: str = "postgresql://ecopulse:ecopulse@localhost:5432/ecopulse"
    rabbitmq_urls: str = "amqp://ecopulse:ecopulse@localhost:5672/"
    rabbitmq_quorum: bool = False
    redis_url: str = "redis://localhost:6379/0"
    redis_cluster: bool = False
    jwt_secret: str = Field(min_length=32)
    jwt_hours: int = 24
    worker_shard: int = Field(default=0, ge=0, le=1)
    firebase_credentials: str = ""


@lru_cache
def settings():
    return Settings()
