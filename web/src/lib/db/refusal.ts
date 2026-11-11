// r35a: the words of a refused action, never empty. A database refusal is shown as written (without the "ERROR:" prefix);
// an error with no words (a dropped connection, a timeout) says what happened instead of showing an empty red box.
export const NO_WORDS = 'Something went wrong and nothing was saved. Check your connection and try again.';
export function refusalMessage(e: unknown): string {
  const raw = e instanceof Error ? e.message : typeof e === 'string' ? e : '';
  const m = raw.replace(/^.*?ERROR:\s*/, '').trim();
  return m || NO_WORDS;
}
