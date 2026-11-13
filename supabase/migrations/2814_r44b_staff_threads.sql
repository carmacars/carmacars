-- 2814 (release 44, part B): who is talking with a customer.
--   1. The AI auto-reply stays quiet when a person replied in the thread a moment ago (2751 gave the rule for texts and
--      email addresses). It still answered when the person's reply was not found: an email reply to "Name <address>"
--      (the address was compared whole), a reply sent to the customer's booking or account rather than to the exact
--      address or number they wrote from, and the live chat (whose assistant never asked). Now:
--        email, SMS, Meta: also any message a staff member sent to the same renter (by their address, number, booking
--                          or account) within program_settings.auto_reply_after_staff_minutes;
--        live chat:        a staff message in the conversation within the same minutes hands the chat to the person
--                          (app.server_chat_visitor_message says so: staff_replied).
--   2. A Sales person who closed a sale with a customer keeps that customer (2750) everywhere the customer is read: the
--      staff window rule (app.va_sees_renter) counts the closer, so the customer's conversations, chats, calls and
--      activity on any later booking stay theirs, not only the booking page, its email thread and its activity log.
-- No applied migration is edited: functions are wrapped, or replaced with the same rule plus the new case.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. a person replied a moment ago
-- the address inside "Name <address>", lower case; a number as written
create function app.contact_key(p text) returns text
language sql immutable as $$
  select nullif(lower(btrim(coalesce(substring(p from '<([^>]+)>'), p, ''))), '')
$$;

alter function app.auto_reply_staff_replied(text, text, timestamptz) rename to auto_reply_staff_replied_pre2814;
create function app.auto_reply_staff_replied(p_channel text, p_sender text, p_now timestamptz default now()) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_since timestamptz := p_now - make_interval(mins => coalesce((app.settings()).auto_reply_after_staff_minutes, 30));
  v_key text := app.contact_key(p_sender);
  v_renters uuid[];
  v_users uuid[];
begin
  if app.auto_reply_staff_replied_pre2814(p_channel, p_sender, p_now) then return true; end if;
  if v_key is null or v_since >= p_now then return false; end if;
  -- a staff message to that exact address, however it was written ("Name <address>", capitals)
  if exists (select 1 from messages m where m.direction = 'outbound' and m.sent_by is not null and m.occurred_at > v_since
                and app.contact_key(m.to_address) = v_key) then
    return true;
  end if;
  -- the same customer: a renter or an account with that email or number
  select coalesce(array_agg(r.id), '{}'), coalesce(array_agg(r.user_id) filter (where r.user_id is not null), '{}') into v_renters, v_users
    from renters r left join users u on u.id = r.user_id
   where lower(btrim(coalesce(r.email, ''))) = v_key or lower(btrim(coalesce(u.email, ''))) = v_key
      or btrim(coalesce(r.mobile, '')) = btrim(p_sender) or btrim(coalesce(u.phone, '')) = btrim(p_sender);
  if cardinality(v_renters) = 0 then return false; end if;
  return exists (select 1 from messages m
                  where m.direction = 'outbound' and m.sent_by is not null and m.occurred_at > v_since
                    and (m.renter_id = any (v_renters) or m.user_id = any (v_users)
                         or m.booking_id in (select b.id from bookings b where b.renter_id = any (v_renters))))
      or exists (select 1 from phone_outbox o join renters r on r.id = any (v_renters)
                  where o.kind = 'staff' and o.sent_by is not null and o.created_at > v_since
                    and btrim(coalesce(o.to_number, '')) = btrim(coalesce(r.mobile, '')) and nullif(btrim(coalesce(r.mobile, '')), '') is not null);
end $$;
select pg_temp.copy_grants('app.auto_reply_staff_replied(text, text, timestamptz)'::regprocedure, 'app.auto_reply_staff_replied_pre2814(text, text, timestamptz)'::regprocedure);

-- the live chat: a staff message in the conversation a moment ago: the assistant does not answer
alter function app.server_chat_visitor_message(text, text) rename to server_chat_visitor_message_pre2814;
create function app.server_chat_visitor_message(p_token text, p_body text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.server_chat_visitor_message_pre2814(p_token, p_body);
  v_since timestamptz := now() - make_interval(mins => coalesce((app.settings()).auto_reply_after_staff_minutes, 30));
begin
  if not coalesce((r ->> 'ok')::boolean, false) or not coalesce((r ->> 'ai')::boolean, false) then return r; end if;
  if exists (select 1 from chat_messages m join chat_conversations c on c.id = m.conversation_id
              where c.token = p_token and m.at > v_since and (m.staff_id is not null or m.sender = 'staff')) then
    return r || jsonb_build_object('ai', false, 'staff_replied', true);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.server_chat_visitor_message(text, text)'::regprocedure, 'app.server_chat_visitor_message_pre2814(text, text)'::regprocedure);

-- ================================================================ 2. the closer keeps the customer
-- 0012's rule, with the Sales person who closed a sale with this renter (2750)
create or replace function app.va_sees_renter(p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_va() and (
    -- a booking that is live, or ended within the window
    exists (select 1 from bookings b
             where b.renter_id = p_renter
               and (b.status in ('tentative', 'pending_payment', 'confirmed', 'on_rent', 'returned')
                    or greatest(b.return_at, coalesce(b.checked_in_at, b.return_at))
                       > now() - make_interval(days => (app.settings()).staff_customer_window_days)))
    -- an open task about this renter
    or exists (select 1 from tasks t where t.renter_id = p_renter and t.status in ('open', 'in_progress', 'waiting'))
    -- a new lead with no booking yet
    or exists (select 1 from renters r where r.id = p_renter
                and r.created_at > now() - make_interval(days => (app.settings()).staff_customer_window_days)
                and not exists (select 1 from bookings b where b.renter_id = r.id))
    -- a logged, time-limited lookup (app.staff_open_renter)
    or exists (select 1 from data_access_log g
                where g.renter_id = p_renter and g.user_id = app.uid() and g.action = 'open' and g.granted_until > now())
    -- r44: the Sales person who closed a sale with this customer keeps them (2750)
    or app.sales_owns_customer(app.uid(), p_renter))
$$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['contact_key', 'auto_reply_staff_replied_pre2814', 'server_chat_visitor_message_pre2814'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
