# The insurer gate on handovers is a setting, off by default (0683)

Hotfix (owner, November 7). A car not marked "Insurer confirmed" could not be checked out: every pickup of a newer car
was refused ("This car is not on the fleet insurance policy yet") while the company works the newer cars through with
its insurer.

- Settings > Program > Field jobs and handovers: "Refuse the pickup of a car not on the fleet insurance policy",
  off by default. Off: the car is handed over like any other. On: the rule of 0078 applies unchanged.
- Nothing else changes: requests and offers for such a car still show the "Not on the fleet insurance policy yet"
  warning, the car's checklist still lists the insurer step, and a car out on rent without it still raises the urgent
  Admin task.

Checks: `supabase/tests/99_handover_policy_switch.sql`.

## Guides

No guide change: the guides describe the insurer step; the setting is described in Settings itself.
