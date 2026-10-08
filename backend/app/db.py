import os
from pathlib import Path

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, sessionmaker


class Base(DeclarativeBase):
    pass


def make_engine(url: str | None = None):
    default_file = Path(__file__).resolve().parents[1] / "data" / "km.db"
    default_file.parent.mkdir(parents=True, exist_ok=True)
    url = url or os.getenv("DATABASE_URL", f"sqlite:///{default_file}")
    if url.startswith("postgresql://"):
        url = url.replace("postgresql://", "postgresql+psycopg://", 1)
    engine = create_engine(url, connect_args={"check_same_thread": False} if url.startswith("sqlite") else {}, pool_pre_ping=True)
    if url.startswith("sqlite"):
        @event.listens_for(engine, "connect")
        def foreign_keys(connection, _):
            connection.execute("PRAGMA foreign_keys=ON")
            # SQLite's built-in lower/LIKE does not fold Cyrillic. Explicitly
            # used only by the new paged search, preserving legacy API search.
            connection.create_function("naryad_lower", 1,
                lambda value: value.lower() if isinstance(value, str) else value,
                deterministic=True)
    return engine


def session_factory(engine):
    return sessionmaker(bind=engine, expire_on_commit=False)
