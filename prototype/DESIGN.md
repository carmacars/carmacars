# CarmaCars design system

The production build copies these values exactly. The live source is `assets/css/tokens.css`; this file explains it. Every component below is rendered on `styleguide.html`.

## 1. Direction

Calm, confident and precise: the feel of a premium car maker's site, with a rental desk's honesty about prices. Three ideas hold it together:

1. **Black studio, real numbers.** Dark full-bleed photography up top, white working pages below with rates, fees and dates set as plain tables. Lots of air.
2. **Large, crisp, sentence-case type.** One family at two optical sizes. Headings are big and tightly tracked, never in capitals.
3. **The plate.** One decorative device, a small licence-plate label. It always carries a real identifier: a fleet number (`CC 03`) or a request number (`R-221704`).

The brand idea is karma: what goes around comes around. The tagline is "What goes around, drives around." It is used with restraint: the home hero, the footer, the owner band ("Good cars come back around."), the reviews heading ("Word gets around.") and the 404. Other headings sell the cars and the ease first and explain the request process second.

Left aligned throughout. No centred sections, no card grids of features, no gradients as decoration, no pills, no icons standing in for words.

## 2. Colour

Red, black, white and true neutral greys. No other hue anywhere, including status colours.

| Token | Hex | Use | Contrast |
| --- | --- | --- | --- |
| `--red-600` | `#D0111B` | CarmaCars red: primary button, selection, step numbers, links underline, focus ring | White on it 5.6:1. On white 5.6:1 |
| `--red-700` | `#A30C14` | Hover and pressed on red | White on it 8.0:1 |
| `--red-400` | `#FF4D52` | Red text and numerals on black | 6.4:1 on black |
| `--red-100` | `#FAD4D6` | Selected date range fill | |
| `--red-50` | `#FDEEEE` | Error alert surface | |
| `--black` | `#000000` | Header, footer, dark sections, text | |
| `--grey-950` | `#111111` | Raised surface on black | |
| `--grey-900` | `#1A1A1A` | | |
| `--grey-800` | `#2B2B2B` | Hairlines on black, button hover | |
| `--grey-700` | `#474747` | Tertiary text | 9.3:1 on white |
| `--grey-600` | `#5E5E5E` | Secondary text on white | 6.5:1 |
| `--grey-500` | `#7A7A7A` | Input borders, disabled text | |
| `--grey-400` | `#A3A3A3` | Secondary text on black | 8.3:1 |
| `--grey-300` | `#C9C9C9` | Option borders, hatch | |
| `--grey-200` | `#E2E2E2` | Hairlines on white | |
| `--grey-100` | `#F0F0F0` | Quiet surface (`.on-grey`, estimate panel) | |
| `--grey-50` | `#F7F7F7` | Portal background | |
| `--white` | `#FFFFFF` | Page | |

Surfaces are set with one class on a section: `.on-dark`, `.on-red`, `.on-grey`. Each redefines the semantic variables (`--text`, `--text-2`, `--line`, `--line-strong`, `--accent-text`) so components inside need no variants.

Status without colour: **solid red** = on rent or needs action now, **solid black** = confirmed, **hatched grey** = pending request, **outlined** = does not block (quote), **solid grey** = finished or service.

## 3. Type

| Role | Family | Self-hosted files | Licence |
| --- | --- | --- | --- |
| Headings, prices, wordmark | Inter Display 600, 700, 800 | `assets/fonts/inter-display-600.woff`, `-700`, `-800` | SIL Open Font License |
| Text and UI | Inter 400, 500, 600 | `assets/fonts/inter-400.woff`, `-500`, `-600` | SIL Open Font License |

Inter Display is the display optical size of Inter: the same design, drawn for large sizes, so headings and body share one voice. The files in `assets/fonts/` are Latin subsets (about 25 KB each). For production, re-export them as WOFF2 from the upstream release and keep the same family names.

```css
--font-display: "Inter Display", "Inter", "SF Pro Display", "Helvetica Neue", Helvetica, "Segoe UI", Roboto, Arial, sans-serif;
--font-text: "Inter", "Helvetica Neue", Helvetica, "Segoe UI", Roboto, Arial, sans-serif;
```

