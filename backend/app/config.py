from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SADO_", env_file=".env", extra="ignore")

    environment: Literal["development", "production", "test"] = "development"
    database_url: str = "postgresql+asyncpg://sado:sado@localhost:5432/sado"
    redis_url: str = "redis://localhost:6379/0"

    jwt_secret: str = Field(default="change-me-in-production-please-32-bytes-min", min_length=32)
    access_token_ttl_seconds: int = 60 * 30
    refresh_token_ttl_seconds: int = 60 * 60 * 24 * 90

    otp_ttl_seconds: int = 300
    otp_max_attempts: int = 5
    otp_resend_cooldown_seconds: int = 60
    # In development a fixed code is accepted for every number so the app can be tried without SMS.
    dev_otp_code: str = "12345"

    sms_provider: Literal["console", "eskiz"] = "console"
    eskiz_email: str = ""
    eskiz_password: str = ""
    eskiz_sender: str = "4546"

    media_root: Path = Path("./media")
    max_upload_bytes: int = 2 * 1024 * 1024 * 1024
    public_base_url: str = "http://localhost:8000"

    message_edit_window_seconds: int = 60 * 60 * 48
    max_group_members: int = 200_000

    anthropic_api_key: str = ""
    ai_model: str = "claude-opus-5-5"
    ai_bot_username: str = "sado_ai"

    turn_urls: list[str] = Field(default_factory=list)
    turn_username: str = ""
    turn_credential: str = ""

    cors_origins: list[str] = Field(default_factory=lambda: ["*"])

    @property
    def ai_enabled(self) -> bool:
        return bool(self.anthropic_api_key)


@lru_cache
def get_settings() -> Settings:
    return Settings()
