# The Canada agreements To do leaves out test accounts (Release 46: 2880)

Migration `2880_r46b_canada_todo_test_accounts.sql`.

The Admin To do "Send N staff in Canada a new agreement with Canadian terms" (2862) and the badge **Lives in Canada: needs the Canadian terms** in Settings > Staff, Staff agreements listed the live checks' test accounts ("Verify Invitation").

- `app.staff_agreement_needs_canada` leaves out every account `app.staff_is_test` names (users.is_test, verify- and +verify- addresses, resend.dev, Site settings' admin test addresses). The badge, the To do and its closing rule read it.
- **Once**: the open To do is written again from the real staff only (the count in its title, their names in its detail), or closed when nobody real is left.
- Test: `supabase/tests/99_r46b_canada_todo_test_accounts.sql`.

## Guides

No guide change: the guide says the To do lists the staff in Canada on the old terms; test accounts were never meant to be in it.
