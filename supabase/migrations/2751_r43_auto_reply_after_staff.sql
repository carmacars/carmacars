-- 2751 (release 43): the AI auto-reply stays quiet while a person is answering. It answered a customer's next message
-- right after a staff member had replied by hand: the gate (2110) only looked at texts staff sent from the site, for SMS.
-- Now, on every channel, no automatic answer is sent when a person replied to that sender within
-- program_settings.auto_reply_after_staff_minutes (30 by default; Program settings, AI auto-replies):
--   SMS    a staff text from the site (phone_outbox kind staff, sent by a person), or a text sent from the Quo app (an
--          outgoing text on the thread that none of our outbox rows sent);
--   email  an email or message a staff member sent to that address (messages, outbound, sent_by set).
-- SMS keeps its earlier 2-hour rule for staff texts from the site.
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2751: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

alter table program_settings add column if not exists auto_reply_after_staff_minutes integer not null default 30
  check (auto_reply_after_staff_minutes between 0 and 1440);
comment on column program_settings.auto_reply_after_staff_minutes is 'AI auto-replies (2751): no automatic answer to a sender a person replied to within this many minutes (30 by default; 0: no pause).';

create function app.auto_reply_staff_replied(p_channel text, p_sender text, p_now timestamptz default now()) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_since timestamptz := p_now - make_interval(mins => coalesce((app.settings()).auto_reply_after_staff_minutes, 30));
begin
  if p_sender is null or btrim(p_sender) = '' or v_since >= p_now then return false; end if;
  if p_channel = 'sms' then
    return exists (select 1 from phone_outbox o where o.to_number = p_sender and o.kind = 'staff' and o.sent_by is not null and o.created_at > v_since)
        or exists (select 1 from phone_activity a join phone_threads t on t.id = a.thread_id
                    where t.number = p_sender and a.kind = 'text' and a.direction = 'out' and a.started_at > v_since
                      and a.outbox_id is null and a.sent_by is null
                      and not exists (select 1 from phone_outbox o where o.quo_message_id is not null and o.quo_message_id = a.quo_id));
  end if;
  return exists (select 1 from messages m
                  where m.direction = 'outbound' and m.sent_by is not null and m.occurred_at > v_since
                    and lower(btrim(coalesce(m.to_address, ''))) = lower(btrim(p_sender)));
end $$;
revoke all on function app.auto_reply_staff_replied(text, text, timestamptz) from public, anon, authenticated;
grant execute on function app.auto_reply_staff_replied(text, text, timestamptz) to service_role;

select pg_temp.patch_fn('public.server_auto_reply_gate(jsonb)'::regprocedure,
  $o$  -- the free allowance: Workers AI paused for the day$o$,
  $n$  -- 2751: a person replied to them a moment ago: the person goes on
  if app.auto_reply_staff_replied(v_channel, v_sender) then return no || jsonb_build_object('reason', 'a person is talking with them'); end if;
  -- the free allowance: Workers AI paused for the day$n$);
