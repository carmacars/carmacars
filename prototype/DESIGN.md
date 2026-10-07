# CarmaCars design system

The production build copies these values exactly. The live source is `assets/css/tokens.css`; this file explains it. Every component below is rendered on `styleguide.html`.

## 1. Direction

A car rental site that reads like a car maker's site, with a rental desk's honesty about prices. Three ideas hold it together:

1. **Black studio, real numbers.** Dark full-bleed photography up top, white working pages below with rates, fees and dates set as plain tables.
2. **The plate.** One decorative device, a licence-plate label. It always carries a real identifier: a fleet number (`CC 03`) or a request number (`R-221704`). Nothing else on the site is decorated.
3. **Condensed display, calm text.** Tall condensed capitals for headings and prices. Everything else is sentence case at reading size.

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

| Role | Family | Self-hosted file | Licence |
| --- | --- | --- | --- |
| Display | TeX Gyre Heros Condensed Bold (a Helvetica Condensed design) | `assets/fonts/heros-cn-bold.woff` | GUST Font License |
| Wordmark | TeX Gyre Heros Condensed Bold Italic | `assets/fonts/heros-cn-bolditalic.woff` | GUST Font License |
| Text and UI | Inter 400, 500, 600 | `assets/fonts/inter-400.woff`, `-500`, `-600` | SIL Open Font License |

Both families are free to self-host. The files in `assets/fonts/` are Latin subsets cut from the full fonts (15 to 28 KB each). For production, re-export them as WOFF2 from the upstream sources and keep the same family names.

Fallback stacks, matched for width so nothing reflows while fonts load:

```css
--font-display: "Heros Condensed", "HelveticaNeue-CondensedBold", "Helvetica Neue Condensed", "Arial Narrow", "Roboto Condensed", "Liberation Sans Narrow", sans-serif-condensed, Impact, sans-serif;
--font-text: "Inter", "Helvetica Neue", Helvetica, "Segoe UI", Roboto, Arial, sans-serif;
```

Scale. Display sizes are fluid between 375 and 1440 px wide.

| Class | Size | Line height | Notes |
| --- | --- | --- | --- |
| `.d-hero` | 52 to 108 px (`clamp(3.25rem, 1.6rem + 6.6vw, 6.75rem)`) | 0.86 | Home hero only |
| `.d1` | 44 to 96 px | 0.92 | Page titles, section openers |
| `.d2` | 34 to 64 px | 0.92 | Section headings |
| `.d3` | 26 to 36 px | 1.0 | Sub-sections, card titles |
| `.d4` | 22 px | 1.05 | Small headings |
| `.lead` | 17 to 20 px | 1.45 | Max 38 em |
| body | 16 px | 1.55 | Max 42 em for running text |
| `.small` | 14 px | | Labels are 14 px semibold |
| `.xs` | 13 px | | Hints, table headers |
| 2xs | 12 px | | Calendar weekdays, badges |

Rules: display type is uppercase with -0.005em tracking. All other text is sentence case. Labels are never tracked capitals. Prices and table figures use tabular numerals (`.num`). One `h1` per page.

### Wordmark

Always the exact string `CarmaCars`, set in the bold italic condensed face with -0.01em tracking: "Carma" in the surface's text colour, "Cars" in `--red-600`, followed by a short slanted red bar that sits on the baseline like a lane marking. Minimum height 20 px. Clear space of one cap height on all sides. Markup: `<a class="wordmark">Carma<b>Cars</b></a>`. No logo file is needed.

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
| Plate | `.plate`, `--dark`, `--lg` | Condensed bold, 0.09em tracking, 2 px border, 4 px radius, red dot |
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
| Car card | `.car-card` | 3:2 photo, plate bottom left, name and price in display type, spec line. No box, no shadow |
| Spec table | `.spec` | Label 42% in grey, value medium weight, hairlines, black top rule |
| Data table | `.data`, `.data--dense` | 14 px, header 13 px, right-aligned numerals with `.r`. Wrap in `.table-scroll` |
| Alert | `.alert`, `--ok`, `--warn`, `--error` | 4 px left bar, round glyph. Only errors are red |
| Tabs | `.tabs` > `.tab` + `.tabpanel` | Red 3 px underline slides in |
| Accordion | `.faq` > `details` | Plus rotates to a cross |
| Modal | `dialog.modal`, `--sheet` | Native dialog, 14 px radius, sheet on phones |
| Toast | `.toast` via `CC.toast()` | Black, red left bar, 4.5 s |
| Step indicator | `.steps` | 4 px bars: done black, current red, labels below |
| Numbered sequence | `.seq` | Red condensed numerals, used only for real sequences |
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

## 8. Files and how to run it

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

Sample data lives in one place, `tools/src/data.mjs`, and is marked as sample. Business rules (rate rule, fees, deposits, age bands, HST, 30 day limit) are in `RULES` there and in `CC.pricing` in `assets/js/app.js`, taken from `docs/source/renter_billing_spec.md`. Legal pages are rendered from `docs/source/website_terms_policies.md` at build time.
