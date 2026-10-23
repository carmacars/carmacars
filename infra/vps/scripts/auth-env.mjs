// Renders Supabase Auth's settings, given in the Management API's config/auth shape (the hosted project's own, copied
// by the vps-copy workflow and changed since by the deploy's auth and phoneauth steps), into what the self-hosted
// GoTrue reads: auth.env (GOTRUE_* variables) and the email templates as files, which Caddy serves to the auth
// container on the Docker network (GoTrue takes a template URL, not its text).
//
//   node infra/vps/scripts/auth-env.mjs --out DIR < auth-config.json
//     writes DIR/auth.env and DIR/templates/<type>.html; prints a summary (names only) on stdout
//   node infra/vps/scripts/auth-env.mjs --self-test
//
// A setting the hosted shape has and this table does not is listed as "not carried" in the summary (nothing silent).
// Values with a newline or "$" are refused (compose env files would change them).
import fs from 'node:fs';
import path from 'node:path';

const TEMPLATE_BASE = 'http://caddy:8089';
const TYPES = ['confirmation', 'invite', 'recovery', 'magic_link', 'email_change', 'reauthentication'];

// config/auth field -> GOTRUE_ variable, and how the value is written
const bool = (v) => (v ? 'true' : 'false');
const str = (v) => String(v);
const seconds = (v) => `${Number(v)}s`;
const MAP = {
  site_url: ['SITE_URL', str],
  uri_allow_list: ['URI_ALLOW_LIST', str],
  disable_signup: ['DISABLE_SIGNUP', bool],
  jwt_exp: ['JWT_EXP', str],
  external_email_enabled: ['EXTERNAL_EMAIL_ENABLED', bool],
  external_phone_enabled: ['EXTERNAL_PHONE_ENABLED', bool],
  external_anonymous_users_enabled: ['EXTERNAL_ANONYMOUS_USERS_ENABLED', bool],
  mailer_autoconfirm: ['MAILER_AUTOCONFIRM', bool],
  mailer_secure_email_change_enabled: ['MAILER_SECURE_EMAIL_CHANGE_ENABLED', bool],
  mailer_otp_exp: ['MAILER_OTP_EXP', str],
  mailer_otp_length: ['MAILER_OTP_LENGTH', str],
  smtp_admin_email: ['SMTP_ADMIN_EMAIL', str],
  smtp_host: ['SMTP_HOST', str],
  smtp_port: ['SMTP_PORT', str],
  smtp_user: ['SMTP_USER', str],
  smtp_pass: ['SMTP_PASS', str],
  smtp_sender_name: ['SMTP_SENDER_NAME', str],
  smtp_max_frequency: ['SMTP_MAX_FREQUENCY', seconds],
  sms_autoconfirm: ['SMS_AUTOCONFIRM', bool],
  sms_max_frequency: ['SMS_MAX_FREQUENCY', seconds],
  sms_otp_exp: ['SMS_OTP_EXP', str],
  sms_otp_length: ['SMS_OTP_LENGTH', str],
  sms_provider: ['SMS_PROVIDER', str],
  sms_template: ['SMS_TEMPLATE', str],
  mfa_totp_enroll_enabled: ['MFA_TOTP_ENROLL_ENABLED', bool],
  mfa_totp_verify_enabled: ['MFA_TOTP_VERIFY_ENABLED', bool],
  mfa_phone_enroll_enabled: ['MFA_PHONE_ENROLL_ENABLED', bool],
  mfa_phone_verify_enabled: ['MFA_PHONE_VERIFY_ENABLED', bool],
  mfa_max_enrolled_factors: ['MFA_MAX_ENROLLED_FACTORS', str],
  password_min_length: ['PASSWORD_MIN_LENGTH', str],
  password_required_characters: ['PASSWORD_REQUIRED_CHARACTERS', str],
  password_hibp_enabled: ['PASSWORD_HIBP_ENABLED', bool],
  rate_limit_email_sent: ['RATE_LIMIT_EMAIL_SENT', str],
  rate_limit_sms_sent: ['RATE_LIMIT_SMS_SENT', str],
  rate_limit_verify: ['RATE_LIMIT_VERIFY', str],
  rate_limit_token_refresh: ['RATE_LIMIT_TOKEN_REFRESH', str],
  rate_limit_otp: ['RATE_LIMIT_OTP', str],
  rate_limit_anonymous_users: ['RATE_LIMIT_ANONYMOUS_USERS', str],
  refresh_token_rotation_enabled: ['SECURITY_REFRESH_TOKEN_ROTATION_ENABLED', bool],
  security_refresh_token_reuse_interval: ['SECURITY_REFRESH_TOKEN_REUSE_INTERVAL', str],
  security_update_password_require_reauthentication: ['SECURITY_UPDATE_PASSWORD_REQUIRE_REAUTHENTICATION', bool],
  security_manual_linking_enabled: ['SECURITY_MANUAL_LINKING_ENABLED', bool],
  sessions_timebox: ['SESSIONS_TIMEBOX', seconds],
  sessions_inactivity_timeout: ['SESSIONS_INACTIVITY_TIMEOUT', seconds],
  sessions_single_per_user: ['SESSIONS_SINGLE_PER_USER', bool],
  hook_send_sms_enabled: ['HOOK_SEND_SMS_ENABLED', bool],
  hook_send_sms_uri: ['HOOK_SEND_SMS_URI', str],
  hook_send_sms_secrets: ['HOOK_SEND_SMS_SECRETS', str],
  hook_send_email_enabled: ['HOOK_SEND_EMAIL_ENABLED', bool],
  hook_send_email_uri: ['HOOK_SEND_EMAIL_URI', str],
  hook_send_email_secrets: ['HOOK_SEND_EMAIL_SECRETS', str],
  hook_custom_access_token_enabled: ['HOOK_CUSTOM_ACCESS_TOKEN_ENABLED', bool],
  hook_custom_access_token_uri: ['HOOK_CUSTOM_ACCESS_TOKEN_URI', str],
  hook_custom_access_token_secrets: ['HOOK_CUSTOM_ACCESS_TOKEN_SECRETS', str],
  hook_mfa_verification_attempt_enabled: ['HOOK_MFA_VERIFICATION_ATTEMPT_ENABLED', bool],
  hook_mfa_verification_attempt_uri: ['HOOK_MFA_VERIFICATION_ATTEMPT_URI', str],
  hook_mfa_verification_attempt_secrets: ['HOOK_MFA_VERIFICATION_ATTEMPT_SECRETS', str],
  hook_password_verification_attempt_enabled: ['HOOK_PASSWORD_VERIFICATION_ATTEMPT_ENABLED', bool],
  hook_password_verification_attempt_uri: ['HOOK_PASSWORD_VERIFICATION_ATTEMPT_URI', str],
  hook_password_verification_attempt_secrets: ['HOOK_PASSWORD_VERIFICATION_ATTEMPT_SECRETS', str]
};
// third-party sign-in providers: external_<p>_enabled / _client_id / _secret (redirect: <API>/auth/v1/callback)
const PROVIDER = /^external_([a-z0-9]+)_(enabled|client_id|secret|url|skip_nonce_check)$/;
// shown by the Management API, meaningless here (the project's own plumbing, or set by docker-compose.yml)
const IGNORED = /^(api_max_request_duration|db_max_pool_size|jwt_secret|saml_|security_captcha_|smtp_pass_encrypted|nimbus_|external_.*_additional_client_ids|mailer_allow_unverified_email_sign_ins|.*_email_optional)/;

