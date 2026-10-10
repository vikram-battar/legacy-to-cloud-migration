# Multi-stage build: compile/install in the builder, ship only the runtime.
# Final image runs as a non-root user and contains no build tools.
FROM python:3.12-slim AS builder

WORKDIR /build
COPY app/requirements.txt .
# psycopg is optional at runtime; install it here so the image works
# against RDS out of the box
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt \
    && pip install --no-cache-dir --prefix=/install "psycopg[binary]>=3.1" gunicorn

FROM python:3.12-slim

# non-root from the start
RUN useradd --create-home --uid 10001 appuser
WORKDIR /home/appuser/app

COPY --from=builder /install /usr/local
COPY app/app.py .

ENV PORT=5000 \
    LOG_LEVEL=INFO \
    PYTHONUNBUFFERED=1

USER appuser
EXPOSE 5000

# /healthz is the ALB target-group check
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:5000/healthz').status==200 else 1)"

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--access-logfile", "-", "app:app"]
