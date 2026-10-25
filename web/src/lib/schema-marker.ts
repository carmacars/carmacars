// The newest migration this website was built for (migration 0118). Every response carries it (custom-worker.ts,
// header x-carmacars-schema) and /api/health returns it, so the site check in the database can tell a website that is
// older than the database (waiting for its deploy) from a broken one. schema-marker.test.ts fails until this is the
// highest migration number in ../supabase/migrations: raise it with each new migration.
export const SCHEMA_MARKER = '0156';
export const SCHEMA_HEADER = 'x-carmacars-schema';