// a value that may be a masked placeholder from the API ("******") or empty
const real = (v) => v !== null && v !== undefined && v !== '' && !(typeof v === 'string' && /^\*+$/.test(v));

function quote(name, v) {
  if (/[\n\r$]/.test(v)) throw new Error(`${name}: value has a newline or "$"; not written`);
  if (!v.includes("'")) return `'${v}'`;
  return `"${v.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

export function render(cfg) {
  const env = [], carried = [], notCarried = [];
  const put = (name, v) => env.push(`GOTRUE_${name}=${quote(`GOTRUE_${name}`, v)}`);
  for (const [k, v] of Object.entries(cfg).sort(([a], [b]) => a.localeCompare(b))) {
    if (MAP[k]) {
      if (!real(v)) continue;
      // a duration of 0 (no limit) is left to GoTrue's default
      if (MAP[k][1] === seconds && Number(v) === 0) continue;
      put(MAP[k][0], MAP[k][1](v)); carried.push(k); continue;
    }
    const p = PROVIDER.exec(k);
    if (p) {
      if (!real(v)) continue;
      const [, prov, what] = p;
      if (!cfg[`external_${prov}_enabled`]) continue;
      put(`EXTERNAL_${prov.toUpperCase()}_${what.toUpperCase()}`, typeof v === 'boolean' ? bool(v) : str(v)); carried.push(k);
      if (what === 'enabled') put(`EXTERNAL_${prov.toUpperCase()}_REDIRECT_URI`, `${cfg.__api_external_url ?? 'https://api.carmacars.ca'}/auth/v1/callback`);
      continue;
    }
    const m = /^mailer_(subjects|templates)_([a-z_]+?)(_content)?$/.exec(k);
    if (m && TYPES.includes(m[2])) {
      if (!real(v)) continue;
      if (m[1] === 'subjects') { put(`MAILER_SUBJECTS_${m[2].toUpperCase()}`, str(v)); carried.push(k); }
      continue; // templates: written as files below
    }
    if (k.startsWith('__') || IGNORED.test(k) || v === null || v === false || v === '') continue;
    notCarried.push(k);
  }
  const templates = {};
  for (const t of TYPES) {
    const v = cfg[`mailer_templates_${t}_content`];
    if (real(v)) { templates[`${t}.html`] = String(v); put(`MAILER_TEMPLATES_${t.toUpperCase()}`, `${TEMPLATE_BASE}/${t}.html`); carried.push(`mailer_templates_${t}_content`); }
  }
  return { env: `# GoTrue settings rendered by infra/vps/scripts/auth-env.mjs from auth-config.json. Secret: root only.\n${env.join('\n')}\n`, templates, carried, notCarried };
}

