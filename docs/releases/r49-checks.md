---
release: r49-checks
title: Release 49
date: 2026-11-23
summary: Automatic checks that every event has its message and the guides match the app, a booking's documents list no longer shows removed files, and an Android test build.
changes:
  - 2026-11-23-r49-checks.md
---

## Staff tools

- Sales are told when a website request has had no reply for 30 minutes, and the Admins at 2 hours
- Finance gets a daily list of overdue renter balances with booking links, a To do for the Admins per balance overdue 3 days, and a notice for every refund paid or failed
- A booking's documents list no longer shows documents that were removed or replaced, so none opens an error page

## For owners

- Owners are told once when their car is 2 hours late coming back

## Reliability & security

- An automatic check on every change makes sure each event reaches every portal it touches, with its email template in place
- The user guides and the academy are checked against the app on every change: a page, button or setting that no longer exists fails the build
- An installable Android test build can be made on demand, without any store
