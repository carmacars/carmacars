# Usage on our own server, and every update with a WHERE clause (migration 0194)

- Settings > Usage: the database and file storage are on our own server, not a Supabase plan. They are now called
  "Database size (our server)" and "File storage (our server)". Near the allowance the advice is to clean up or move to a
  larger server disk; nothing is billed by use. The "Measured by" lines say where each figure comes from.
- "Data sent out (Supabase egress)" is retired: it is not measured on our server. It no longer shows on Settings > Usage
  and its open alerts are closed.
- Allowances an Admin set are kept. Only the old Supabase Free defaults (500 MB database, 1 GB files) become 8 GB and 20 GB.
  The import size setting (Vehicle pages) no longer changes the database allowance.
- The usage alert email: the "If you allow paid usage" line is now "Cost or next step", and its description no longer
  names Supabase.
- The server refuses an UPDATE or DELETE without a WHERE clause (pg_safeupdate). The IndexNow sweep and twelve other
  functions (Google reviews sync, ads job, social publishing, sitemap shape, settings saves of one-row tables, Sales
  availability) did that and failed there. Each now has an explicit WHERE. A database test reads every function so
  none can come back (pg_safeupdate itself is not loaded in the tests).

## Guides
- `admin/usage-and-paid-usage`: Change the allowance after a plan or disk change; the database and storage are our server's.