Scale. Display sizes are fluid between 375 and 1440 px wide.

| Class | Weight | Size | Line height | Tracking |
| --- | --- | --- | --- | --- |
| `.d-hero` | 700 | 38 to 96 px (`clamp(2.375rem, 1.1rem + 5.6vw, 6rem)`) | 1.0 | -0.034em |
| `.d1` | 700 | 36 to 72 px | 1.03 | -0.03em |
| `.d2` | 700 | 28 to 48 px | 1.08 | -0.025em |
| `.d3` | 600 | 22 to 28 px | 1.15 | -0.018em |
| `.d4` | 600 | 18 px | 1.25 | -0.012em |
| Prices and figures | 700 | 19 to 48 px by context | 1.05 | -0.02em to -0.035em |
| `.lead` | 400 | 17 to 20 px | 1.45 | 0 |
| body | 400 | 16 px | 1.55 | 0 |
| `.small` | 400 or 600 | 14 px | | |
| `.xs` | | 13 px | | |
| `.eyebrow` | 600 | 12 px, capitals | 1.2 | +0.14em |

Rules: every heading is sentence case. Capitals appear only in `.eyebrow` labels, the "Option 1" labels and plates, all 12 px or smaller with wide tracking. Tracking tightens as size grows and is never tighter than -0.035em. Prices and table figures use tabular numerals (`.num`). One `h1` per page.

### Wordmark and logo slot

The wordmark is the single word `CarmaCars` in Inter Display 800, upright, tracking -0.045em: "Carma" in the surface's text colour and "Cars" in `--red-600`. No bar, no slant, no symbol. Minimum height 18 px; clear space of one cap height.

It is a slot, not a fixed asset. If `logo.image` is set in site settings (Admin > Settings > Brand), every header, footer and style guide instance renders that image instead (`<img>` inside `.wordmark`, height 1.6em). `logo.imageOnDark` is used on black surfaces when present. The text wordmark is the fallback.

## 4. Space, grid and shape

- **Spacing scale (4 px base):** 4, 8, 12, 16, 24, 32, 48, 64, 96, 128 (`--s-1` to `--s-10`).
- **Gutter:** `clamp(1.25rem, 0.6rem + 2.8vw, 3rem)` (20 px on a phone, 48 px on desktop).
- **Section padding:** `clamp(4rem, 2.5rem + 6vw, 8.5rem)`.
- **Max content width:** 85 rem (1360 px). Photos and coloured bands run full bleed.
- **Grid:** one column on phones, 12 columns from 768 px with 32 px gaps (`.grid`, `.c-4` to `.c-8`, `.s-7`, `.s-8`). Layouts are deliberately uneven: 5/7, 4/8, 6/5 with an empty column.
- **Breakpoints:** 48 rem (768 px) and 64 rem (1024 px). Designed at 375, 768 and 1440.
- **Radii follow role:** `--r-0` 0 for photos, sections and tables; `--r-1` 4 px for plates, badges and calendar days; `--r-2` 6 px for buttons and inputs; `--r-3` 14 px for things that float (search panel, sheets, modals, toasts).
- **Borders:** 1.5 px (`--bw`) for strong rules and controls, 1 px for hairlines.
- **Shadow:** only on floating things (`--shadow-float`) and the sticky bar (`--shadow-bar`). Cards have none.

## 5. Motion

| Token | Value | Use |
| --- | --- | --- |
| `--t-1` | 120 ms | Hover and press |
| `--t-2` | 220 ms | Menus, tabs, toggles |
| `--t-3` | 420 ms | Sheets, modals, step bar |
| `--t-4` | 800 ms | Image reveals (fallback only) |
| `--ease` | `cubic-bezier(0.2, 0.7, 0.1, 1)` | Anything a person triggers |

Scroll effects use CSS scroll-driven animations (`animation-timeline: view()` and `scroll()`), linear, with an IntersectionObserver fallback that adds `.is-in` once.

