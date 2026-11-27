-- 5140 (R50 hotfix 2, docs/changes/2026-11-27-r50-hotfix2-ops.md): 407 ETR statements read right.
-- What went wrong (the owner, Nov 27: "super broken, especially for 407"): the reader took each statement line as text and
-- guessed its values from their place on the line. A distance printed without "km" was read as money, the line's amount
-- was its last number and its fees the last less the first (wrong when a line has a toll, a camera charge, a trip toll
-- charge and a total), a plate printed once above its trips was never given to them, the CSV download's account details
-- above the header row were taken as the header, a plate written with its province ("ABCD123 ON") did not match the car,
-- and the CSV amount left the fees out while the PDF amount had them in.
-- Now (web/src/features/tolls/parse.ts): a statement is read as a table, each value from the column its header names
-- (5140's readTable and autoMap, with unit tests on the 407 PDF and CSV shapes). This migration gives the 407 ETR reading
-- profile the words of those layouts: the plate headings and the statement charges that are not trips. An Admin's own
-- words in the profile are kept; these are added to them.
-- No applied migration is edited. SCHEMA_MARKER 5140.

update toll_import_profiles p
   set rules = jsonb_set(jsonb_set(jsonb_set(p.rules,
         '{fields,plate}', to_jsonb(array(select distinct x from unnest(coalesce((select array_agg(e) from jsonb_array_elements_text(p.rules #> '{fields,plate}') e), '{}')
                                                                  || array['Licence Plate', 'License Plate', 'Plate Number', 'Plate']) x order by x))),
         '{trip,statement_fee_words}', to_jsonb(array(select distinct x from unnest(coalesce((select array_agg(e) from jsonb_array_elements_text(p.rules #> '{trip,statement_fee_words}') e), '{}')
                                                                  || array['Account Fee', 'Monthly Account Fee', 'Statement Fee', 'Late Payment', 'Late Payment Charge', 'NSF', 'Interest Charge']) x order by x))),
         '{detect}', to_jsonb(array(select distinct x from unnest(coalesce((select array_agg(e) from jsonb_array_elements_text(p.rules -> 'detect') e), '{}')
                                                     || array['407 ETR', '407etr', 'Express Toll Route', '407etr.com']) x order by x)))
 where p.operator = '407 ETR' and p.source = 'pdf_text';
