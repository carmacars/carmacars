-- 0026_reply_to_alignment.sql
-- The email catalogue (emails/catalogue.json, loaded into notification_catalogue by 0018) names the
-- desk each email replies to: contact@, bookings@, owners@, billing@, privacy@ or investors@.
-- 0025 chose the reply-to by audience only. This makes the order:
--   1. a per-code row an admin added to email_reply_to (an explicit override),
--   2. the catalogue's reply-to for that email, when it is an active alias,
--   3. the audience default in email_reply_to,
--   4. contact@carmacars.ca.
create or replace function app.email_reply_to_for(p_code text, p_audience text) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select r.reply_to from email_reply_to r join email_aliases a on a.address = r.reply_to and a.is_active where r.code = p_code limit 1),
    (select c.reply_to from notification_catalogue c join email_aliases a on a.address = c.reply_to and a.is_active where c.code = p_code),
    (select r.reply_to from email_reply_to r join email_aliases a on a.address = r.reply_to and a.is_active
      where r.code is null and r.audience = p_audience limit 1),
    'contact@carmacars.ca')
$$;

-- A North American number stored as +1XXXXXXXXXX shown as XXX-XXX-XXXX; anything else as stored.
create or replace function app.phone_display(p text) returns text
language sql immutable as $$
  select case when p ~ '^\+1[0-9]{10}$'
              then substr(p, 3, 3) || '-' || substr(p, 6, 3) || '-' || substr(p, 9, 4)
              else coalesce(p, '') end
$$;

-- The email footers (catalogue refreshed after 0025) carry the public contact details from
-- site_settings: email, phone as displayed, opening hours, reply promise and social links.
create or replace function app.ntf_contact() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'company_address', coalesce(nullif(ss.mailing_address, ''), nullif(ps.company_address, ''), ''),
    'support_phone',   app.phone_display(coalesce(nullif(ss.phone, ''), nullif(ps.company_phone, ''), '')),
    'roadside_phone',  app.phone_display(coalesce(nullif(ss.roadside_phone, ''), nullif(ps.incident_line_phone, ''),
                                nullif(ss.phone, ''), nullif(ps.company_phone, ''), '')),
    'contact_email',   coalesce(nullif(ss.public_email, ''), 'contact@carmacars.ca'),
    'opening_hours',   coalesce(nullif(ss.opening_hours_text, ''), ''),
    'reply_time',      coalesce(nullif(ss.reply_wording, ''), ''),
    'instagram_url',   coalesce(ss.social_links ->> 'instagram', ''),
    'tiktok_url',      coalesce(ss.social_links ->> 'tiktok', ''))
    from (select 1) one
    left join lateral (select * from site_settings order by created_at limit 1) ss on true
    left join lateral (select * from app.settings()) ps on true
$$;
