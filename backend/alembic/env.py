from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from sitesense.core.config import get_settings
from sitesense.db.base import Base
import sitesense.db.models  # noqa: F401 - imports mapped models for Alembic

config = context.config
database_url = get_settings().database_url
# Alembic executes synchronously. The application remains fully async, but a
# migration process must use the matching synchronous dialect.
database_url = database_url.replace("postgresql+asyncpg://", "postgresql+psycopg://")
database_url = database_url.replace("sqlite+aiosqlite://", "sqlite://")
config.set_main_option("sqlalchemy.url", database_url)
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
