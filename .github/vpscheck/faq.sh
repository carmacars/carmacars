#!/usr/bin/env bash
source .github/vpscheck/common.sh
for i in 1 2 3; do say "/faq: $(curl -sS -o "$RUNNER_TEMP/f.html" -D "$RUNNER_TEMP/h" -w '%{http_code} %{time_total}s' --max-time 30 "$SITE/faq") $(grep -i '^retry-after\|^cf-cache' "$RUNNER_TEMP/h" | tr -d '\r' | paste -sd' ') $(grep -o '<title>[^<]*' "$RUNNER_TEMP/f.html" | head -1)"; sleep 3; done
flush faq
