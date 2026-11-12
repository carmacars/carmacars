-- 2470_r40_agreement_retry_on_profile.sql
-- Release 40 (the owner, Nov 12: "incomplete staff profiles should tell staff that they need to complete their profile in order to get
-- their agreements"). Welcome now tells a staff member which values their agreement waits for and how soon it comes once they are in.
-- For that to be true, the agreements job must try again soon after a missing value is filled in. Until now only the licence number
-- (2373) cleared the waiting row (staff_agreement_auto, kept for a day after a try); a home address, a start date or a pay set by
-- an Admin waited for the next day's try. A change to any value the agreement is made from now clears a waiting row (one that
-- has not produced a request), so the job's next five-minute run makes the agreement. Nothing else changes; no applied migration is edited.
create function app.staff_agreement_retry() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  delete from staff_agreement_auto where user_id = new.user_id and request_id is null;
  return new;
end $$;
revoke all on function app.staff_agreement_retry() from public, anon, authenticated;
grant execute on function app.staff_agreement_retry() to service_role;

drop trigger if exists staff_profiles_agreement_retry on staff_profiles;
create trigger staff_profiles_agreement_retry after update of home_address, started_on, licence_number on staff_profiles
  for each row when (old.home_address is distinct from new.home_address or old.started_on is distinct from new.started_on or old.licence_number is distinct from new.licence_number)
  execute function app.staff_agreement_retry();

drop trigger if exists staff_onboarding_agreement_retry on staff_onboarding;
create trigger staff_onboarding_agreement_retry after insert or update of start_on, pay_basis, pay_cents, pay_currency on staff_onboarding
  for each row execute function app.staff_agreement_retry();
