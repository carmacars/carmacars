# The background remover of the site's cutouts (r48 O, 3080), built here from a pinned rembg on PyPI instead of a third-party
# image: python slim, rembg 2.0.87 with the CPU runtime, and a small server (server.py) with the one call the site makes,
# POST /api/remove (multipart: file, model) -> PNG with transparency. The model's weights are downloaded while the image is built
# (so the first request is not waiting for a download) and stay in the image; /root/.u2net is a volume only as a cache for other models.
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 U2NET_HOME=/root/.u2net
RUN pip install "rembg[cpu]==2.0.87" "fastapi>=0.128,<1" "uvicorn==0.40.0" "python-multipart>=0.0.31,<0.1"
# the model the site asks for (web/src/server/site-cutouts.ts: isnet-general-use, about 180 MB)
RUN python -c "from rembg import new_session; new_session('isnet-general-use')"
WORKDIR /app
COPY server.py /app/server.py
EXPOSE 7000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:7000/healthz', timeout=4)"
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "7000", "--workers", "1"]
