-- 0270: a booking message is texted once, not twice (docs/changes/2026-10-31-no-double-texts.md).
--
-- Why texts went twice (live, October 31: the offer text arrived twice, one link with ?m=): renters get booking messages
-- by text by default (0213), and while emails are held for the daily limit the held email is ALSO texted (0212). Both
-- reached the same phone for the same message. Now the held email's text is not sent when that booking's message of the
-- same kind already went (or is going) to the person by text, and any two texts with the same words to the same number
-- within 10 minutes are sent once.

alter function app.outbox_text(uuid, uuid) rename to outbox_text_pre0270;
create function app.outbox_text(p_id uuid, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o notification_outbox;
begin
  select * into o from notification_outbox where id = p_id;
  if p_by is null and o.id is not null and exists (
       select 1 from phone_outbox x
        where x.status <> 'skipped' and x.created_at > now() - interval '12 hours'
          and ((o.booking_id is not null and x.booking_id = o.booking_id and x.sms_kind = o.code)
               or (x.notification_id is not null and x.notification_id = o.id))) then
    return jsonb_build_object('ok', false, 'reason', 'already texted');
  end if;
  return app.outbox_text_pre0270(p_id, p_by);
end $$;

-- the same words to the same number twice within 10 minutes: the second is skipped (a link's ?m= marker is ignored)
create or replace function app.phone_outbox_no_repeat() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'queued' and new.kind in ('booking', 'notify') and exists (
       select 1 from phone_outbox x
        where x.id <> new.id and x.to_number = new.to_number and x.status <> 'skipped'
          and x.created_at > now() - interval '10 minutes'
          and regexp_replace(x.body, '\?m=[0-9a-f-]+', '', 'g') = regexp_replace(new.body, '\?m=[0-9a-f-]+', '', 'g')) then
    new.status := 'skipped'; new.status_reason := 'The same text went to this number a few minutes ago';
  end if;
  return new;
end $$;
drop trigger if exists phone_outbox_no_repeat on phone_outbox;
create trigger phone_outbox_no_repeat before insert on phone_outbox for each row execute function app.phone_outbox_no_repeat();

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('outbox_text', 'outbox_text_pre0270', 'phone_outbox_no_repeat') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
