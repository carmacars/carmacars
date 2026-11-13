-- 2771 (release 43): the Call helper's "updated by" column clears itself when that person is removed (on delete set
-- null), so the delete looks the rows up by it: give it an index, as every such foreign key has (99_r35sec_security).
create index if not exists call_helper_items_updated_by_idx on app.call_helper_items (updated_by);
