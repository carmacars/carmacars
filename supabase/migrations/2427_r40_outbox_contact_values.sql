-- 2427_r40_outbox_contact_values.sql
-- Release 40: "An email could not be sent: owner_agreement_to_sign ... Template: Missing value: support_phone". The emails a
-- migration queues straight into notification_outbox (owner_agreement_to_sign from app.owner_agreement_send, 0640, and the
-- forms reminder, 1000) carried only their own values, not the footer's contact details that the event path adds
-- (app.ntf_contact: phone, address, hours, reply promise, social links). The sender renders strictly, so the email failed.
-- Every row queued now gets those values; a value already in the row always wins. The emails that failed for this
-- reason in the last 14 days are queued again with the values.
create function app.outbox_fill_contact() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  -- a row without values of its own (a suppression record, a placeholder) is left as it is
  if coalesce(new.payload, '{}'::jsonb) <> '{}'::jsonb then
    new.payload := coalesce(app.ntf_contact(), '{}'::jsonb) || new.payload;
  end if;
  return new;
end $$;
revoke all on function app.outbox_fill_contact() from public, anon, authenticated;
grant execute on function app.outbox_fill_contact() to service_role;

create trigger notification_outbox_fill_contact before insert on notification_outbox
  for each row execute function app.outbox_fill_contact();

update notification_outbox
   set payload = coalesce(app.ntf_contact(), '{}'::jsonb) || coalesce(payload, '{}'::jsonb),
       status = 'queued', last_error = null, locked_at = null, send_after = now()
 where status = 'failed'
   and last_error ~ '^Template: Missing value: (support_phone|company_address|contact_email|opening_hours|reply_time|instagram_url|tiktok_url|roadside_phone)$'
   and created_at > now() - interval '14 days';
