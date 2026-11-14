-- 2910 (release 48): renters are no longer told "The signature does not match the one drawn".
--
-- The owner's report (Nov 14): renters got an error saying their signature does not match. Root causes:
-- 1. The signature box uploads the drawing at the end of each stroke, and each upload becomes the session's signature.
--    A renter who draws two or three strokes and presses Sign at once sends the path of an earlier stroke while the
--    last one is stored: the strict check (0154, record_signature and sign_booking_amendment; 0193,
--    esign_signature_matches) compared the two paths exactly and refused.
-- 2. The same renter signing on two devices (or two tabs) within two hours shares one session: the drawing of the other
--    device became the session's, and the first device was refused the same way.
-- 3. A typed name was compared with the legal name ignoring only case and spaces: accents, hyphens, a middle name,
--    the order of the names or an initial refused a real renter.
--
-- Now: the signature recorded is always the session's own latest drawing (any drawing of that session, or none sent,
-- signs with it); a drawing from another signing still refuses (the person signing is the one in the session: the
-- session is found from the signed-in renter or the driver's link, never from the page). Typed names are compared
-- tolerantly (app.person_names_match); with the signing session on, a renter's typed name that still differs is
-- accepted and staff get a To do to check it, instead of an error. No applied migration is edited: functions are patched in place and the patch refuses
-- when the text it changes is not found.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2910: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- The words of a name, lower case, accents and punctuation removed ("Zoë O'Neil-Brown" -> {zoe, oneil, brown}).
create or replace function app.person_name_tokens(p text) returns text[]
language sql immutable as $$
  select coalesce(array_remove(regexp_split_to_array(btrim(regexp_replace(
           lower(translate(regexp_replace(coalesce(p, ''), '[''`’‘]', '', 'g'),
             'ÀÁÂÃÄÅàáâãäåĀāĂăĄąÇçĆćČčĎďÈÉÊËèéêëĒēĘęĚěÌÍÎÏìíîïĪīŁłÑñŃńŇňÒÓÔÕÖØòóôõöøŌōŐőŘřŚśŠšŞşŤťÙÚÛÜùúûüŪūŮůŰűÝýÿŹźŻżŽž',
             'AAAAAAaaaaaaAaAaAaCcCcCcDdEEEEeeeeEeEeEeIIIIiiiiIiLlNnNnNnOOOOOOooooooOoOoRrSsSsSsTtUUUUuuuuUuUuUuYyyZzZzZz')),
           '[^a-z0-9]+', ' ', 'g')), ' '), ''), '{}'::text[])
$$;

-- x's first and last words are both in y (the first may be an initial): middle names and order do not matter.
create or replace function app.person_name_covers(x text[], y text[]) returns boolean
language sql immutable as $$
  select cardinality(x) >= 2 and cardinality(y) >= 2
     and (x[1] = any (y) or (length(x[1]) = 1 and exists (select 1 from unnest(y) t where left(t, 1) = x[1])))
     and x[cardinality(x)] = any (y)
$$;

-- Is this the same person's name? Case, accents, punctuation, hyphens, spaces, middle names, the order of the names
-- and an initial for the first name are ignored. Nicknames are not guessed (staff check those).
create or replace function app.person_names_match(a text, b text) returns boolean
language plpgsql immutable as $$
declare
  ta text[] := app.person_name_tokens(a);
  tb text[] := app.person_name_tokens(b);
begin
  if cardinality(ta) = 0 or cardinality(tb) = 0 then return false; end if;
  if array_to_string(ta, '') = array_to_string(tb, '') then return true; end if;
  return app.person_name_covers(ta, tb) or app.person_name_covers(tb, ta);
end $$;

-- A renter's typed name, compared tolerantly. With the signing session on (Program settings, esign_strict: the session
-- has already proved who signs) one that still differs is never refused: it is recorded as typed and staff get a To do
-- to check it. Without the session the name is all there is, so a name that still differs is refused as before.
-- Returns whether to refuse (it sits where the old refusal's condition was).
create or replace function app.typed_name_refused(p_booking uuid, p_expected text, p_given text) returns boolean
language plpgsql security definer set search_path = public, app as $$
begin
  if p_given is null or app.person_names_match(p_given, p_expected) then return false; end if;
  if not coalesce((app.settings()).esign_strict, true) then return true; end if;
  perform app.raise_task(p_type => 'signature_name_review', p_title => 'Check a typed signature: the name differs from the legal name',
    p_detail => format('Signed as "%s"; the legal name on file is "%s". Check the licence and correct the name, or ask the renter.', left(p_given, 120), p_expected),
    p_booking => p_booking, p_queue => 'cs', p_priority => 'normal', p_dedupe => 'signature_name_review:' || coalesce(p_booking::text, '') || ':' || lower(left(p_given, 60)));
  return false;
end $$;

-- The session id in a drawing's key (esign/<session>/signature-<uuid>.png).
create or replace function app.esign_path_session(p text) returns uuid
language sql immutable as $$
  select (substring(coalesce(p, '') from '^esign/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/'))::uuid
$$;

-- The complete session that signs: the one the drawing sent belongs to (this signer's, ready), else the newest ready one.
create or replace function app.esign_pick(p_context text, p_ref uuid, p_drawn text) returns esign_sessions
language plpgsql stable security definer set search_path = public, app as $$
declare
  s esign_sessions;
begin
  select x.* into s from esign_sessions x where x.id = app.esign_path_session(p_drawn) and x.context = p_context and x.signer_ref = p_ref and app.esign_is_ready(x);
  if s.id is null then s := app.esign_ready(p_context, p_ref); end if;
  return s;
end $$;

-- The drawing recorded: the session's own latest one when the page sent none, the same one or another drawing of the
-- same session (an earlier stroke, the other device); a drawing of another signing is refused.
create or replace function app.esign_drawn_for(s esign_sessions, p_drawn text) returns text
language plpgsql stable as $$
declare
  v text := nullif(btrim(coalesce(p_drawn, '')), '');
begin
  if s.id is null or s.signature_method is distinct from 'drawn' then return v; end if;
  if v is null or v = s.signature_path or app.esign_path_session(v) = s.id then return s.signature_path; end if;
  raise exception 'This signature does not match this signing page. Reload the page and sign once more' using errcode = '23514';
end $$;

-- 0193's check (owners, partners, investors, staff, an owner's co-signer): another drawing of the same session passes.
create or replace function app.esign_signature_matches(s esign_sessions, p_drawn text, p_typed text) returns void
language plpgsql stable as $$
declare
  v text := nullif(btrim(coalesce(p_drawn, '')), '');
begin
  if s.signature_method = 'drawn' and v is distinct from s.signature_path and app.esign_path_session(v) is distinct from s.id then
    raise exception 'This signature does not match this signing page. Reload the page and sign once more' using errcode = '23514';
  end if;
  if s.signature_method = 'typed' and nullif(btrim(coalesce(p_typed, '')), '') is null then
    raise exception 'Type your full legal name' using errcode = '22023';
  end if;
end $$;

-- The rental agreement (renter, additional driver): the session of the drawing, signed with its latest drawing.
select pg_temp.patch_fn('app.record_signature(uuid, uuid, text, text, inet, text, text, text, jsonb)'::regprocedure,
  $o$s := app.esign_ready('rental_agreement', p_signer);$o$,
  $n$s := app.esign_pick('rental_agreement', p_signer, p_drawn_signature);$n$);
select pg_temp.patch_fn('app.record_signature(uuid, uuid, text, text, inet, text, text, text, jsonb)'::regprocedure,
  $o$    if s.signature_method = 'drawn' and p_drawn_signature is distinct from s.signature_path then
      raise exception 'The signature does not match the one drawn: sign again' using errcode = '23514';
    end if;$o$,
  $n$    if s.signature_method = 'drawn' then p_drawn_signature := app.esign_drawn_for(s, p_drawn_signature); end if;$n$);

-- An amendment: the same.
select pg_temp.patch_fn('app.sign_booking_amendment(uuid, uuid, text, text, text, text, inet, text)'::regprocedure,
  $o$s := app.esign_ready('amendment', p_amendment);$o$,
  $n$s := app.esign_pick('amendment', p_amendment, p_drawn_signature);$n$);
select pg_temp.patch_fn('app.sign_booking_amendment(uuid, uuid, text, text, text, text, inet, text)'::regprocedure,
  $o$    if s.signature_method = 'drawn' and p_drawn_signature is distinct from s.signature_path then
      raise exception 'The signature does not match the one drawn: sign again' using errcode = '23514';
    end if;$o$,
  $n$    if s.signature_method = 'drawn' then p_drawn_signature := app.esign_drawn_for(s, p_drawn_signature); end if;$n$);

-- Typed names of renters and drivers: tolerant, and never refused (staff check one that still differs).
select pg_temp.patch_fn('app.record_signature_0019(uuid, uuid, text, text, inet, text, text, text, jsonb)'::regprocedure,
  $o$lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(g.signer_name, '\s+', '', 'g'))$o$,
  $n$app.typed_name_refused(b.id, g.signer_name, v_typed)$n$);
