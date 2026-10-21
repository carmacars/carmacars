# Show password, a simpler cookie banner and quieter site health (October 21, 2026)

Migration `0075_site_health_quiet.sql`. No applied migration was edited.

| Change | Where |
| --- | --- |
| Every password field (sign in, create account, new password, the owner application) has a Show / Hide button inside the field. The input stays the same element and keeps its name, so forms work as before | `web/src/features/forms/PasswordInput.tsx`, `AuthForms.tsx`, `features/owner/ApplyWizard.tsx`, `styles/motion.css` |
| The cookie banner is one short block: the wording from site content (up to three lines), one large Accept button, and "Necessary only" and the preferences as small links under it. Same choices, same record in the database, same preferences dialog | `web/src/components/CookieBanner.tsx`, `styles/core.css` |
| Site health, scheduled jobs: a pg_cron run that failed only with "job startup timeout" (no free database connection for a moment) is not reported once the same job has run successfully after it. A job that keeps failing, or fails for another reason, is still reported | `app.uptime_internal` |
| Cookies by region (approved by the owner and the lawyer): visitors from Canada outside Quebec and from the US get a notice with analytics on, OK and Opt out, fading after 10 seconds; everyone else, and an unknown location, is asked first. The Worker sets `cc_geo` (country-region) on pages; `record_cookie_notice` keeps the region with the record; privacy section 10 updated | `CookieBanner.tsx`, `custom-worker.ts`, `cookie_consents.region`, `cookies.banner` |
| The phone number is 289-312-5991 everywhere it is set: site phone, WhatsApp and roadside line, Program settings (company and incident line, used by agreements and emails), guide text, email samples, guides sources, the prototype and tests. History (sent emails, chats, audit) is unchanged | migration 0075; repository |
