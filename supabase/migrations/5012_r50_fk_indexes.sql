-- 5012 (release 50): indexes for the foreign keys added in R50 (owner pipeline, incorporation referral, calls), per 99_r35sec.
-- SCHEMA_MARKER: 5012
set search_path = public, app, pg_temp;
create index if not exists call_participants_user_id_idx on call_participants (user_id);
create index if not exists call_participants_application_id_idx on call_participants (application_id);
create index if not exists owner_pipeline_last_nudge_by_idx on owner_pipeline (last_nudge_by);
create index if not exists owner_pipeline_visited_by_idx on owner_pipeline (visited_by);
create index if not exists owner_pipeline_inspected_by_idx on owner_pipeline (inspected_by);
create index if not exists incorporation_referrals_updated_by_idx on incorporation_referrals (updated_by);
create index if not exists incorporation_affiliate_updated_by_idx on incorporation_affiliate (updated_by);
create index if not exists call_rooms_application_id_idx on call_rooms (application_id);
create index if not exists call_rooms_slot_id_idx on call_rooms (slot_id);
create index if not exists call_guest_links_slot_id_idx on call_guest_links (slot_id);
