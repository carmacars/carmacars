-- 0101: the "about to leave the page" game trigger is back on (the owner, October 22, 2026). 0100 turned exit intent
-- off, live and as the default; the owner wants it on. It stays an Admin setting (Admin > Settings > Program,
-- Discount games: "Also when the mouse heads for the tabs"), now on by default and on in every settings row.
alter table program_settings alter column game_exit_intent set default true;
update program_settings set game_exit_intent = true where not game_exit_intent;
comment on column program_settings.game_exit_intent is 'Discount games (0101): also when the mouse heads for the tabs on a computer (on by default; 0100 had turned it off).';
