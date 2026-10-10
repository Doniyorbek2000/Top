FROM python:3.13-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /srv
RUN useradd --system --uid 10001 sado
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY alembic.ini .
COPY alembic ./alembic
COPY app ./app
USER sado
EXPOSE 8080
# Trusted proxy list for --proxy-headers: uvicorn reads FORWARDED_ALLOW_IPS (default 127.0.0.1).
# Migrations run as a separate release step: `python -m alembic upgrade head`.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--no-server-header"]
