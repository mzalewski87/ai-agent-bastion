FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=5050 \
    HOST=0.0.0.0 \
    DOCUMENTS_DIR=/app/documents \
    SEED_DOCUMENTS_DIR=/app/seed-documents

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Official Prisma AIRS SDK (pan-aisecurity) + Google Auth + Flask + Gunicorn + Requests
RUN pip install --no-cache-dir \
    flask==3.0.3 \
    gunicorn==22.0.0 \
    requests==2.32.3 \
    google-auth==2.29.0 \
    pan-aisecurity

COPY static/ ./static/
COPY templates/ ./templates/
COPY seed-documents/ ./seed-documents/
COPY mcp_servers.py security_engine.py app.py ./

RUN mkdir -p /app/documents /app/seed-documents \
    && cp -r /app/seed-documents/. /app/documents/ 2>/dev/null || true

RUN useradd --create-home --uid 10001 appuser && chown -R appuser:appuser /app
USER 10001

EXPOSE 5050

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5050/health')" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:5050", "--workers", "1", "--threads", "8", "--timeout", "180", "--graceful-timeout", "180", "app:app"]
