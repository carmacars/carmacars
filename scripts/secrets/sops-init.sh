#!/usr/bin/env bash
# r36: moves the deploy's GitHub secrets into secrets/deploy.sops.yaml (SOPS with age), in one run on the owner's computer.
#   1. makes an age key (once; kept in ~/.config/sops/age/keys.txt, never in the repository) and writes its public key
#      into .sops.yaml;
#   2. builds secrets/deploy.sops.yaml from a plain YAML file of NAME: value lines the owner fills (it is encrypted in
#      place and the plain copy is deleted; nothing plain is left in the repository);
#   3. with the GitHub CLI signed in, sets the repository secret SOPS_AGE_KEY to the private key (else prints how).
# The deploy then reads the file (.github/actions/sops-env). The old GitHub secrets keep working until they are deleted.
#   scripts/secrets/sops-init.sh <plain.yaml>      (needs sops and age-keygen: brew install sops age)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLAIN="${1:-}"
KEYS="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
OUT="$ROOT/secrets/deploy.sops.yaml"
command -v sops >/dev/null || { echo "sops is missing (brew install sops)"; exit 2; }
command -v age-keygen >/dev/null || { echo "age-keygen is missing (brew install age)"; exit 2; }

if [ ! -f "$KEYS" ]; then
  mkdir -p "$(dirname "$KEYS")"; umask 077
  age-keygen -o "$KEYS" 2>/dev/null
  echo "A new age key is in $KEYS: keep a copy in your password manager (it opens every secret)."
fi
PUB="$(grep -m1 -o 'age1[0-9a-z]*' "$KEYS")"
if grep -q 'AGE_PUBLIC_KEY_NOT_SET' "$ROOT/.sops.yaml"; then
  sed -i.bak "s/AGE_PUBLIC_KEY_NOT_SET/$PUB/" "$ROOT/.sops.yaml" && rm -f "$ROOT/.sops.yaml.bak"
  echo ".sops.yaml now names your public key ($PUB): commit it."
fi

if [ -n "$PLAIN" ]; then
  [ -f "$PLAIN" ] || { echo "No such file: $PLAIN"; exit 2; }
  # names must be environment variable names; the values stay as typed
  if grep -Ev '^\s*(#|$)|^[A-Z][A-Z0-9_]*:|^\s' "$PLAIN" | grep -q .; then echo "Every line must be NAME: value (capitals, digits, _)"; exit 2; fi
  mkdir -p "$ROOT/secrets"
  if [ -f "$OUT" ]; then
    # merge into the existing file: decrypted in memory only
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    (cd "$ROOT" && sops --decrypt secrets/deploy.sops.yaml) > "$tmp"
    python3 - "$tmp" "$PLAIN" <<'PY'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1])) or {}
a.update(yaml.safe_load(open(sys.argv[2])) or {})
yaml.safe_dump(a, open(sys.argv[1], 'w'), default_flow_style=False, sort_keys=True)
PY
    cp "$tmp" "$OUT"
  else
    cp "$PLAIN" "$OUT"
  fi
  (cd "$ROOT" && sops --encrypt --in-place secrets/deploy.sops.yaml)
  rm -f "$PLAIN"
  echo "secrets/deploy.sops.yaml is encrypted ($(grep -c 'ENC\[' "$OUT") values) and $PLAIN is deleted: commit secrets/deploy.sops.yaml."
fi

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  grep -m1 '^AGE-SECRET-KEY-' "$KEYS" | gh secret set SOPS_AGE_KEY -R carmacars/carmacars
  echo "The repository secret SOPS_AGE_KEY is set."
else
  echo "Set the repository secret SOPS_AGE_KEY (GitHub > Settings > Secrets and variables > Actions) to the line starting AGE-SECRET-KEY- in $KEYS."
fi
