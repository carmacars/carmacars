import { expect, test } from '@playwright/test';
import { acceptCookies, watch } from './helpers';

// The discount game's preview (2026-11-06, docs/changes/2026-11-06-games-every-visit-preview.md): /?preview=game puts
// the card on screen at once for anyone (the owner, signed in, never gets the real game), plays a game through to a
// sample prize and shows the code screen, with no play on the server and nothing remembered in the browser.
test.use({ contextOptions: { reducedMotion: 'no-preference' } });

test('preview: the game on demand, played through, nothing recorded', async ({ page }) => {
  test.setTimeout(90_000);
  const errors = watch(page);
  // nothing goes to the server for a preview: no play, no reveal, no claim, no contact capture
  const calls: string[] = [];
  page.on('request', (r) => { if (/game_start|game_reveal|\/api\/games|capture/.test(r.url())) calls.push(r.url()); });
  await page.goto('/?preview=game&game=mystery');
  await acceptCookies(page);
  const card = page.locator('[data-testid="game"][data-preview="true"]');
  await expect(card).toBeVisible({ timeout: 20_000 });
  await expect(card).toHaveAttribute('data-game', 'mystery');
  // the cookie banner can come up after the first check (it then covers Play now on a phone): answered again
  await acceptCookies(page);
  await expect(card).toContainText('Preview of the giveaway');
  await card.getByTestId('game-play').click();
  // the mystery box: pick one
  await card.getByTestId('game-box-2').click();
  await expect(card.getByTestId('game-claim')).toBeVisible({ timeout: 20_000 });
  await card.getByLabel('First name').fill('Preview');
  await card.getByLabel('Email').fill('preview@example.com');
  await card.getByTestId('game-get-code').click();
  await expect(card.getByTestId('game-code')).toHaveText('PREVIEW');
  await card.getByTestId('game-close').click();
  await expect(card).toHaveCount(0);
  expect(calls).toEqual([]);
  expect(await page.evaluate(() => localStorage.getItem('cc_game'))).toBeNull();
  expect(errors).toEqual([]);
});
