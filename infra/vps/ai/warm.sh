#!/usr/bin/env bash
# r48 part AI: run on the server in the background by a deploy (scripts/deploy/web-vps-remote.sh ai), never waited for:
# the Ollama models pulled and checked against their pinned digests (infra/vps/ai/models.env), the whisper image built and
# started (its container downloads and checks its model). A model whose digest differs is removed: the site never uses
# it. Low priority (nice 19, idle I/O) so the site and the database are not slowed. The state is written to
# /opt/carmacars/ai/state (text=, vision=, speech=: ready, warming or failed with the reason), which the next deploy prints.
set -uo pipefail
A=/opt/carmacars/ai
# shellcheck source=models.env
. "$A/models.env"
state() { # key value
  touch "$A/state"; grep -v "^$1=" "$A/state" > "$A/state.tmp" 2>/dev/null || true; echo "$1=$2" >> "$A/state.tmp"; mv "$A/state.tmp" "$A/state"
}
dca() { docker compose --project-directory "$A" --env-file "$A/models.env" -f "$A/docker-compose.yml" "$@"; }
log() { echo "[ai-warm $(date -u +%H:%M:%S)] $*"; }

pull() { # key model digest
  local key="$1" model="$2" digest="$3" id i
  for i in 1 2 3; do
    id=$(docker exec carmacars-llm ollama list 2>/dev/null | awk -v m="$model" '$1 == m {print $2}')
    if [ -n "$id" ] && [ "${id:0:12}" = "${digest:0:12}" ]; then state "$key" ready; log "$model ready ($id)"; return 0; fi
    if [ -n "$id" ]; then
      log "$model has digest $id, not the pinned $digest: removed"; docker exec carmacars-llm ollama rm "$model" > /dev/null 2>&1 || true
      state "$key" "failed: digest $id is not the pinned $digest"; return 1
    fi
    state "$key" warming
    log "pulling $model (try $i)"
    docker exec carmacars-llm ollama pull "$model" > /dev/null 2>&1 || sleep 30
  done
  state "$key" "failed: $model could not be downloaded"; return 1
}

dca up -d llm > /dev/null 2>&1 || { state text "failed: carmacars-llm did not start"; state vision "failed: carmacars-llm did not start"; }
for i in $(seq 1 30); do docker exec carmacars-llm ollama list > /dev/null 2>&1 && break; sleep 2; done
pull text "$LOCAL_LLM_MODEL" "$LOCAL_LLM_DIGEST"
pull vision "$LOCAL_VISION_MODEL" "$LOCAL_VISION_DIGEST"

# models no longer pinned (an earlier release's) are removed: disk is kept for what is used
docker exec carmacars-llm ollama list 2>/dev/null | awk 'NR > 1 {print $1}' | while read -r m; do
  [ "$m" = "$LOCAL_LLM_MODEL" ] || [ "$m" = "$LOCAL_VISION_MODEL" ] || { log "removing $m (not pinned)"; docker exec carmacars-llm ollama rm "$m" > /dev/null 2>&1 || true; }
done

if ! docker image inspect "carmacars-stt:$WHISPER_VERSION" > /dev/null 2>&1; then
  state speech warming
  log "building whisper.cpp $WHISPER_VERSION"
  nice -n 19 dca build stt > "$A/stt-build.log" 2>&1 || { state speech "failed: the whisper image did not build (see $A/stt-build.log)"; exit 0; }
fi
dca up -d stt > /dev/null 2>&1 || { state speech "failed: carmacars-stt did not start"; exit 0; }
for i in $(seq 1 90); do
  st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' carmacars-stt 2>/dev/null || true)
  if [ "$st" = healthy ]; then state speech ready; log "speech ready"; exit 0; fi
  sleep 10
done
state speech "warming: the speech model is still downloading (docker logs carmacars-stt)"