| Class or element | Effect |
| --- | --- |
| `.hero__media img`, `.hero__copy` | Hero photo scales to 1.12 and dims over the first 90 vh; copy lifts 28 px |
| `.fx-drift` | Photo band drifts 7% against the scroll (parallax) |
| `.fx-wipe` | Photo wipes in top to bottom while settling from 1.14 to 1 |
| `.fx-grow-y` | The red line beside numbered steps draws as the list scrolls |
| `.rail` + `.rail-progress` | Horizontal fleet rail with scroll snap; the bar tracks a named scroll timeline |
| `.gallery__track` | Native scroll snap between photos; buttons and thumbnails scroll it |
| `.bookbar` | Sticky Request to book bar slides up after the car header leaves, hides while the estimate button is on screen |
| `CC.tween` | Estimate total counts to its new value in 380 ms |

Rules: only `transform`, `opacity` and `clip-path` animate. No scroll hijacking. Every image has `width` and `height`, so nothing shifts. `prefers-reduced-motion: reduce` turns all of it off.

## 6. Components

Class names are stable; copy the CSS from `assets/css/core.css`.

| Component | Class | Spec |
| --- | --- | --- |
| Button | `.btn` + `--primary`, `--light`, `--ghost`, `--quiet`; sizes `--sm` 40 px, default 48 px, `--lg` 56 px; `--block` | 600 weight, 6 px radius, 1.5 px border. One red button per view. Disabled is grey-200 on grey-600 |
| Icon button | `.icon-btn` | 44 px square, outlined |
| Text link | `.link`, `.link--go` | Underline in red, thickens on hover. `--go` adds an arrow that slides 4 px |
| Plate | `.plate`, `--dark`, `--lg` | Inter 700, 12 px capitals, 0.1em tracking, 2 px border, 4 px radius, red dot |
| Badge | `.badge`, `--red`, `--outline`, `--grey`, `--hatch` | 12 px semibold, rectangular |
| Input, select, textarea | `.field` > `.label` + `.input` / `.select` / `.textarea` + `.hint` + `.error` | 50 px tall, grey-500 border, black on hover, red ring on focus. `.has-error` and `.is-ok` states |
| Checkbox, radio | `.check`, `.radio` | 24 px, red when on |
| Option card | `.option` | Whole card is the hit area, 1.5 px black inset when chosen |
| Segmented control | `.seg` | Radio group, black selected segment |
| Switch | `.switch` | 44 by 26 px |
| Range | `.range` | 4 px track, 24 px thumb |
| Quantity | `.qty` | Minus, value, plus; 44 px buttons |
| Date range field | `[data-daterange]` | Two `.datefield` buttons open one `.popover` calendar; a bottom sheet under 704 px |
| Calendar | `.cal` (`CC.Calendar`) | 44 px day cells, `role="grid"`, arrow keys, Page Up and Down, Home, End. States: today dot, start and end red, range red-100, unavailable hatched and struck |
| Car card | `.car-card` | 3:2 photo, plate bottom left, name and price in Inter Display 700 at 21 px, spec line. No box, no shadow |
| Spec table | `.spec` | Label 42% in grey, value medium weight, hairlines, black top rule |
| Data table | `.data`, `.data--dense` | 14 px, header 13 px, right-aligned numerals with `.r`. Wrap in `.table-scroll` |
| Alert | `.alert`, `--ok`, `--warn`, `--error` | 4 px left bar, round glyph. Only errors are red |
| Tabs | `.tabs` > `.tab` + `.tabpanel` | Red 3 px underline slides in |
| Accordion | `.faq` > `details` | Plus rotates to a cross |
| Modal | `dialog.modal`, `--sheet` | Native dialog, 14 px radius, sheet on phones |
| Toast | `.toast` via `CC.toast()` | Black, red left bar, 4.5 s |
| Step indicator | `.steps` | 4 px bars: done black, current red, labels below |
| Numbered sequence | `.seq` | Red Inter Display numerals, used only for real sequences |
| Skeleton | `.skeleton`, `.sk-img`, `.sk-title`, `.sk-line` | Grey-200 with a shimmer |
| Breadcrumbs | `.crumbs` | 13 px, slash separators |
| Sticky bar | `.bookbar` | Fixed bottom, price left, button right |
| Prototype note | `.proto-note`, `.tbc` | Dashed outline. Marks sample data and blanks. Remove for launch |

