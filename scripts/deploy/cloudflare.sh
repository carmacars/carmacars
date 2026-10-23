#!/usr/bin/env bash
# Cloudflare side of the deploy (ci workflow, deploy job). Idempotent.
#
#   scripts/deploy/cloudflare.sh token       check the API token and report what it may do
#   scripts/deploy/cloudflare.sh resources   page cache and file storage by what the account offers (R2, KV, D1),
#                                            the resources they need, and web/wrangler.jsonc and
#                                            web/open-next.config.ts rewritten to match (CI workspace only)
#   scripts/deploy/cloudflare.sh subdomain   the account's workers.dev subdomain (Wrangler needs one before a first upload)
#   scripts/deploy/cloudflare.sh turnstile   the Turnstile widget for the site; exports the keys, or turns
#                                            Turnstile off (TURNSTILE_PROVIDER=off) when the token cannot
#   scripts/deploy/cloudflare.sh dns         frees carmacars.ca and www for the Worker's custom domains: only
#                                            A, AAAA or CNAME records on those two names are removed (never
#                                            MX, TXT or anything else, never another name)
#   scripts/deploy/cloudflare.sh images      image transformations on the zone (listing photos), on when the token may
#   scripts/deploy/cloudflare.sh photos      the stand-in photos into the R2 public bucket (once; a marker object
#                                            records it); with Supabase Storage: supabase.sh photos
#   scripts/deploy/cloudflare.sh email       Turo by email (0063): checks Email Routing on in.carmacars.ca and points the
#                                            rule for trips@in.carmacars.ca at the Worker when the token may. It never
#                                            enables Email Routing and never touches the root domain's mail (Google
#                                            Workspace MX): the subdomain is turned on once in the dashboard
#                                            (docs/changes/2026-10-19-turo-email-quiet-alerts.md, owner steps)
#
# Needs CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID; DEPLOY_ENV (production | staging), DOMAIN (carmacars.ca).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
ACC="${CLOUDFLARE_ACCOUNT_ID:?}"
DEPLOY_ENV="${DEPLOY_ENV:-production}"
DOMAIN="${DOMAIN:-carmacars.ca}"
P=$([ "$DEPLOY_ENV" = staging ] && echo carmacars-staging || echo carmacars-prod)
BUCKETS=(opennext-cache vehicle-public vehicle-originals documents identity condition-photos agreements)

