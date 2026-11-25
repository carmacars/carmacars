-- r50 security fixes found by 99_r35sec_security:
--   app.academy_questions_joke() is a SECURITY DEFINER trigger function; nobody needs to call it directly.
--   checkin_visits.booked_by and done_by are join-path foreign keys and get indexes.
revoke execute on function app.academy_questions_joke() from public, anon, authenticated;
create index if not exists checkin_visits_booked_by_idx on checkin_visits (booked_by);
create index if not exists checkin_visits_done_by_idx on checkin_visits (done_by);