Portal patterns (bottom of `styleguide.html`): a dense bookings table with a detail side panel, and the fleet master calendar (`.mc`): vehicles down a sticky first column, days across, bookings as bars in the status styles from section 2.

## 7. Accessibility

- Semantic landmarks, one `h1`, skip link, `lang="en-CA"`.
- Focus: 3 px red outline with 3 px offset, white on dark and red surfaces. Inputs use a white and red ring.
- All text passes WCAG AA against its surface (checked by `tools/a11y.mjs`).
- Menu: a button with `aria-expanded`; Escape closes; the panel is `inert` when closed.
- Date picker and calendar are fully keyboard usable; every day has a spoken label that includes its state.
- Errors are text, tied to the field with `aria-describedby`, and say how to fix the problem.
- Touch targets are 44 px or more.

## 8. Admin-editable content

Nothing a renter or owner reads is typed into a page template. The prototype reads it from three data files that stand in for the admin portal; the production build reads the same fields from the database. Templates use tokens such as `{{deductible}}`, and the build fails if a token is unknown or left unfilled.

| Field | Prototype source | Admin screen that will own it |
| --- | --- | --- |
| Brand name | `site.mjs` `brand` | Settings > Brand |
| Tagline | `site.mjs` `tagline` | Settings > Brand |
| Logo image, dark-surface logo, alt text | `site.mjs` `logo` (text wordmark when empty) | Settings > Brand |
| City, region, service area | `site.mjs` `city`, `region`, `serviceArea` | Settings > Locations |
| Delivery area, airport delivery | `site.mjs` `deliveryArea`, `airportDelivery` | Settings > Locations |
| Email, phone, WhatsApp, 24-hour line | `site.mjs` `email`, `phone`, `whatsapp`, `roadsideLine` | Settings > Contact |
| Address, opening hours | `site.mjs` `address`, `hours` | Settings > Contact |
| Social links | `site.mjs` `social` | Settings > Contact |
| Reply-time wording | `site.mjs` `replyWording` | Settings > Contact |
| Review source | `site.mjs` `reviewSource` | Settings > Reviews |
| Reviews | none yet (empty state) | Reviews |
| Cars: year, make, model, trim, class, body, colour, seats, doors, transmission, drive, fuel, consumption, luggage, features, description, fleet number | `data.mjs` `CARS` | Fleet > Vehicle |
| Daily, weekend, weekly and monthly rates | `data.mjs` `CARS[].rates` | Fleet > Vehicle > Rates |
| Kilometres per day, overage rate | `data.mjs` `CARS[].kmPerDay`, `overage` | Fleet > Vehicle > Rates |
| Delivery and pickup fee per car | `data.mjs` `CARS[].delivery` | Fleet > Vehicle > Rates |
| Open to drivers 18 to 20 | `data.mjs` `CARS[].young` | Fleet > Vehicle |
| Booked and pending dates | `data.mjs` `CARS[].booked`, `pending` | Bookings (computed) |
| Featured cars on the home page | `data.mjs` `FEATURED` | Fleet > Featured |
| Car photos and alt text | `assets/photos.json` `cars` | Fleet > Vehicle > Photos |
| Scene photos and alt text | `assets/photos.json` `slots` | Settings > Site photos |
| Deposit by class | `data.mjs` `RULES.depositByClass` | Pricing > Deposits |
| Deposit hold limit, release time, hold-back time | `RULES.depositHoldMaxDays`, `depositReleaseBusinessDays`, `depositHoldbackDays` | Pricing > Deposits |
| HST rate | `RULES.hst` | Pricing > Tax |
| Young driver fees and caps | `RULES.youngDriver` | Pricing > Fees |
| Additional driver, winter tire, baby seat fees and caps | `RULES.additionalDriver`, `winterTire`, `babySeat` | Pricing > Fees |
| Delivery fee range | `RULES.deliveryRange` | Pricing > Fees |
| Overage rates (standard, luxury) | `RULES.overage` | Pricing > Fees |
| Late return grace and hourly fee | `RULES.lateReturn` | Pricing > Fees |
| Fuel and recharging fees | `RULES.fuel` | Pricing > Fees |
| Cleaning, pet, smoking fees | `RULES.cleaning` | Pricing > Fees |
| Lost key, toll, ticket, declined payment fees | `RULES.lostKeyFee`, `tollFee`, `ticketFee`, `declinedPaymentFee` | Pricing > Fees |
| Deductible and administration fees | `RULES.deductible`, `adminFee` | Pricing > Damage |
| Non-refundable discount | `RULES.nonRefundableDiscount` | Pricing > Booking types |
| Cancellation tiers (hours and percentages), refund time | `RULES.cancellation`, `refundBusinessDays` | Policies > Cancellation |
| Longest booking, weekly-rate threshold | `RULES.maxDays`, `weeklyFromDays` | Policies > Booking |
| Minimum age, standard age, no-fee age, licence classes | `RULES.minAge`, `standardMinAge`, `noFeeAge`, `licence` | Policies > Drivers |
| Offer validity, verification deadline, accident reporting times | `RULES.offerOpenHours`, `verifyHoursBeforePickup`, `accidentCallHours`, `accidentReportHours`, `hiddenDamageHours` | Policies > Booking |
| Owner program: payout day, billing day, notice, referral rate, reply and listing times | `RULES.owner` | Owners > Program settings |
| Terms, privacy and cancellation text | `docs/source/website_terms_policies.md` | Settings > Legal pages |
| Prototype clock | `data.mjs` `PROTO_TODAY` | not in production |