probe() { # label method path -> prints yes, or NO and the reason
  local out
  if out=$(cfapi GET "$2" 2>&1 >/dev/null); then echo "yes"; else echo "NO ($(grep -o '"message":"[^"]*"' <<<"$out" | head -1 | cut -d'"' -f4))"; fi
}

token() {
  local v
  v=$(cfapi GET "/accounts/$ACC/tokens/verify" 2>/dev/null || cfapi GET "/user/tokens/verify") || die "The Cloudflare API token does not verify"
  log "token: $(jq -c '.result | {status, expires_on}' <<<"$v")"
  CF_R2=$(probe r2 "/accounts/$ACC/r2/buckets")
  CF_KV=$(probe kv "/accounts/$ACC/storage/kv/namespaces?per_page=5")
  CF_D1=$(probe d1 "/accounts/$ACC/d1/database")
  notice "Cloudflare account and token: workers $(probe w "/accounts/$ACC/workers/scripts") | R2 $CF_R2 | KV $CF_KV | D1 $CF_D1 | Turnstile $(probe t "/accounts/$ACC/challenges/widgets") | zone $(probe z "/zones?name=$DOMAIN")"
  export CF_R2 CF_KV CF_D1
}

# What the account offers decides the page cache and the file storage:
#   R2 on:          R2 page cache (+ D1 tags when allowed), files on the Worker's R2 bindings
#   R2 off, KV on:  KV page cache and tags, files on Supabase Storage
#   neither:        pages served as built from the static assets, files on Supabase Storage
resources() {
  [ -n "${CF_R2:-}" ] || token
  local cache tag storage kv_id="" d1_id=""
  # R2 became available on the account on Oct 23. Files move to R2 only once they have been copied there
  # (FILES_ON_R2=yes, set after the copy), and the page cache stays on KV unless CACHE_ON_R2=yes: a crawl writes pages
  # far more often than R2's free 1M writes a month allow. Without these, R2 alone changes nothing.
  storage=supabase; [ "${CF_KV:0:3}" = yes ] && cache=kv || cache=assets
  if [ "$CF_R2" = yes ] && [ "${FILES_ON_R2:-no}" = yes ]; then storage=r2-binding; fi
  if [ "$CF_R2" = yes ] && [ "${CACHE_ON_R2:-no}" = yes ]; then cache=r2; fi
  # PAGE_CACHE=assets (the workflow's page_cache input): serve pages as built, for a day the KV free write quota
  # (1,000 a day) is used up by earlier deploys and the cache cannot be filled
  if [ "${PAGE_CACHE:-auto}" = assets ] && [ "$cache" = kv ]; then cache=assets; notice "Page cache: assets for this deploy (PAGE_CACHE=assets)"; fi
  tag=none
  [ "$cache" = r2 ] && [ "$CF_D1" = yes ] && tag=d1
  [ "$cache" = kv ] && tag=kv

  if [ "$cache" = r2 ] || [ "$storage" = r2-binding ]; then
    local b name
    for b in "${BUCKETS[@]}"; do
      name="$P-$b"
      if cfapi GET "/accounts/$ACC/r2/buckets/$name" > /dev/null 2>&1; then log "r2: $name exists"; continue; fi
      cfapi POST "/accounts/$ACC/r2/buckets" "$(jq -n --arg n "$name" '{name: $n, locationHint: "enam"}')" > /dev/null || die "Could not create the R2 bucket $name"
      notice "R2: bucket $name created"
    done
  fi
  if [ "$tag" = d1 ]; then
    local db="$P-tag-cache"
    d1_id=$(cfapi GET "/accounts/$ACC/d1/database?name=$db" | jq -r --arg n "$db" '[.result[]? | select(.name == $n)][0].uuid // empty')
    if [ -z "$d1_id" ]; then
      d1_id=$(cfapi POST "/accounts/$ACC/d1/database" "$(jq -n --arg n "$db" '{name: $n, primary_location_hint: "enam"}')" | jq -r '.result.uuid // empty') || true
      [ -n "$d1_id" ] && notice "D1: database $db created" || { warn "D1 database could not be created; no tag cache"; tag=none; }
    fi
  fi
  if [ "$cache" = kv ]; then
    local title="$P-cache"
    kv_id=$(cfapi GET "/accounts/$ACC/storage/kv/namespaces?per_page=100" | jq -r --arg t "$title" '[.result[]? | select(.title == $t)][0].id // empty')
    if [ -z "$kv_id" ]; then
      kv_id=$(cfapi POST "/accounts/$ACC/storage/kv/namespaces" "$(jq -n --arg t "$title" '{title: $t}')" | jq -r '.result.id // empty') || true
      if [ -n "$kv_id" ]; then notice "KV: namespace $title created"; else warn "KV namespace could not be created; pages are served as built"; cache=assets; tag=none; fi
    fi
  fi

  case "$cache" in
    kv) cp "$HERE/open-next/kv.config.ts" "$ROOT/web/open-next.config.ts" ;;
    assets) cp "$HERE/open-next/assets.config.ts" "$ROOT/web/open-next.config.ts" ;;
    r2) [ "$tag" = d1 ] || sed -i '/tagCache: withEdgeGeneration(d1NextTagCache),/d; /d1-next-tag-cache/d; /tag-cache-gen/d' "$ROOT/web/open-next.config.ts" ;;
  esac
  node "$ROOT/scripts/deploy/wrangler-config.mjs" --cache "$cache" --tag "$tag" --storage "$storage" ${kv_id:+--kv-id "$kv_id"} ${d1_id:+--d1-id "$d1_id"}
  export_env STORAGE_PROVIDER "$storage"
  export_env OPEN_NEXT_CACHE "$cache"
  if [ "$storage" = supabase ]; then
    export_env NEXT_PUBLIC_VEHICLE_PHOTOS_URL "https://$SUPABASE_PROJECT_REF.supabase.co/storage/v1/object/public/vehicle-public"
  else
    export_env NEXT_PUBLIC_VEHICLE_PHOTOS_URL "${APP_URL:-https://$DOMAIN}/media"
  fi
  notice "Cache and storage: page cache $cache, tag cache $tag, files $storage"
}

