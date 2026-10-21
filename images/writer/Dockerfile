FROM python:3.12-slim
RUN pip install --no-cache-dir psycopg2-binary redis
COPY writer.py report.py /app/
CMD ["python", "-u", "/app/writer.py"]
