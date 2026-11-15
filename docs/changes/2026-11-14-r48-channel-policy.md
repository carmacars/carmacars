# Fewer texts, more email: a channel for each message type (Release 48: 2971)

Migration `2971_r48_channel_policy.sql`.

Texts cost money and most messages read as well by email. Program settings now has **Texts and email by message type**: each message that can go by text, its texts in the last 30 days, and its channel (email only, text only, or text and email as the person chooses).

- `program_settings.email_production_ready` (off): while Amazon SES is in its sandbox nothing changes. On: the urgent types keep their texts by default (the pickup details and codes, the late return, a failed payment, a declined deposit) and every other type goes by email only, by text only when the person has no email address or theirs is bounced or suppressed. An Admin flips it on the same card.
- `message_channel_policy`: the types an Admin changed (`admin_do channel_policy_set {code, channel | null}`, audited); `app.channel_policy_for` is the rule; the routing trigger `app.notify_route` follows it.
- An email of an email-only type that bounces, and the ones still waiting for that address, go by text instead (`app.outbox_record_bounce` wrapped).
- Texts sent outside the notifications (the deposit link, sign-in codes, staff alerts, texts typed by staff) always stay texts; the card lists their counts.
- Tests: `supabase/tests/99_r48_channel_policy.sql`; unit: `features/channel-policy/model.test.ts`.

## Guides

- `admin/settings`: Texts and email by message type.
- `admin/text-alerts-email-text-or-both`: fewer texts once email is ready.
