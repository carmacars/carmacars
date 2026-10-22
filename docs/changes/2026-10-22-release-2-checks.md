# Release 2: the full suite (October 22, 2026)

## What changed

- The car page lists no "Dates and price" link under On this page for a car that is not taking requests: it has no booking box, so the #dates anchor is missing (from the maintenance branch; the link check failure on main).
- The local stand-in for the AI writer (`web/src/integrations/llm/fake.ts`) writes a car's intro from three short sentences picked from separate lists. With one pick from five sentences, the end-to-end site (dozens of cars) soon had no intro left that did not repeat another car's, so new cars kept their plain copy. The stand-in for the chat assistant quotes the car on the visitor's page when several cars share the name (since 0087 a car added by hand goes live at once). Neither runs on the live site.
- End to end: the rates form's "Add a rental for a car whose listing is not finished" takes back the rate card and the publishing 0087 now gives a car added without rates.
- Suite 56: the late-night visit is put back in the past after its checks, so the job test passes just after local midnight.
- CI: the full job may run 100 minutes (the release 2 end-to-end suite runs about 45).

## Guides

No guide change: nothing a person sees or does changes, apart from a link that led nowhere.
