# Every class picker reads the real class list (0233)

The owner: Settings > Fee defaults offered Economy, Standard, Premium, Luxury and Exotic, but the site has 11 classes.

- The single-class columns (a car's pricing class, fee defaults, required shots, service rules, class rules) are the
  enum `vehicle_class`, which had six classes. It now has every class of Settings > Vehicle classes, and a class added
  there is added to it (a code renamed is renamed).
- A fee default for a class applies to the cars of that pricing class, as before; a car can now be priced as any class
  (a default for Van applies to a car priced as a Van).
- The pickers read the list: Settings > Fee defaults, a car's Deposit class (Cars, the car), Add a car (the VIN entry),
  Settings > Maintenance and Settings > Class rules (in the list's order, with its labels).
- Tests: `supabase/tests/99_release_23.sql` section 7.

## Guides

No guide change: the pickers work the same way, with every class.
