# 3.12 matches the interpreter this is developed against.
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY inspect_data.py ./inspect_data.py

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app
# Everything -- records, attachments, index -- lives under DATA_DIR as files,
# so this can be bound straight to a NAS share.
ENV DATA_DIR=/data
# Read only, to import an older SQLite install on first start.
ENV DATABASE_URL=sqlite:////data/trudido.db

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://localhost:8000/api/v1/health || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
