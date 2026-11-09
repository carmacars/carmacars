# Release 34: every current staff account is held by the academy (0842)

Migration `supabase/migrations/0842_r34_academy_gate_all_staff.sql`. SCHEMA_MARKER 0842.

The owner's rule: every staff account that exists is locked out of its work pages until it passes the academy, not
only people hired with one-step Hire.

- Each current staff member (Customer service, Sales, Fleet, Finance or field work; not an Admin, not a test account)
  who has not finished the academy gets gated enrollments from an Admin for every path of their functions, held from
  the deploy. They sign in to Welcome, the academy, the guide and their profile only, until they pass.
- A person an Admin already waived stays open (Take the waiver back holds them again).
- Each held person is written to the audit log.
- Test accounts are left out so the site checks keep running.

## Guides

- `admin/academy`: the gate holds every staff account until it passes, new hires and staff already working (regenerated
  into 0841 by `supabase/seed/0841_gen_guides.mjs`).
