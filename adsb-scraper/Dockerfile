FROM python:3.11-slim

WORKDIR /app

# Install dependencies
RUN pip install --no-cache-dir \
    kafka-python \
    requests

# Copy scraper script
COPY scraper.py /app/

# Run scraper
CMD ["python", "-u", "scraper.py"]
