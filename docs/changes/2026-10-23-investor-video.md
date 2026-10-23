# The investor deck's narrated video (October 23, 2026)

The owner, October 23, 2026: "generate a video using claude for the investor page, not to replace the deck but in
addition to the deck (goes over the entire deck with animations and sound and voiceover and transitions) throw it on the
investor page right above the deck".

## What it is

- **The deck, narrated.** One scene per deck slide, in the deck's order; each feature group is one scene that shows the
  group's opening slide and every one of its feature slides. The slides are the deck's own: `Deck.tsx` rendered with the
  same `app.deck_figures()` and the deck's styles, fonts and screens, animated by a frame clock (pieces rise in, numbers
  count up, bars grow, screens drift) with fade, slide and zoom transitions between scenes. 1920x1080 at 30 fps.
- **The script** is `docs/investor-video/script.md` (the source the build reads). Every `{{number}}` is filled from the
  deck's figures with the deck's formulas, and the build stops if a value is not on the deck as rendered. The deck's
  rules hold: no internal costs, fleet size or car count; the 3.2x as CarmaCars' figure with its footnote; no numbered
  company name; no long dashes.
- **Sound**: the narration by Cloudflare Workers AI text to speech (Deepgram Aura 2), a soft pad synthesized in ffmpeg
  (no recorded music) ducked under the voice, and synthesized whooshes at the transitions; -16 LUFS. Captions (WebVTT)
  are the script's words, timed to the voice.
- **Where**: `/investor/deck` and the Admin's preview (`/admin/investors/deck`), above the deck: a 16:9 player with the
  poster, captions, controls, no autoplay, `preload="metadata"`. Hidden when printing the deck.
- **Private files**: the deck has no public version, so the files are in the private Supabase Storage bucket
  `investor-media` (folder `deck-video`), and the page signs links valid 6 hours on each visit, after its own access
  check. No video and no reserved space when the files are not there. The content security policy allows media from
  Supabase Storage (`media-src`).
- **Made by** `.github/workflows/investor-video.yml` (on a push to the `investorvideo` branch, by hand, and on the 1st
  of each month once on the default branch, so its figures and dates follow the deck). It reads the figures (read only),
  renders, checks (a 12-frame contact sheet, loudness and audio levels, sizes, duration) and uploads. Nothing is written
  to the database. A changed figure in Admin > Investors > Deck reaches the video on the next run.

## Guides

No guide change: the video sits above the deck the investor guide already describes; the deck's steps do not change.
