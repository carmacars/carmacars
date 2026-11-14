// Names compared the way people write them (release 48, migration 2910's app.person_names_match, the same rules): case,
// accents, apostrophes, hyphens and other punctuation, extra spaces, middle names, the order of the names and an
// initial for the first name do not matter. Nicknames are not guessed. Pure; the database decides.

/** The words of a name: lower case, accents and punctuation removed ("Zoë O'Neil-Brown" -> zoe, oneil, brown). */
export function nameTokens(name: string | null | undefined): string[] {
  return (name ?? '')
    .replace(/['`‘’]/g, '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/ł/g, 'l').replace(/Ł/g, 'L')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .split(' ')
    .filter(Boolean);
}

/** x's first and last words are both in y (the first may be an initial). */
function covers(x: string[], y: string[]): boolean {
  if (x.length < 2 || y.length < 2) return false;
  const first = x[0]!;
  const last = x[x.length - 1]!;
  const firstOk = y.includes(first) || (first.length === 1 && y.some((t) => t.startsWith(first)));
  return firstOk && y.includes(last);
}

/** Is this the same person's name? */
export function sameName(a: string | null | undefined, b: string | null | undefined): boolean {
  const ta = nameTokens(a);
  const tb = nameTokens(b);
  if (!ta.length || !tb.length) return false;
  if (ta.join('') === tb.join('')) return true;
  return covers(ta, tb) || covers(tb, ta);
}

/** The initials of a name: the first letter of the first and the last word. */
export function initialsOf(name: string | null | undefined): string {
  const t = nameTokens(name);
  if (!t.length) return '';
  return (t.length === 1 ? t[0]!.slice(0, 1) : t[0]!.slice(0, 1) + t[t.length - 1]!.slice(0, 1)).toUpperCase();
}

/** x's last word is in y and x's first word is a shortened first word of y ("alex" of "alexander"). */
function shortCovers(x: string[], y: string[]): boolean {
  if (x.length < 2 || y.length < 2) return false;
  const first = x[0]!;
  const last = x[x.length - 1]!;
  return y.includes(last) && first.length >= 2 && y.some((t) => t !== last && t.length > first.length && t.startsWith(first));
}

/** Is the card in this person's name (migration 2912's app.card_name_matches)? sameName, or a shortened first name. */
export function cardNameMatches(card: string | null | undefined, name: string | null | undefined): boolean {
  if (sameName(card, name)) return true;
  const a = nameTokens(card);
  const b = nameTokens(name);
  return shortCovers(a, b) || shortCovers(b, a);
}