function selfTest() {
  const r = render({ site_url: 'https://carmacars.ca', uri_allow_list: 'https://carmacars.ca/auth/callback', disable_signup: false, jwt_exp: 3600,
    smtp_host: 'smtp.resend.com', smtp_port: '465', smtp_user: 'resend', smtp_pass: '******', smtp_max_frequency: 60,
    sms_template: "CarmaCars code: {{ .Code }}. It expires in 5 minutes. Don't share it.", external_phone_enabled: true,
    hook_send_sms_enabled: true, hook_send_sms_uri: 'https://carmacars.ca/api/webhooks/auth-sms', hook_send_sms_secrets: 'v1,whsec_abc=',
    mfa_totp_enroll_enabled: true, mailer_subjects_confirmation: 'Confirm your CarmaCars account', mailer_templates_confirmation_content: '<p>{{ .TokenHash }}</p>',
    external_google_enabled: false, external_google_client_id: 'x', sessions_timebox: 0, some_new_setting: 5 });
  const need = ["GOTRUE_SITE_URL='https://carmacars.ca'", "GOTRUE_DISABLE_SIGNUP='false'", "GOTRUE_SMTP_MAX_FREQUENCY='60s'",
    `GOTRUE_SMS_TEMPLATE="CarmaCars code: {{ .Code }}. It expires in 5 minutes. Don't share it."`, "GOTRUE_HOOK_SEND_SMS_SECRETS='v1,whsec_abc='",
    "GOTRUE_MAILER_TEMPLATES_CONFIRMATION='http://caddy:8089/confirmation.html'", "GOTRUE_MAILER_SUBJECTS_CONFIRMATION='Confirm your CarmaCars account'"];
  for (const n of need) if (!r.env.includes(n)) throw new Error(`self-test: missing ${n}\n${r.env}`);
  for (const bad of ['SMTP_PASS', 'GOOGLE', 'SESSIONS_TIMEBOX']) if (r.env.includes(bad)) throw new Error(`self-test: ${bad} should not be written`);
  if (r.templates['confirmation.html'] !== '<p>{{ .TokenHash }}</p>') throw new Error('self-test: template');
  if (JSON.stringify(r.notCarried) !== '["some_new_setting"]') throw new Error(`self-test: notCarried ${JSON.stringify(r.notCarried)}`);
  let threw = false; try { render({ smtp_pass: 'a$b' }); } catch { threw = true; }
  if (!threw) throw new Error('self-test: "$" must be refused');
  console.log('auth-env self-test: ok');
}

if (process.argv.includes('--self-test')) selfTest();
else {
  const i = process.argv.indexOf('--out');
  if (i < 0 || !process.argv[i + 1]) { console.error('usage: auth-env.mjs --out DIR < auth-config.json'); process.exit(2); }
  const out = process.argv[i + 1];
  const cfg = JSON.parse(fs.readFileSync(0, 'utf8'));
  const r = render(cfg);
  fs.mkdirSync(path.join(out, 'templates'), { recursive: true });
  fs.writeFileSync(path.join(out, 'auth.env'), r.env, { mode: 0o600 });
  for (const [f, v] of Object.entries(r.templates)) fs.writeFileSync(path.join(out, 'templates', f), v);
  console.log(JSON.stringify({ carried: r.carried.length, templates: Object.keys(r.templates), not_carried: r.notCarried }));
}
