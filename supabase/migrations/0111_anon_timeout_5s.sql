-- 0111: a visitor's read may take 5 s (0106 set 2.5 s).
-- On the Micro database under a crawl, ordinary page reads (seo_links, site_facts, place_hub, seo_page) sometimes take
-- 2.4 to 3 s; at 2.5 s they were cancelled and the page answered the busy page (Worker errors, Oct 23 00:00). 5 s keeps a
-- stuck read from piling up while letting a slow moment pass; the website gives up after 6 s (ANON_DEADLINE_MS).
alter role anon set statement_timeout = '5s';
