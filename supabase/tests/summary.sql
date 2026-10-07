select format('%-22s %4s passed %4s failed', suite, count(*) filter (where passed), count(*) filter (where not passed))
  from test.results group by suite order by suite;
select format('%-22s %4s passed %4s failed', 'TOTAL', count(*) filter (where passed), count(*) filter (where not passed)) from test.results;
select 'FAILED: [' || suite || '] ' || name || coalesce(' -- ' || detail, '') from test.results where not passed order by id;
