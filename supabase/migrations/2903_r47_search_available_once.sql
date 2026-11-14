-- 2903 (release 47): the cars list for chosen dates prices each car once, not seven times.
--
-- The owner's report (Nov 14): /cars with dates showed "Live availability is not loading" for every visitor. The list asks
-- public.search_available, which runs as anon with its 5 s limit (0111). Its inner query priced each free car with
-- app.price_quote and then read seven fields of that quote; Postgres folded the inner query into the outer one and
-- copied the price_quote call into each of the seven reads, so every car was priced seven times. With about 120 public
-- cars that is about 3.5 s on an idle database (measured), and over 5 s on the live one: the read was cancelled.
-- "offset 0" keeps the inner query as its own step, so each car is priced once (about 0.5 s for the same fleet).
-- Nothing else about the answer changes. No applied migration is edited: the function is patched in place, and the
-- patch refuses when the text it changes is not found.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2903: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.search_available(timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$l.daily_rate_cents <= (f ->> 'max_daily_rate_cents')::bigint)) q$o$,
  $n$l.daily_rate_cents <= (f ->> 'max_daily_rate_cents')::bigint) offset 0) q$n$);

comment on function app.search_available(timestamptz, timestamptz, jsonb) is
  'The cars free for the dates, each priced once (2903: the inner query is kept as its own step, so price_quote runs once a car).';
