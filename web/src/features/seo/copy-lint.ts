// The positive-copy rule of the SEO pages (release 36, docs/changes/2026-11-11-r36-seo-growth.md): a search page never
// tells the reader what we lack ("not available", "we don't have", "we don't offer", "no car matches"). It shows the
// nearest similar cars, a "Request this exact car" form, or what we do instead. One list of phrases, used three ways:
//   1. CI: scripts/check-seo-copy.mjs fails on a phrase in an SEO template (the files of SEO_TEMPLATE_GLOBS),
//   2. the search copy checks (copy.ts styleProblems): written or imported copy with a phrase is refused,
//   3. the unit test (copy-lint.test.ts).
// Pure, relative imports only.

/** The phrases (regular expressions, case-insensitive), each with the positive way to say it. */
export const NEGATIVE_PHRASES: ReadonlyArray<{ re: RegExp; say: string }> = [
  { re: /\bnot\s+available\b|\bunavailable\b/i, say: 'show the similar cars available now, or "Request this exact car"' },
  { re: /\bwe\s+(?:do\s+not|don['’]t)\s+have\b|\bwe\s+have\s+no\b/i, say: 'say what we have: the similar cars, the request form' },
  { re: /\b(?:do|does)\s+not\s+offer\b|\b(?:don['’]t|doesn['’]t)\s+offer\b|\bnot\s+something\s+we\s+offer\b/i, say: 'say what we arrange or offer instead' },
  { re: /\bno\s+cars?\s+match(?:es)?\b/i, say: 'show the nearest similar cars' },
  { re: /\bnot\s+from\s+our\s+fleet\b|\bnot\s+in\s+our\s+fleet\b/i, say: 'invite a request for the exact car' },
  { re: /\bsold\s+out\b|\bout\s+of\s+stock\b/i, say: 'show the similar cars and the request form' },
  { re: /\bnot\s+right\s+now\b|\bnot\s+as\s+a\s+rule\b/i, say: 'say what the reader can do now' },
  { re: /\bha(?:s|ve)\s+no\s+location\b/i, say: 'say where we are and that we deliver' },
  { re: /\bbeyond\s+the\s+[^.]{0,40}\bdeliver/i, say: 'say the car is picked up in Toronto, or delivered on request' },
  { re: /\b(?:does|do)\s+not\s+(?:do\s+(?:this|mechanical)\s+work|sell)\b|\bwe\s+are\s+not\s+a\s+dealer\b/i, say: 'say what we do: we arrange it with a trusted shop, we rent the model first' },
  { re: /\bno\s+longer\s+offered\b/i, say: 'say when it was last offered' },
  { re: /\bwe\s+do\s+not\s+publish\b/i, say: 'say what the page shows' },
  { re: /\bnot\s+rated\b/i, say: 'leave the value out, or "Rating on request"' },
  { re: /\b(?:can['’]t|cannot)\s+help\b/i, say: 'say what we can do' },
  { re: /\bha(?:s|ve)\s+no\b[^.]{0,40}\byet\b|\bnone\s+for\s+sale\b/i, say: 'say what the page has: our cars, the similar cars' }
];

export interface LintHit { phrase: string; say: string }
/** The negative phrases in a text. */
export function negativeHits(text: string): LintHit[] {
  const out: LintHit[] = [];
  for (const p of NEGATIVE_PHRASES) { const m = p.re.exec(text); if (m) out.push({ phrase: m[0], say: p.say }); }
  return out;
}

/** The source files whose visible text the CI check reads (globs relative to the repository root). */
export const SEO_TEMPLATE_GLOBS = [
  'web/src/features/seo/*.ts', 'web/src/features/seo/*.tsx', 'web/src/features/places/*.ts', 'web/src/features/places/*.tsx',
  'web/src/features/vehicles/*.ts', 'web/src/features/vehicles/*.tsx', 'web/src/features/events/*.ts', 'web/src/features/events/*.tsx',
  'web/src/features/i18n/*.ts', 'web/src/features/i18n/*.tsx', 'web/src/features/tracker-product/*.ts', 'web/src/features/tracker-product/*.tsx',
  'web/src/app/car-rental/**', 'web/src/app/cars/**', 'web/src/app/rent/**', 'web/src/app/places/**', 'web/src/app/makes/**', 'web/src/app/events/**',
  'web/src/features/airports/*.ts', 'web/src/features/airports/*.tsx', 'web/src/features/rent-vs-own/*.ts', 'web/src/features/rent-vs-own/*.tsx',
  'web/src/app/gps-tracker/**', 'web/src/app/airport-car-rental/**', 'web/src/app/rent-vs-own/**', 'web/src/app/[[]lang]/**'
];
/** Files of those globs that are not page text: the checks' own lists, tests, the importers' parsers and admin screens. */
export const SEO_TEMPLATE_SKIP = /(\.test\.ts$|copy-lint\.ts$|Admin\.tsx$|admin|seo-data\.ts$|worker\.ts$|batch\.ts$|gsc-plan\.ts$|coverage\.ts$|crawlers\.ts$|normalise\.ts$|permit-read\.ts$|PermitScan\.tsx$|Registration\.tsx$|stock-photos\.ts$)/;

/** The text of a source file without its comments (line, block and JSX comments), line numbers kept. */
export function stripComments(src: string, sql = false): string {
  let s = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '));
  // in SQL, a WHERE line names the old text being replaced (an update's condition), not text a page shows
  s = s.split('\n').map((l) => (sql ? (/^\s*where\s/i.test(l) ? '' : l.replace(/--.*$/, '')) : l.replace(/(^|[\s;{}(),])\/\/.*$/, '$1'))).join('\n');
  return s;
}

/** The hits of a source file: [line, hit]. */
export function lintSource(src: string, sql = false): Array<{ line: number; hit: LintHit }> {
  const out: Array<{ line: number; hit: LintHit }> = [];
  stripComments(src, sql).split('\n').forEach((l, i) => { for (const h of negativeHits(l)) out.push({ line: i + 1, hit: h }); });
  return out;
}
