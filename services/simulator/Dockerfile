FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
# CLI tool, not a server — docker-compose's `command:` picks --mode live vs backfill
# and the bus/speed args. `--mode live` runs each simulated bus through exactly one
# trip and then exits; restart: unless-stopped (set on the compose service, not
# here) is what keeps new trips starting instead of the live feed going stale.
ENTRYPOINT ["python", "-m", "app.main"]
CMD ["--mode", "live", "--buses", "6", "--speed-multiplier", "1.0"]
