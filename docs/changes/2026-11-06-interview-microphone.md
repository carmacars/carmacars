# AI interviews can record again: the site allows the microphone, November 6, 2026

## 1. What was wrong

Applicants with the microphone on could not record an AI interview answer. The site's `Permissions-Policy` header said
`microphone=()`, which blocks the microphone on every carmacars.ca page, whatever the browser allows. The interview fell
back to "The microphone is blocked" and typed answers.

## 2. Now

`Permissions-Policy` allows the microphone for carmacars.ca itself: `microphone=(self)` (`web/src/lib/security/csp.ts`,
the local server in `web/scripts/serve.mjs`, the security blueprint). Other sites in frames still cannot use it.

## Guides

No guide change: the interview steps are the same; recording now works as the guides already describe.
