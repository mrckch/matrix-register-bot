# syntax=docker/dockerfile:1.7

# ---- Stage 1: Frontend bauen (Vite) ----------------------------------------
FROM node:22-alpine AS frontend-builder

WORKDIR /app
COPY frontend/package.json frontend/package-lock.json* ./
# package-lock.json existiert ggf. noch nicht — install statt ci, dann ist es egal.
RUN npm install --no-audit --no-fund

COPY frontend/ ./
RUN npm run build


# ---- Stage 2: Python-Runtime mit FastAPI -----------------------------------
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080 \
    STATIC_DIR=/app/static

WORKDIR /app

# Curl fuer den HEALTHCHECK
RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ ./
COPY --from=frontend-builder /app/dist /app/static

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null || exit 1

# uvicorn als Prozessmanager — eine einzelne UI-App braucht keine Workers.
CMD ["sh", "-c", "uvicorn server:app --host 0.0.0.0 --port ${PORT}"]
