# syntax=docker/dockerfile:1
ARG PYTHON_IMAGE=python:3.12.16-slim-bookworm

FROM ${PYTHON_IMAGE} AS builder
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt requirements-dev.txt ./
RUN pip install -r requirements.txt

# Test image: runtime dependencies + test/lint tools + tests. Never deployed.
FROM builder AS test
RUN pip install -r requirements-dev.txt
WORKDIR /app
COPY . .
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/app
CMD ["sh", "-c", "ruff check . && ruff format --check . && pytest -v"]

FROM ${PYTHON_IMAGE} AS runtime
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PATH="/opt/venv/bin:$PATH"
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY alembic.ini ./
COPY alembic ./alembic
COPY app ./app
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).status == 200 else 1)"]
# Apply migrations, then serve. Uvicorn access logs are off: the app logs requests itself.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn --factory app.main:create_app --host 0.0.0.0 --port 8000 --no-access-log"]
