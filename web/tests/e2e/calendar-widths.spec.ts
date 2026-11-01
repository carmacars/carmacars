import { expect, test, type Page } from '@playwright/test';
import { acceptCookies, noOverflow, watch } from './helpers';

// The date picker at every width the owner uses (2026-11-06, docs/changes/2026-11-06-stale-chunks-car-card-photos.md):
// the car page's calendar (one month, the days already booked crossed out: the full availability) and the request's
// two-month calendar, at 375 and from 1024 to 1280. Each shows this month in Toronto, its header on one line, seven
// numbered days a row inside its box, and nothing wider than the window.
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const thisMonth = () => {
  const [y, m] = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit' }).format(new Date()).split('-');
  return { name: MONTHS[Number(m) - 1]!, year: y! };
};

async function checkCalendar(page: Page, cal: ReturnType<Page['locator']>, label: string) {
  await expect(cal, label).toBeVisible();
  const { name, year } = thisMonth();
  await expect(cal.locator('.cal__title'), label).toContainText(name);
  await expect(cal.locator('.cal__month-name').first(), label).toHaveText(`${name} ${year}`);
  const box = await cal.evaluate((c) => {
    const r = c.getBoundingClientRect();
    const head = [...c.querySelectorAll('.cal__head > *')].map((e) => e.getBoundingClientRect());
    const days = [...c.querySelectorAll('.cal__day')] as HTMLElement[];
    const tables = [...c.querySelectorAll('table')].map((t) => t.getBoundingClientRect());
    const firstRow = c.querySelector('tbody tr:nth-child(2)');
    return {
      // the previous button, the month and the next button side by side: their middles on one line, left to right
      headOneLine: head.length === 3 && Math.max(...head.map((h) => h.top + h.height / 2)) - Math.min(...head.map((h) => h.top + h.height / 2)) < 6
        && head[0]!.right <= head[1]!.left && head[1]!.right <= head[2]!.left,
      numbered: days.length >= 28 && days.every((d) => /^\d{1,2}$/.test((d.textContent ?? '').trim())),
      inside: tables.every((t) => t.left >= r.left - 1 && t.right <= r.right + 1),
      perRow: firstRow ? firstRow.querySelectorAll('td').length : 0,
      minCell: Math.min(...days.map((d) => d.getBoundingClientRect().width)),
      cellH: Math.min(...days.map((d) => d.getBoundingClientRect().height))
    };
  });
  expect(box, label).toMatchObject({ headOneLine: true, numbered: true, inside: true, perRow: 7 });
  expect(box.minCell, label).toBeGreaterThanOrEqual(36);
  expect(box.cellH, label).toBeGreaterThanOrEqual(40);
}

test('the date picker: this month, one header line, numbered days, no overflow at 375 and 1024 to 1280', async ({ page }) => {
  const errors = watch(page);
  await page.goto('/cars');
  await acceptCookies(page);
  await page.locator('#fleet-grid .car-card__name a').first().click();
  await expect(page.locator('.gallery')).toBeVisible();
  const slug = new URL(page.url()).pathname.split('/')[2]!;
  for (const width of [375, 1024, 1152, 1280]) {
    await page.setViewportSize({ width, height: 900 });
    const cal = page.locator('.booking__cal .cal');
    await cal.scrollIntoViewIfNeeded();
    await checkCalendar(page, cal, `car page at ${width}`);
    await noOverflow(page);
  }
  // the request's two months (the full calendar a renter picks from)
  await page.goto(`/book/${slug}`);
  for (const width of [375, 1024, 1152, 1280]) {
    await page.setViewportSize({ width, height: 900 });
    const cal = page.locator('.req__cal .cal');
    await cal.scrollIntoViewIfNeeded();
    await checkCalendar(page, cal, `request at ${width}`);
    expect(await cal.locator('.cal__month-name').count()).toBe(2);
    await noOverflow(page);
  }
  expect(errors).toEqual([]);
});

test('a missing build file is a plain 404, never the HTML page', async ({ request }) => {
  const r = await request.get('/_next/static/chunks/app/gone-0000000000000000.js');
  expect(r.status()).toBe(404);
  expect(r.headers()['content-type'] ?? '').not.toContain('text/html');
});

test('the stale page guard is in the head of the page, with the page nonce', async ({ page }) => {
  const errors = watch(page);
  await page.goto('/');
  const g = await page.evaluate(() => { const s = document.getElementById('chunk-guard'); return { inHead: !!s && s.parentElement === document.head, nonce: !!s && (s.nonce || s.getAttribute('nonce') || '').length > 0 }; });
  expect(g).toEqual({ inHead: true, nonce: true });
  expect(errors).toEqual([]);
});
