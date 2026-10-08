FROM python:3.12-slim

WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends fonts-dejavu-core && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ ./app/
COPY eval/__init__.py eval/fetch_equipment_model.py ./eval/
ARG FETCH_EQUIPMENT_MODEL=true
RUN if [ "$FETCH_EQUIPMENT_MODEL" = "true" ]; then python -m eval.fetch_equipment_model; fi
RUN useradd --create-home aiuser && mkdir -p /app/state /app/data && chown -R aiuser:aiuser /app
USER aiuser
EXPOSE 8090
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8090"]
