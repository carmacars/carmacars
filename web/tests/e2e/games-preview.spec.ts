import { expect, test } from '@playwright/test';
import { acceptCookies, db, watch } from './helpers';

// The discount game's preview (2026-11-06, docs/changes/2026-11-06-games-every-visit-preview.md): /?preview=game puts
// the card on screen at once for anyone (the owner, signed in, never gets the real game), plays a game through to a
// sample prize and shows the code screen, with no play on the server and nothing remembered in the browser.
test.use({ contextOptions: { reducedMotion: 'no-preference' } });

test('preview: the game on demand, played through, nothing recorded', async ({ page }) => {
  test.setTimeout(90_000);
  const errors = watch(page);
  const sql = db();
  const before = (await sql<{ n: number }[]>`select count(*)::int n from game_plays`)[0]!.n;
  await page.goto('/?preview=game&game=mystery');
  await acceptCookies(page);
  const card = page.locator('[data-testid="game"][data-preview="true"]');
  await expect(card).toBeVisible({ timeout: 20_000 });
  await expect(card).toHaveAttribute('data-game', 'mystery');
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
  const after = (await sql<{ n: number }[]>`select count(*)::int n from game_plays`)[0]!.n;
  expect(after).toBe(before);
  expect(await page.evaluate(() => localStorage.getItem('cc_game'))).toBeNull();
  expect(errors).toEqual([]);
  await sql.end();
});
