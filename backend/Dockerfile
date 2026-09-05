FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg gcc g++ git libsndfile1 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir cython numpy && \
    pip install --no-cache-dir -r requirements.txt

COPY requirements-ismir.txt .
COPY scripts/setup_ismir.sh ./scripts/setup_ismir.sh
# Only model-loading code invalidates the expensive model installation layer.
COPY chordlyze_backend/analysis/ismir_worker.py chordlyze_backend/analysis/provenance.py ./chordlyze_backend/analysis/

ENV CHORDLYZE_ISMIR_DIR=/opt/chordlyze/ismir2019 \
    CHORDLYZE_TORCH_THREADS=2
RUN PYTHON=python3.11 bash scripts/setup_ismir.sh "$CHORDLYZE_ISMIR_DIR"

COPY chordlyze_backend ./chordlyze_backend
COPY song_worker.py ./song_worker.py
COPY scripts/reset_song_library.py ./scripts/reset_song_library.py

ARG APP_REVISION=unknown
ENV CHORDLYZE_RELEASE=$APP_REVISION

ENV CHORDLYZE_CACHE=/data/analysis_cache
EXPOSE 8080
CMD ["uvicorn", "chordlyze_backend.main:app", "--host", "0.0.0.0", "--port", "8080"]