Still written in templates as copy rather than data: headings, explanatory sentences and FAQ wording (the numbers inside them are tokens). In production these belong to a content screen (Settings > Site copy) if the owner wants to edit them without a deploy.

## 9. Files and how to run it

```
prototype/
  index.html, fleet.html, car-<make>-<model>.html (12), request.html, confirmation.html,
  owners.html, how-it-works.html, requirements.html, delivery.html, faq.html, contact.html,
  terms.html, privacy.html, cancellation.html, signin.html, 404.html, styleguide.html
  assets/css/tokens.css, core.css, pages.css
  assets/js/app.js (core + components), pages.js (page behaviour), fleet-data.js (generated)
  assets/fonts/, assets/photos/, assets/photos.json, assets/data/fleet.json
  dist/carmacars-prototype.html      one file, no external requests, hash routing
  tools/                             build and check scripts (Node, no dependencies)
  shots/                             screenshots
```

```bash
node tools/serve.mjs                 # http://localhost:4173/
node tools/build.mjs                 # regenerate pages, fleet data and the single file
node tools/make-standins.mjs         # redraw stand-in photos (keeps real ones)
node tools/linkcheck.mjs             # links, anchors, h1, titles, alt text, JSON-LD
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node tools/flows.mjs        # behaviour checks
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node tools/a11y.mjs         # contrast, labels, focus
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node tools/verify-dist.mjs  # single file: requests, errors, links
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node tools/shots.mjs        # screenshots at 375 and 1440
```

The page files are plain HTML. `tools/build.mjs` only stamps the shared header, footer, fleet data and photo manifest into them from `tools/src/`, so the 28 pages cannot drift apart. Open the page files through `tools/serve.mjs` (browsers block web fonts on `file://`); the single file in `dist/` opens straight from disk.

Sample cars live in `tools/src/data.mjs` and are marked as sample. Policy numbers and fees are in `RULES` in the same file, taken from `docs/source/renter_billing_spec.md`; site settings are in `tools/src/site.mjs`. `CC.pricing` in `assets/js/app.js` holds only the rate rule's logic and reads every number from those files. Legal pages are rendered from `docs/source/website_terms_policies.md` at build time.
