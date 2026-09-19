FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home updater && mkdir /data && chown updater:updater /data
COPY app.py manage.py ./
USER updater
ENV UPDATE_DATA=/data PYTHONDONTWRITEBYTECODE=1
EXPOSE 8787
CMD ["gunicorn", "--no-control-socket", "--bind", "0.0.0.0:8787", "--workers", "2", "--threads", "4", "--timeout", "120", "app:create_app()"]
