-- 1102_r35m_01_motors_terms.sql
-- Release 35, part M (docs/changes/2026-11-08-r35-seo-depth.md, section F): 01 Motors as a comparison set, the way
-- 0522 added Turo: "01 Motors Alternative in <place>" (a place page per place), the vehicle twins of the term ("01 Motors
-- alternative: 2022 Toyota Camry", /t/01-motors-alternative/...), and the versus pages "CarmaCars vs 01 Motors in
-- <place>" (place pages only: a versus term has no vehicle tree).
-- Factual and fair: 01 Motors is named only as what the searcher compared; nothing is said about its prices, rules or
-- service; no logo. 01 Motors is a partner whose cars are listed on this site (0093), so these pages never say
-- CarmaCars is unaffiliated with it: they say the page is written by CarmaCars, not by 01 Motors, which is true either
-- way. The versus pages show CarmaCars' own facts (web/src/features/seo/depth.ts, the comparison section) and ask the
-- reader to check the other company's terms with it.
-- No applied migration is edited.

insert into place_terms (slug, vertical, phrase, title, match, served, landing_slug, intent_note, faq, sort_order) values
  ('01-motors-alternative', 'rental', '01 Motors alternative', '01 Motors Alternative', '{}', 'yes', null,
   'Rent from CarmaCars on this site: every car shows its photos, calendar, daily, weekly and monthly rates, deposit and kilometres included. Send a request with no payment, and pay only once we confirm the car and the full price. 01 Motors is named only to describe what you compared; this page is written by CarmaCars, not by 01 Motors.',
   '[{"question": "Is this page from 01 Motors?", "answer": "No. This page is written by CarmaCars. You book with CarmaCars on this site, and CarmaCars handles the rental agreement, the deposit and support."}, {"question": "Do I pay when I send a request?", "answer": "No. You pay only after we confirm the car and the price and you approve the offer."}]', 930),
  ('carmacars-vs-01-motors', 'rental', 'CarmaCars vs 01 Motors', 'CarmaCars vs 01 Motors', '{}', 'yes', null,
   'What renting from CarmaCars involves, in figures from this site: the rates, the deposit, the kilometres included, the delivery fee, the age and licence rules and the coverage options. We do not publish another company''s prices or terms: check them with 01 Motors before you compare.',
   '[{"question": "Is this page from 01 Motors?", "answer": "No. This page is written by CarmaCars and gives CarmaCars'' own figures only."}, {"question": "Where do I find 01 Motors'' prices and terms?", "answer": "With 01 Motors. We do not publish another company''s prices or terms."}]', 940)
on conflict (slug) do update set phrase = excluded.phrase, title = excluded.title, intent_note = excluded.intent_note, faq = excluded.faq,
  served = excluded.served, sort_order = excluded.sort_order, is_active = true;

-- a versus term has place pages only (no vehicle tree: "CarmaCars vs 01 Motors: 2022 Toyota Camry" says nothing true)
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception 'patch_fn: text not found in %', p_sig; end if;
  execute replace(d, p_old, p_new);
end $$;
select pg_temp.patch_fn('app.vpage_terms()'::regprocedure, $o$t.slug <> 'car-rental' order by$o$, $n$t.slug <> 'car-rental' and t.slug !~ '-vs-' order by$n$);
