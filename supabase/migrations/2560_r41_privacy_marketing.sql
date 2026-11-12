-- Release 41 (2560): the privacy policy says what Release 41 does: marketing emails (the weekly cars-and-deals email and the
-- new-car email) go to everyone who gave an email address on carmacars.ca unless they unsubscribed; CASL implied consent;
-- sender, one-click unsubscribe, contact. Changes only text still carrying ours (an Admin's own edit is left as it is).
-- docs/changes/2026-11-12-r41-privacy.md. No applied migration is edited.
update site_content_blocks
   set body = replace(body, 'We send promotional emails and texts only if you opted in, or where Canada''s anti-spam law otherwise allows. Every message identifies us and lets you unsubscribe. We act on an unsubscribe within 10 business days. Messages about your booking, payments or safety are not marketing and are always sent.',
'**Marketing emails.** If you give us your email address anywhere on carmacars.ca (a booking, an account, a contact or listing form, a discount game, or a form you started but did not send), we may send you marketing emails: a weekly email with the cars ready to rent and the deals running, and an email each time a new car joins our fleet. Under Canada''s anti-spam law (CASL), your inquiry or business relationship with us, and the address you gave us, is implied consent to these emails. We do not send them to anyone who has unsubscribed.

**Who sends them.** 18122211 Canada Inc., operating as CarmaCars{{mailingAddress}}. Questions: {{contactEmail}}, or our privacy officer, {{privacyOfficer}}.

**Unsubscribe.** Every marketing email has an unsubscribe link. One click stops all our marketing emails to that address, and it takes effect at once. You can also turn offers off in your account under Notifications.

**Always sent.** Messages about your booking, payments, account or safety are not marketing and are always sent.

**Texts.** We send promotional texts only if you opted in.')
 where block_key = 'legal.privacy' and body like '%We send promotional emails and texts only if you opted in, o%';
update site_content_blocks
   set body = replace(body, 'never for offers without your consent.', 'and for our marketing emails (section 11).')
 where block_key = 'legal.privacy' and body like '%never for offers without your consent.%';
update site_content_blocks
   set body = replace(body, 'offers only with your consent', 'offers by email as described in section 11')
 where block_key = 'legal.privacy' and body like '%offers only with your consent%';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'November 12, 2026')
 where block_key = 'legal.meta' and coalesce(data ->> 'last_updated', '') <> 'November 12, 2026'
   and exists (select 1 from site_content_blocks b where b.block_key = 'legal.privacy' and b.body like '%Marketing emails.** If you give us your email address%');
