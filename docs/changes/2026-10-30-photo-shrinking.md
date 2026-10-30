# Smaller photos before upload

- Photos are made smaller in the browser before they are sent, to save storage: listing photos, condition and handover
  photos, field reports and checklists are at most 2048 px on the long side (JPEG, quality 80). Before: 2400 px or
  3000 px at a higher quality.
- Licence and selfie photos taken by staff (Sign now, and the field fixes) are at most 2560 px (quality 85) so the card
  stays readable. Sign now sent them at full size before.
- Each photo is drawn upright and saved without the camera's data (location, device). PDFs and other documents are sent
  exactly as chosen. One helper does it (web/src/lib/image-shrink.ts), with unit tests.

## Guides
No guide change: taking and sending photos works the same way.