# Wrangler refuses to upload a Worker until the account has a workers.dev subdomain (code 10063), even
# though this Worker answers only on its custom domains (workers_dev is false in wrangler.jsonc).
subdomain() {
  local cur
  cur=$(cfapi GET "/accounts/$ACC/workers/subdomain" 2>/dev/null | jq -r '.result.subdomain // empty') || cur=""
  if [ -n "$cur" ]; then log "workers.dev subdomain: $cur"; return; fi
  local try out
  for try in carmacars carmacars-ca "carmacars-$(openssl rand -hex 3)"; do
    if out=$(cfapi PUT "/accounts/$ACC/workers/subdomain" "$(jq -n --arg s "$try" '{subdomain: $s}')" 2>&1); then
      notice "Workers: account subdomain $try.workers.dev created (needed before the first upload; the site itself is not served there)"
      return
    fi
    log "subdomain $try refused: $(grep -o '"message":"[^"]*"' <<<"$out" | head -1)"
  done
  die "The account has no workers.dev subdomain and the token cannot create one: open Workers & Pages once in the Cloudflare dashboard"
}

turnstile() {
  local list key secret name="$DOMAIN"
  [ "$DEPLOY_ENV" = staging ] && name="staging.$DOMAIN"
  if list=$(cfapi GET "/accounts/$ACC/challenges/widgets?per_page=50" 2>/dev/null); then
    key=$(jq -r --arg n "$name" '[.result[]? | select(.name == $n)][0].sitekey // empty' <<<"$list")
    if [ -z "$key" ]; then
      local created
      if created=$(cfapi POST "/accounts/$ACC/challenges/widgets" "$(jq -n --arg n "$name" --arg d "$DOMAIN" \
            '{name: $n, domains: [$d, ("www." + $d)], mode: "managed", region: "world"}')" 2>/dev/null); then
        key=$(jq -r '.result.sitekey' <<<"$created"); secret=$(jq -r '.result.secret' <<<"$created")
        notice "Turnstile: widget $name created"
      fi
    else
      secret=$(cfapi GET "/accounts/$ACC/challenges/widgets/$key" | jq -r '.result.secret // empty') || secret=""
    fi
  fi
  if [ -n "${key:-}" ] && [ -n "${secret:-}" ]; then
    mask "$secret"
    export_env TURNSTILE_PROVIDER cloudflare
    export_env NEXT_PUBLIC_TURNSTILE_SITE_KEY "$key"
    export_env TURNSTILE_SECRET_KEY "$secret"
    log "turnstile: on ($key)"
  else
    export_env TURNSTILE_PROVIDER off
    export_env NEXT_PUBLIC_TURNSTILE_SITE_KEY ""
    warn "Turnstile is OFF: the API token cannot read or create Turnstile widgets (needs Account > Turnstile > Edit). Public forms rely on the database rate limits until it is on."
  fi
}

dns() {
  [ "$DEPLOY_ENV" = production ] || { log "dns: staging has no custom domain"; return; }
  local zone recs attached
  zone=$(cfapi GET "/zones?name=$DOMAIN" | jq -r '.result[0].id // empty') || die "The token cannot read the $DOMAIN zone"
  [ -n "$zone" ] || die "Zone $DOMAIN is not in this account"
  attached=$(cfapi GET "/accounts/$ACC/workers/domains?zone_id=$zone" 2>/dev/null | jq -r '[.result[]? | "\(.hostname)=\(.service)"] | join(" ")') || attached=""
  log "dns: worker custom domains now: ${attached:-none}"
  local h
  for h in "$DOMAIN" "www.$DOMAIN"; do
    if grep -qw "$h=$P" <<<"$attached"; then log "dns: $h already on $P"; continue; fi
    recs=$(cfapi GET "/zones/$zone/dns_records?name=$h&per_page=100" | jq -c '[.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME")]')
    local n
    n=$(jq 'length' <<<"$recs")
    [ "$n" = "0" ] && { log "dns: $h has no address record (the custom domain creates it)"; continue; }
    local r
    for r in $(jq -r '.[] | @base64' <<<"$recs"); do
      local rec
      rec=$(base64 -d <<<"$r")
      cfapi DELETE "/zones/$zone/dns_records/$(jq -r '.id' <<<"$rec")" > /dev/null || die "Could not remove $(jq -c '{type,name,content}' <<<"$rec") (the token needs DNS Edit)"
      notice "DNS: removed $(jq -r '"\(.type) \(.name) -> \(.content) (proxied \(.proxied))"' <<<"$rec") so the Worker custom domain can take $h"
    done
  done
}

photos() {
  local bucket="$P-vehicle-public" marker=".seeded/stand-in-photos-v1" f
  cd "$ROOT/web"
  # the listing pipeline's studio backdrop and shadow, always refreshed (two small files)
  for f in brand_background_v1.png studio_v2.png shadow_v1.png; do
    npx wrangler r2 object put "$bucket/site/backdrop/$f" --file "src/features/listing/presets/$f" --content-type image/png --cache-control "public, max-age=31536000" --remote > /dev/null \
      || die "Could not upload the listing preset $f"
  done
  if npx wrangler r2 object get "$bucket/$marker" --remote --pipe > /dev/null 2>&1; then
    log "photos: already uploaded"; return
  fi
  local list
  list=$(mktemp)
  node -e '
    const fs = require("fs"), path = require("path");
    const dir = path.join(process.argv[1], "prototype/assets/photos");
    const cars = Object.keys(JSON.parse(fs.readFileSync(path.join(process.argv[1], "prototype/assets/photos.json"), "utf8")).cars);
    for (const f of fs.readdirSync(dir)) {
      const isCar = cars.some((s) => f.startsWith(s + "-"));
      console.log((isCar ? "vehicles/" : "site/") + f + "\t" + path.join(dir, f));
    }' "$ROOT" > "$list"
  log "photos: uploading $(wc -l < "$list") files to $bucket"
  # shellcheck disable=SC2016
  tr '\t' '\n' < "$list" | xargs -n 2 -P 8 sh -c 'ct=image/jpeg; case "$0" in *.svg) ct=image/svg+xml;; *.webp) ct=image/webp;; *.png) ct=image/png;; *.avif) ct=image/avif;; esac;
      npx wrangler r2 object put "'"$bucket"'/$0" --file "$1" --content-type "$ct" --cache-control "public, max-age=31536000" --remote > /dev/null 2>&1 || { echo "upload failed: $0" >&2; exit 255; }'
  echo "uploaded $(date -u +%FT%TZ)" > "$list.marker"
  npx wrangler r2 object put "$bucket/$marker" --file "$list.marker" --content-type text/plain --remote > /dev/null
  notice "Photos: $(wc -l < "$list") stand-in photos uploaded to $bucket"
  rm -f "$list" "$list.marker"
}

# Image transformations on the zone (the listing photos: segment=foreground and draw). Turned on when the
# token may; otherwise the worker keeps each original and flags it for staff (docs/changes/0032).
images() {
  local zone cur
  zone=$(cfapi GET "/zones?name=$DOMAIN" | jq -r '.result[0].id // empty') || { warn "Images: the token cannot read the $DOMAIN zone"; return 0; }
  cur=$(cfapi GET "/zones/$zone/settings/image_resizing" 2>/dev/null | jq -r '.result.value // empty') || cur=""
  if [ "$cur" = "on" ] || [ "$cur" = "open" ]; then notice "Images: transformations are on for $DOMAIN ($cur)"; return 0; fi
  if cfapi PATCH "/zones/$zone/settings/image_resizing" '{"value":"on"}' > /dev/null 2>&1; then
    notice "Images: transformations turned on for $DOMAIN (free up to 5,000 unique transformations a month)"
  else
    warn "Images: transformations are ${cur:-not readable} on $DOMAIN and the token cannot turn them on (Zone > Zone Settings > Edit, or Images > Transformations in the dashboard). Listing photos keep their original background and are flagged for staff until then."
  fi
}

# Turo by email (0063). Read only, except the routing rule of the inbound address (created or pointed at the Worker).
# Email Routing on the subdomain is turned on by the owner in the dashboard; this reports whether it is, and never calls
# the enable or DNS endpoints, so the root domain's MX records (Google Workspace) can never change here.
email() {
  [ "$DEPLOY_ENV" = production ] || { log "email: production only"; return; }
  local sub="in.$DOMAIN" addr="trips@in.$DOMAIN" worker="carmacars-prod" zone out mx rules rid body steps
  steps="Cloudflare dashboard > $DOMAIN > Email > Email Routing > Settings > Subdomains: add 'in', then Routing rules > Custom address trips@$sub > Send to a Worker > $worker (the owner steps in docs/changes/2026-10-19-turo-email-quiet-alerts.md)"
  zone=$(cfapi GET "/zones?name=$DOMAIN" 2>/dev/null | jq -r '.result[0].id // empty') || zone=""
  [ -n "$zone" ] || { warn "Turo by email: the token cannot read the zone $DOMAIN. $steps"; return; }
  mx=$(cfapi GET "/zones/$zone/dns_records?type=MX&name=$sub" 2>/dev/null | jq -r '[.result[]?.content] | join(", ")') || mx=""
  if [ -z "$mx" ]; then
    notice "Turo by email: Email Routing is not on for $sub yet (no MX records on $sub). $steps"
    return
  fi
  log "email: MX on $sub: $mx"
  if ! rules=$(cfapi GET "/zones/$zone/email/routing/rules?per_page=50" 2>&1); then
    warn "Turo by email: the token cannot read the Email Routing rules (it needs Zone > Email Routing Rules > Edit). Set the rule by hand: $steps"
    return
  fi
  rid=$(jq -r --arg a "$addr" '[.result[]? | select(any(.matchers[]?; .field == "to" and .value == $a))][0].id // empty' <<<"$rules")
  if [ -n "$rid" ] && jq -e --arg a "$addr" --arg w "$worker" '[.result[]? | select(any(.matchers[]?; .value == $a))][0] | .enabled and any(.actions[]?; .type == "worker" and (.value | index($w)))' <<<"$rules" >/dev/null; then
    notice "Turo by email: ready. Mail to $addr goes to the Worker $worker"
    return
  fi
  body=$(jq -n --arg a "$addr" --arg w "$worker" '{name: "Turo trip emails to the CarmaCars Worker", enabled: true, matchers: [{type: "literal", field: "to", value: $a}], actions: [{type: "worker", value: [$w]}]}')
  if [ -n "$rid" ]; then out=$(cfapi PUT "/zones/$zone/email/routing/rules/$rid" "$body" 2>&1) || out="FAILED $out"
  else out=$(cfapi POST "/zones/$zone/email/routing/rules" "$body" 2>&1) || out="FAILED $out"; fi
  if [[ "$out" == FAILED* ]]; then
    warn "Turo by email: the rule for $addr could not be set ($(grep -o '"message":"[^"]*"' <<<"$out" | head -1)). Set it by hand: $steps"
  else
    notice "Turo by email: the rule for $addr now sends it to the Worker $worker"
  fi
}

for step in "$@"; do "$step"; done
