# The greeting on Admin > To do: "Abbas and Mahad" (0324)

The owners share one Admin login (rent@carmacars.ca, named "CarmaCars Admin"), so To do greeted "Good morning, CarmaCars".

- **Settings > My profile** (new): the greeting name of the signed-in Admin (`users.greeting_name`, at most 60
  characters). To do greets it whole ("Good morning, Abbas and Mahad"); empty, the first word of the account's name as
  before (web/src/features/admin/today/greeting.ts).
- The staff assistant uses the same name: its panel opens with "Hi Abbas and Mahad." and the assistant is given that name.
- `app.my_roles` and `app.admin_gate` carry it as `greeting`.
- The migration sets "Abbas and Mahad" on the Admin account rent@carmacars.ca (the business address in
  docs/email-aliases.md) only where it has no greeting name yet.

## Tests

- DB: `supabase/tests/99_owner_todo_usage_noise.sql` section 10 (none: the account's name; saved, trimmed, carried by the
  gate and the roles; emptied; at most 60 characters; Admins only).
- Unit: `web/src/features/admin/today/greeting.test.ts`.

## Guides

- `admin/settings`: My profile, the greeting name.
