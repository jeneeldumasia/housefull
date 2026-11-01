FROM python:3.12-slim AS base
ENV PYTHONUNBUFFERED=1
WORKDIR /srv
RUN useradd --system --no-create-home housefull
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY housefull ./housefull
COPY migrations ./migrations
COPY scripts ./scripts

FROM base AS test
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY tests ./tests
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider"]

FROM base AS app
USER housefull
ENV PORT=8080
CMD ["sh", "-c", "exec uvicorn ${APP_MODULE:-housefull.api:app} --host 0.0.0.0 --port $PORT"]
