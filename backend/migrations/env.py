from logging.config import fileConfig
import os
from alembic import context
from sqlalchemy import engine_from_config, pool
from app.migrations import migrate_connection

config = context.config
if config.config_file_name and config.attributes.get("configure_logging", True):
    fileConfig(config.config_file_name)
database_url = os.getenv("DATABASE_URL", config.get_main_option("sqlalchemy.url"))
if database_url.startswith("postgresql://"):
    database_url = database_url.replace("postgresql://", "postgresql+psycopg://", 1)
config.set_main_option("sqlalchemy.url", database_url.replace("%", "%%"))

if context.is_offline_mode():
    raise RuntimeError("Schema validation requires a live migration connection; offline SQL generation is unsupported")
else:
    external = config.attributes.get("connection")
    if external is not None:
        migrate_connection(external, config)
    else:
        connectable = engine_from_config(config.get_section(config.config_ini_section), prefix="sqlalchemy.", poolclass=pool.NullPool)
        try:
            with connectable.connect() as connection:
                migrate_connection(connection, config)
        finally:
            connectable.dispose()
