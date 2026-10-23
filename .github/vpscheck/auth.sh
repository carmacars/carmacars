#!/usr/bin/env bash
source .github/vpscheck/common.sh
keys
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
say "== GoTrue settings on the server (non-secret keys of auth.env)"
vps_ssh "sudo grep -E '^GOTRUE_(SITE_URL|SMTP_HOST|SMTP_PORT|SMTP_SENDER_NAME|MAILER_AUTOCONFIRM|MAILER_SECURE_EMAIL_CHANGE_ENABLED|EXTERNAL_EMAIL_ENABLED|EXTERNAL_PHONE_ENABLED|EXTERNAL_GOOGLE_ENABLED|EXTERNAL_GOOGLE_REDIRECT_URI|HOOK_SEND_SMS_ENABLED|HOOK_SEND_SMS_URI|MFA_TOTP_ENROLL_ENABLED|MFA_TOTP_VERIFY_ENABLED|MFA_MAX_ENROLLED_FACTORS|RATE_LIMIT_[A-Z_]+|SMS_OTP_EXP|SMS_TEMPLATE|MAILER_OTP_EXP|SECURITY_REFRESH_TOKEN_ROTATION_ENABLED|SECURITY_REFRESH_TOKEN_REUSE_INTERVAL|URI_ALLOW_LIST|DISABLE_SIGNUP|SESSIONS_[A-Z_]+|PASSWORD_MIN_LENGTH)=' /opt/carmacars/supabase/auth.env; sudo grep -cE '^GOTRUE_MAILER_TEMPLATES_' /opt/carmacars/supabase/auth.env; sudo grep -E '^GOTRUE_(SMTP_USER|SMTP_PASS|HOOK_SEND_SMS_SECRETS|EXTERNAL_GOOGLE_SECRET|EXTERNAL_GOOGLE_CLIENT_ID)=' /opt/carmacars/supabase/auth.env | sed -E 's/=.+/=<set>/'" 2>&1 | cut -c1-240 | sayf
say "== sessions from before the switch refreshed since go-live (auth.refresh_tokens)"
q <<SQL | sayf
select 'sessions created before go-live with a token minted after it', count(distinct s.id) from auth.sessions s join auth.refresh_tokens t on t.session_id = s.id where s.created_at < '$SINCE' and t.created_at >= '$SINCE';
select 'refresh tokens minted since go-live', count(*) from auth.refresh_tokens where created_at >= '$SINCE';
select 'sign-ins (sessions created) since go-live', count(*) from auth.sessions where created_at >= '$SINCE';
select 'mfa factors totp verified', count(*) from auth.mfa_factors where factor_type = 'totp' and status = 'verified';
select 'users', count(*) from auth.users;
select 'auth users with the company number', count(*) from auth.users where phone = '${PHONE#+}';
SQL
say "== GoTrue end to end (throwaway account, removed at the end)"
API=$API SITE=$SITE ANON=$ANON SERVICE=$SERVICE JWT_SECRET=$JWT_SECRET REF=$SUPABASE_PROJECT_REF RUN=$RUN PHONE=$PHONE node .github/vpscheck/auth.mjs 2>&1 | sayf
say "== GoTrue log since this check started (mail, sms hook, errors)"
sleep 20
vps_ssh "sudo /opt/carmacars/bin/dc logs --no-color --no-log-prefix --since $T0 auth 2>&1" > "$RUNNER_TEMP/auth.log" || true
grep -iE 'mail|smtp|hook|sms|error|"level":"(warn|error)"' "$RUNNER_TEMP/auth.log" | grep -oE '"(level|msg|error|component|path|status|mail_type|action)":("[^"]{0,200}"|[0-9]+)' | paste -sd' ' | sed 's/"level"/\n"level"/g' | cut -c1-300 | sort | uniq -c | sort -rn | head -20 | sayf
say "== Resend: the emails to the test address since the check started"
RK=$(vps_secret RESEND_API_KEY); [ -n "$RK" ] || RK=$(vault deploy_resend_api_key)
sleep 30
code=$(curl -sS -o "$RUNNER_TEMP/re.json" -w '%{http_code}' "https://api.resend.com/emails?limit=50" -H "Authorization: Bearer $RK")
say "resend list: $code"
jq -r --arg r "vpscheck-$RUN" '.data[]? | select((.to|tostring)|contains($r)) | "\(.created_at) \(.last_event) subject=\(.subject) from=\(.from|split("<")[0])"' "$RUNNER_TEMP/re.json" 2>/dev/null | sayf
jq -r '.message? // empty' "$RUNNER_TEMP/re.json" | sayf
say "resend: last 50 emails by last_event since go-live:"
jq -r --arg s "2026-10-23 15:15" '[.data[]? | select(.created_at >= $s)] | group_by(.last_event) | map("\(.[0].last_event)=\(length)") | join(" ")' "$RUNNER_TEMP/re.json" 2>/dev/null | sayf
flush auth
