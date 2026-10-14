-- 0034_audit_fixes.sql
-- What the handover audit (docs/audit/2026-10-13-audit.md) found the emails link to without a door in the
-- database for the website:
--   1. one-click unsubscribe from marketing emails (the link every marketing email carries, and the
--      List-Unsubscribe-Post request mail apps send): server wrappers for 0018's app.unsubscribe_token_info()
--      and app.unsubscribe(); the link's path moves to /unsubscribe, the page the website serves
--   2. the renter's review of a closed booking, which the review request email asks for: the review state
--      of a booking and the submit, with the renter's consent to publish (reviews.publish_consent_at of
--      0019, never set until now)

-- ================================================================ 1. unsubscribe
-- The website's page is /unsubscribe (robots.txt keeps it out of search). Links already sent with the old
-- path keep working: the website redirects /email/unsubscribe to /unsubscribe.
alter table program_settings alter column notify_unsubscribe_path set default '/unsubscribe';
update program_settings set notify_unsubscribe_path = '/unsubscribe' where notify_unsubscribe_path = '/email/unsubscribe';

-- What the page shows before the click: valid, a masked address, already unsubscribed. Nothing changes.
create or replace function public.server_unsubscribe_info(p_token uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select coalesce((select jsonb_build_object('valid', i.valid, 'masked_email', i.masked_email, 'already_unsubscribed', i.already_unsubscribed)
                     from app.unsubscribe_token_info(p_token) i limit 1),
                  jsonb_build_object('valid', false, 'masked_email', null, 'already_unsubscribed', false))
$$;

-- The click, or the mail app's one-click request. Idempotent; false for an unknown token.
create or replace function public.server_unsubscribe(p_token uuid) returns boolean
language sql volatile security invoker set search_path = public, app as $$
  select app.unsubscribe(p_token)
$$;

revoke all on function public.server_unsubscribe_info(uuid), public.server_unsubscribe(uuid) from public, anon, authenticated;
grant execute on function public.server_unsubscribe_info(uuid), public.server_unsubscribe(uuid) to service_role;

-- ================================================================ 2. the renter's review
-- One booking's review state for its renter: may review (closed, not an Owner Booking, no review yet), and
-- the review left, if any.
create or replace function app.renter_review_state(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  r reviews;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking;
  select * into r from reviews where booking_id = p_booking;
  return jsonb_build_object(
    'can_review', b.status = 'closed' and b.booking_type <> 'owner' and r.id is null,
    'status', b.status,
    'review', case when r.id is null then null else jsonb_build_object(
      'rating', r.rating, 'title', r.title, 'body', r.body, 'status', r.status, 'staff_reply', r.staff_reply,
      'created_at', r.created_at, 'publish_consent', r.publish_consent_at is not null) end);
end $$;

-- The review itself: 0016's app.submit_review (closed bookings only, one per booking, pending until staff
-- publish it), plus the renter's consent to show it on the site (the moderation screen shows it).
create or replace function app.renter_submit_review(p_booking uuid, p_by uuid, p_rating integer, p_title text,
                                                    p_body text, p_publish_consent boolean) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'Choose a rating from 1 to 5 stars' using errcode = '22023';
  end if;
  if length(coalesce(p_title, '')) > 120 or length(coalesce(p_body, '')) > 2000 then
    raise exception 'The title is at most 120 characters and the review at most 2,000' using errcode = '22023';
  end if;
  v_id := app.submit_review(p_booking, p_by, p_rating, p_title, p_body);
  if coalesce(p_publish_consent, false) then
    update reviews set publish_consent_at = now() where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function public.renter_review_state(p_booking uuid, p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select app.renter_review_state(p_booking, p_by)
$$;
create or replace function public.renter_submit_review(p_booking uuid, p_by uuid, p_rating integer, p_title text default null,
                                                       p_body text default null, p_publish_consent boolean default false) returns uuid
language sql volatile security invoker set search_path = public, app as $$
  select app.renter_submit_review(p_booking, p_by, p_rating, p_title, p_body, p_publish_consent)
$$;

revoke all on function app.renter_review_state(uuid, uuid), app.renter_submit_review(uuid, uuid, integer, text, text, boolean),
  public.renter_review_state(uuid, uuid), public.renter_submit_review(uuid, uuid, integer, text, text, boolean)
  from public, anon, authenticated;
grant execute on function app.renter_review_state(uuid, uuid), app.renter_submit_review(uuid, uuid, integer, text, text, boolean),
  public.renter_review_state(uuid, uuid), public.renter_submit_review(uuid, uuid, integer, text, text, boolean)
  to service_role;

-- ================================================================ 3. the disable approval email without a booking
-- A disable asked for on a ground other than a late return (suspected theft, procedure 8) has no booking, so the
-- booking number and the renter were left empty and the email could not be rendered: the admins were never told.
-- They now read "No booking" and "No renter"; with a booking they are read from it when the event lacks them.
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0033;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0033(p_code, p_event, p_to);
  b bookings;
  r renters;
begin
  if p_code <> 'staff_disable_approval_needed' then return x; end if;
  select * into b from bookings where id = nullif(p_event.payload ->> 'booking_id', '')::uuid;
  select * into r from renters where id = b.renter_id;
  return x || jsonb_build_object(
    'booking_number', coalesce(nullif(x ->> 'booking_number', ''), b.booking_number, 'No booking'),
    'renter_name', coalesce(nullif(x ->> 'renter_name', ''), nullif(p_event.payload ->> 'renter_name', ''), r.legal_name, 'No renter'),
    'renter_phone', coalesce(nullif(x ->> 'renter_phone', ''), nullif(p_event.payload ->> 'renter_phone', ''), r.mobile, 'no phone on file'));
end $$;

-- ================================================================ 4. the renter portal's documents are the renter's own
-- public.my_documents (0028) listed every document row-level security lets the caller read, so a staff member who
-- opened /account/documents saw the whole company's files there (licence images included, outside the identity
-- review screen and its access log). The renter portal now lists the caller's own renter documents only; staff
-- keep their screens.
create or replace function public.my_documents() returns setof jsonb
language sql stable security invoker set search_path = public, app as $$
  select jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'mime_type', d.mime_type, 'created_at', d.created_at,
                            'purge_after', d.purge_after, 'purged', d.purged_at is not null,
                            'booking_number', (select rb.booking_number from renter_bookings rb where rb.id = d.booking_id))
    from documents d
   where d.renter_id = app.my_renter_id() or app.is_my_booking(d.booking_id)
   order by d.created_at desc
$$;

-- ================================================================ 5. digest lines read as words
-- The staff digests showed raw status codes ("Claim_Open") and "Due not set". Every digest line goes through
-- app.ntf_item, so its second line is tidied there: underscores become spaces and a missing date reads
-- "No due date".
create or replace function app.ntf_item(p_line text, p_meta text, p_url text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('line', p_line,
    'meta', regexp_replace(replace(coalesce(p_meta, ''), '_', ' '), '^(Due|Evidence due) not set$', 'No due date'),
    'url', coalesce(p_url, ''))
$$;
