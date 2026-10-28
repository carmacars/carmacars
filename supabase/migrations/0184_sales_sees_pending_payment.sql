-- 0184: Sales sees a booking waiting for payment (the owner, October 28). SCHEMA_MARKER 0184.
-- A renter who accepted a Sales offer and left the pay page (CC-10029) disappeared from Sales' list and page: Sales saw
-- only requests and offers out. Now Sales lists and opens bookings waiting for payment too (to call the renter, send the
-- pay link again, or meet them), as before read only for what Sales may not change.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0184: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.va_list(uuid, text, jsonb)'::regprocedure,
  $o$jsonb_build_object('status', jsonb_build_array('requested', 'offered')));$o$,
  $n$jsonb_build_object('status', jsonb_build_array('requested', 'offered', 'pending_payment')));$n$);

select pg_temp.patch_fn('app.va_booking_0031(uuid, text, jsonb)'::regprocedure,
  $o$if p_fn = 'sales' and not (v ->> 'status' in ('requested', 'offered')$o$,
  $n$if p_fn = 'sales' and not (v ->> 'status' in ('requested', 'offered', 'pending_payment')$n$);
