"""The site's background remover: POST /api/remove (multipart: file, model) answers a PNG with the background removed.

The same call rembg's own server takes, so web/src/server/site-cutouts.ts needs nothing else. One model session per model name
is kept; one request is worked at a time (a car photo takes seconds on the CPU, and the site asks for a couple per run).
"""
import io
import threading

from fastapi import FastAPI, File, Form, HTTPException
from fastapi.responses import Response
from rembg import new_session, remove

ALLOWED = {"isnet-general-use", "u2net", "u2netp", "isnet-anime", "silueta"}
app = FastAPI(title="carmacars-rembg")
_sessions: dict = {}
_lock = threading.Lock()


def session(name: str):
    if name not in _sessions:
        _sessions[name] = new_session(name)
    return _sessions[name]


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/api/remove")
def api_remove(file: bytes = File(...), model: str = Form("isnet-general-use")):
    if model not in ALLOWED:
        raise HTTPException(status_code=400, detail="unknown model")
    if not file:
        raise HTTPException(status_code=400, detail="no file")
    try:
        with _lock:
            out = remove(file, session=session(model))
    except Exception as e:  # an unreadable image, a model that cannot load
        raise HTTPException(status_code=422, detail=str(e)[:200])
    buf = out if isinstance(out, (bytes, bytearray)) else _png(out)
    return Response(content=bytes(buf), media_type="image/png")


def _png(img) -> bytes:
    b = io.BytesIO()
    img.save(b, format="PNG")
    return b.getvalue()
