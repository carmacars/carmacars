-- 3325 (release 48, integration): one speeding event is one charge, in the charge itself.
-- The owner (Nov 20) confirmed the rule 3323 puts in the agreement (rental agreement 10.5): a speeding event bills only the
-- highest limit reached. 3320 refuses a second charge on the tracker-alert path; this makes app.speeding_charge_add (3102,
-- the Admin and the connector) refuse it too: a speeding charge of the booking within the tracker's event window
-- (tracker_settings.event_window_minutes, 30) of this reading is the same event, whatever its limit. Void that charge first
-- to bill another. The same reading twice still says "already charged". SCHEMA_MARKER 3325.
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3325: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.speeding_charge_add(uuid, jsonb)'::regprocedure,
  $o$  v_desc := format('Speeding over %s km/h:$o$,
  $n$  if exists (select 1 from booking_line_items li
                 where li.booking_id = b.id and li.charge_type like 'speeding\_%' and li.voided_at is null and li.assessment_key <> v_key
                   and nullif(li.supporting_refs ->> 'at', '')::timestamptz
                       between v_at - make_interval(mins => (app.tracker_settings()).event_window_minutes) and v_at + make_interval(mins => (app.tracker_settings()).event_window_minutes)) then
    raise exception 'This speeding event is already charged at another limit: one event is one charge, at the highest limit reached. Void that charge first to bill this one' using errcode = '23514';
  end if;
  v_desc := format('Speeding over %s km/h:$n$);
