# Comms: SES sends, texts recover, auto-replies, the call screen (Release 50 hotfix 2: 5090, 5091, 5092, 5099)

The owner (Nov 25 to 27): "Amazon SES, Quo messages, Twilio calls ... all need to be working"; "still getting emails that
we're almost out of email usage ... even though we switched to SES"; auto replies stopped for texts and every social;
"Website calling ugly ... mute, speaker, mic choice, native look"; sales calls fail, there is no way to hang up, and one
salesperson cannot call at all.

Migrations `5090_r50h2_texts_recover.sql`, `5091_r50h2_email_meter_auto_replies.sql`,
`5092_r50h2_ses_reports_call_contacts.sql`, `5099_r50h2_comms_guides.sql`; tests `supabase/tests/99_r50h2_texts_recover.sql`,
`99_r50h2_email_meter_auto_replies.sql`, `99_r50h2_ses_contacts.sql` and `web/tests/e2e/r50h2-call-screen.spec.ts`.

## What it does

- **Amazon SES (5092)**: on Nov 27 every email went through Resend and the emails held for Resend's 100 a day all went at
  midnight. The server's send-outbox still binds its reports as a JSON string (f4df37d3 fixed the binds, its deploy was
  cancelled), so `server_ses_email_result({seen})` failed every minute and SES was never tried. The database now reads a
  report given as a JSON string as its object (`app.jsonb_arg`), so SES sends once the migration is applied, whichever
  build of send-outbox runs. Cloudflare's report the same.
- **The email meter (5091)**: the day's limit is the whole day's capacity (SES included), the month test counts Resend
  only, and the portal warning stays quiet while SES sends.
- **Texts (5090)**: any text that went through Quo after the newest failure clears "Sign-in codes by text"; a sign-in
  code refused for credits pauses texts and one that goes ends the pause; waiting texts go once the probe goes.
- **Auto-replies (5091)**: the gate asks `app.ai_allow('faq_reply')` like every AI feature, so the server's own model
  answers when Workers AI's share of the day is used (before, every question was skipped). **Owner decision open:** an
  auto-reply reads a renter's message, so it is private by default (`faq_reply` is in `app.ai_private` and
  `PRIVATE_PURPOSES`): it never goes to Gemini's free tier, where Google may use the text. To let Gemini answer too when
  the server's model is down, remove `faq_reply` from both lists (a new migration).
- **Texts (5090), owner decision open:** REQ-045 says stale queued texts are dropped when Quo credits return. 5090
  instead holds a due text up to 30 minutes (text_retry_paused_minutes) for the probe, then sends it by email; texts
  older than their drop rules (app.text_drop_reason) are still dropped.
- **The call screen (5091, 5092)**: name, number, timer, Mute, Keypad, Speaker (microphone and speaker choice), Hold and a
  red End call that is always on the screen and also cancels a call still starting; switching apps on a phone keeps a
  connected call on (pagehide ends only a call not yet connected), and a second tap never places a second call. The
  round phone button opens Keypad (any number) and Contacts (`app.voice_contacts`: the people called last, or a search;
  Sales see only their own leads, masked (the name too), and the call goes by the record; only Admins, customer
  service, Sales and Fleet may search, as phone_renter_search).
- **Call buttons**: a failed load of the phone settings was kept for the whole page, so Call became a dead `tel:` link
  (on a computer) or the own-mobile way (off) until a reload. A failure is no longer kept, and Call then places the call
  in the browser, where the server checks the person and the call screen says why when it cannot.

## Guides

- `admin/texts-and-calls-the-quo-phone-line`: Calls in the browser, the call screen and its contacts.
- `va/texts-and-calls`: Calls in your browser, the keypad, contacts and End call.

## Review fixes (fresh-eyes review of 5092, Nov 27)

- Contacts search: `app.assert_phone_staff` (0970) instead of any staff; `%`, `_` and `\` in a search match only
  themselves; a name shown masked to Sales goes through `app.mask_phone_text`.
- `scripts/diag/comms.sql` voice_settings: only calls, inbound, own_mobile and seconds (no forward number, no message).
- voice.ts: each call has an attempt number (End and a newer call stop an older one at its next step); no second call
  on a double tap; pagehide ends only a call that is not connected and not kept (`persisted`).
- 5090 and 5092 are re-run safe (create or replace; the `_pre5090` rename happens once).
- REQ-042 to REQ-046 updated with Rule, Proof and Test (docs/owner/requirements.md).
