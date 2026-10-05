"""Initial schema, including relational material writeoffs and AI assessments.

This first migration deliberately uses checkfirst so an initialized demo database
can be adopted with `alembic upgrade head` without losing data.
"""
from alembic import op
from app.db import Base
from app import models  # noqa: F401

revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    Base.metadata.create_all(bind=op.get_bind(), checkfirst=True)


def downgrade():
    Base.metadata.drop_all(bind=op.get_bind(), checkfirst=True)
