"""Application settings, read from environment variables.

Database credentials have no defaults: the service refuses to start without them.
"""

from functools import lru_cache

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import URL


class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", case_sensitive=False)

    log_level: str = "INFO"

    db_host: str
    db_port: int = 5432
    db_name: str
    db_user: str
    db_password: SecretStr

    db_pool_size: int = Field(default=5, ge=1, le=50)
    db_max_overflow: int = Field(default=5, ge=0, le=50)
    db_pool_timeout_s: int = Field(default=5, ge=1)
    db_connect_timeout_s: int = Field(default=5, ge=1)
    db_statement_timeout_ms: int = Field(default=5000, ge=100)

    max_page_size: int = Field(default=100, ge=1, le=1000)

    @property
    def database_url(self) -> URL:
        # URL.create keeps the password out of any string rendering of the URL.
        return URL.create(
            "postgresql+psycopg",
            username=self.db_user,
            password=self.db_password.get_secret_value(),
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]  # required fields come from the environment
