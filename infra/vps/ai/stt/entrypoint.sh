#!/bin/sh
# r48 part AI: the whisper model downloaded once (into the stt-models volume) and checked against its published SHA-1
# before it is used; then the server. A model that does not match is never used: the container waits and says so
# (no restart loop that downloads it again), and the site shows speech to text as warming up.
set -eu
M="/models/ggml-${WHISPER_MODEL:-small.en}.bin"
want="${WHISPER_MODEL_SHA1:?WHISPER_MODEL_SHA1}"
ok() { [ -s "$M" ] && [ "$(sha1sum "$M" | cut -d' ' -f1)" = "$want" ]; }
if ! ok; then
  echo "[stt] downloading ggml-${WHISPER_MODEL:-small.en}.bin"
  curl -fsSL --retry 3 -o "$M.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${WHISPER_MODEL:-small.en}.bin" || { echo "[stt] download failed"; rm -f "$M.part"; sleep 600; exit 1; }
  if [ "$(sha1sum "$M.part" | cut -d' ' -f1)" != "$want" ]; then
    echo "[stt] the model's SHA-1 does not match the pin $want: not used"; rm -f "$M.part"; exec sleep infinity
  fi
  mv "$M.part" "$M"
fi
echo "[stt] model checked ($want): starting"
exec whisper-server --host 0.0.0.0 --port 8080 -m "$M" -t "${WHISPER_THREADS:-2}" -l en --convert