select pg_temp.patch_fn('app.record_signature_pre0154(uuid, uuid, text, text, inet, text, text, text, jsonb)'::regprocedure,
  $o$lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(g.signer_name, '\s+', '', 'g'))$o$,
  $n$app.typed_name_refused(b.id, g.signer_name, v_typed)$n$);
select pg_temp.patch_fn('app.sign_booking_amendment_0040(uuid, uuid, text, text, text, text, inet, text)'::regprocedure,
  $o$lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(r.legal_name, '\s+', '', 'g'))$o$,
  $n$app.typed_name_refused(am.booking_id, r.legal_name, v_typed)$n$);
-- owners and documents sent to sign: the tolerant comparison (a name that still differs is refused, as before)
select pg_temp.patch_fn('app.owner_sign_agreements_0029(uuid, uuid, jsonb)'::regprocedure,
  $o$lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(v_signer, '\s+', '', 'g'))$o$,
  $n$not app.person_names_match(v_typed, v_signer)$n$);
select pg_temp.patch_fn('app.sign_request_sign_0044(uuid, uuid, jsonb)'::regprocedure,
  $o$lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(r.signer_name, '\s+', '', 'g'))$o$,
  $n$not app.person_names_match(v_typed, r.signer_name)$n$);

revoke all on function app.typed_name_refused(uuid, text, text) from public;
grant execute on function app.typed_name_refused(uuid, text, text) to service_role;
grant execute on function app.person_name_tokens(text), app.person_names_match(text, text), app.person_name_covers(text[], text[]) to authenticated, service_role;

comment on function app.person_names_match(text, text) is
  'Same person''s name (2910): case, accents, punctuation, hyphens, spaces, middle names, name order and a first-name initial ignored.';
comment on function app.esign_drawn_for(esign_sessions, text) is
  'The drawing recorded (2910): the session''s latest one for any drawing of the same session or none; another signing''s is refused.';
