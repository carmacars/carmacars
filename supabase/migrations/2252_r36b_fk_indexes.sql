-- 2252: an index on every join-path foreign key of the r36b tables (99_r35sec's rule).
create index if not exists listing_angle_makes_shot_type_idx on listing_angle_makes (shot_type);
create index if not exists listing_angle_makes_job_id_idx on listing_angle_makes (job_id);
create index if not exists social_videos_created_by_idx on social_videos (created_by);
create index if not exists social_queue_video_id_idx on social_queue (video_id);
create index if not exists social_queue_draft_id_idx on social_queue (draft_id);
create index if not exists social_queue_vehicle_id_idx on social_queue (vehicle_id);
create index if not exists social_queue_created_by_idx on social_queue (created_by);
create index if not exists social_queue_posted_by_idx on social_queue (posted_by);
create index if not exists social_post_log_by_user_idx on social_post_log (by_user);
