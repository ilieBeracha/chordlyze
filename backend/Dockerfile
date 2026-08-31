FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg gcc g++ git libsndfile1 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir cython numpy && \
    pip install --no-cache-dir -r requirements.txt

COPY chordlyze_backend ./chordlyze_backend

ENV CHORDLYZE_CACHE=/data/analysis_cache
EXPOSE 8080
CMD ["uvicorn", "chordlyze_backend.main:app", "--host", "0.0.0.0", "--port", "8080"]
