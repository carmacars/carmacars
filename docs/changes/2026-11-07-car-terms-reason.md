# Raising a car's fees before the owner signs: the reason box shows, November 7, 2026

## 1. What was wrong

On an owner's Cars and terms, raising the Insurance Fee or the management fee of a car whose Vehicle Schedule is not
signed yet left **Save** greyed out. A higher amount needs a reason (the owner reads it, and `app.car_terms_change`
refuses a raise without one), but the Reason box was drawn only for signed cars.

## 2. Now

The Reason box shows whenever an amount goes up, signed or not (`web/src/features/owner-billing/CarTerms.tsx`). Saving
still needs the reason, as the database requires.

## Guides

No guide change: the guides already say a higher amount needs a reason.
