-- 3012 (release 48): the two pages of an OPCF 27 proof carry the same names for the renter, staff and Admins:
-- "pink slip" and "OPCF 27 endorsement page" (docs/changes/2026-11-14-r48-coverage-page-labels.md).
-- Before, one page was "OPCF 27 endorsement" (what is missing, the document title), "the endorsement page" (the renter's
-- button) or "OPCF 27 endorsement page" (the review and the upload), depending on the screen.
-- No applied migration is edited: the functions are patched (pg_temp.patch_fn).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3012: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- what is still missing (the checkout, the Verify page, the staff review read it): app.opcf27_missing and
-- app.coverage_state compare through this one function, so both follow
create or replace function app.opcf27_page_label(p text) returns text
language sql immutable as $$
  select case p when 'pink_slip' then 'pink slip' when 'endorsement' then 'OPCF 27 endorsement page' when 'card_benefit' then 'card benefit document' else 'policy document' end
$$;

-- the document's title in the renter's files
select pg_temp.patch_fn('app.register_verification_upload(uuid, uuid, text, uuid, text, text, text, jsonb, text)'::regprocedure,
  $o$case v_page when 'pink_slip' then 'Pink slip' else 'OPCF 27 endorsement' end$o$,
  $n$case v_page when 'pink_slip' then 'Pink slip' else 'OPCF 27 endorsement page' end$n$);
update documents set title = replace(title, 'OPCF 27 endorsement, booking ', 'OPCF 27 endorsement page, booking ')
 where title like 'OPCF 27 endorsement, booking %';

-- the renter's checklist button
select pg_temp.patch_fn('app.renter_still_needed(uuid)'::regprocedure,
  $o$when 'endorsement' then 'Upload the endorsement page'$o$,
  $n$when 'endorsement' then 'Upload the OPCF 27 endorsement page'$n$);
