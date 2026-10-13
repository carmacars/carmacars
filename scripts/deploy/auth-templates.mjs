// Prints the Supabase Auth email templates as a JSON patch for PATCH /v1/projects/{ref}/config/auth.
// Every link goes to the site's /auth/callback with a token hash, which the callback verifies on the
// server. This works on any device and browser: the default templates send people to Supabase's own
// verify page, which then lands on the home page with nothing to show, and the email confirmation
// does not reach the account page.
// Usage: node scripts/deploy/auth-templates.mjs
const red = '#D0111B';
const wrap = (title, body, cta, href, after) => `<!doctype html><html><body style="margin:0;background:#EDEDED;font-family:Inter,Helvetica,Arial,sans-serif;color:#111111">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#EDEDED;padding:24px 0"><tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#FFFFFF">
<tr><td style="background:#000000;border-top:4px solid ${red};padding:24px 32px"><span style="font-size:24px;font-weight:800;color:#FFFFFF">Carma<span style="color:${red}">Cars</span></span></td></tr>
<tr><td style="padding:32px">
<h1 style="font-size:24px;line-height:1.25;margin:0 0 16px">${title}</h1>
<p style="font-size:16px;line-height:1.5;margin:0 0 24px">${body}</p>
<p style="margin:0 0 24px"><a href="${href}" style="display:inline-block;background:${red};color:#FFFFFF;text-decoration:none;font-weight:700;font-size:16px;padding:14px 24px;border-radius:6px">${cta}</a></p>
<p style="font-size:14px;line-height:1.5;color:#5C5C5C;margin:0">${after}</p>
</td></tr>
<tr><td style="background:#F5F5F5;padding:20px 32px;font-size:13px;color:#5C5C5C">CarmaCars, Toronto. Questions: contact@carmacars.ca</td></tr>
</table></td></tr></table></body></html>`;

const cb = (type, next) => `{{ .SiteURL }}/auth/callback?token_hash={{ .TokenHash }}&type=${type}&next=${next}`;

const patch = {
  mailer_subjects_confirmation: 'Confirm your CarmaCars account',
  mailer_templates_confirmation_content: wrap('Confirm your email', 'Thanks for creating a CarmaCars account. Confirm this email address to finish.', 'Confirm my email', cb('signup', '/account'), 'The link works once. If you did not create an account, ignore this email.'),
  mailer_subjects_invite: 'Your CarmaCars account',
  mailer_templates_invite_content: wrap('Your CarmaCars account is ready', 'An account has been created for you. Choose a password to sign in.', 'Choose your password', cb('invite', '/update-password'), 'The link works once. If it has expired, use "Forgot password" on the sign-in page.'),
  mailer_subjects_recovery: 'Reset your CarmaCars password',
  mailer_templates_recovery_content: wrap('Choose a new password', 'We received a request to reset the password on your CarmaCars account.', 'Choose a new password', cb('recovery', '/update-password'), 'The link works once and expires in one hour. If you did not ask for this, ignore this email; your password stays the same.'),
  mailer_subjects_magic_link: 'Your CarmaCars sign-in link',
  mailer_templates_magic_link_content: wrap('Sign in to CarmaCars', 'Tap the button to sign in. No password needed.', 'Sign in', cb('magiclink', '/account'), 'The link works once and expires in one hour.'),
  mailer_subjects_email_change: 'Confirm your new CarmaCars email',
  mailer_templates_email_change_content: wrap('Confirm your new email address', 'Confirm this address to use it for your CarmaCars account.', 'Confirm new email', cb('email_change', '/account'), 'If you did not ask for this change, contact us at privacy@carmacars.ca.')
};
process.stdout.write(JSON.stringify(patch));
