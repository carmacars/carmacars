# Quo calls with decimal durations (hotfix)

Quo began sending some call durations with decimals (54.678912). The database keeps whole seconds, so those
deliveries failed ("invalid input syntax for type integer") and Quo retried them: calls and voicemails stopped reaching
the phone inbox. The webhook now rounds every duration to whole seconds before it is recorded.

## Guides
No guide change: nothing on any screen changes.
