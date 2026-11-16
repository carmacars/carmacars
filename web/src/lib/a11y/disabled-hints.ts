// r48 part 2: every button that can be greyed out says why and what to do first (the owner: "every disabled button on
// every portal must show a hint"), the pattern of Propose a change's Send (3050): the button names its hint with
// aria-describedby (or a title), and the hint, shown while it is greyed out, says what to do first. A button greyed out
// only while its own action runs ("Working") needs none. Pure: disabled-hints.test.ts scans every .tsx with it.

/** Flags that only mean "this button's action is running": a button greyed out by these alone needs no hint. */
export const IN_FLIGHT = new Set(['pending', 'busy', 'working', 'saving', 'isPending', 'loading', 'sending', 'submitting', 'running', 'inFlight',
  'pend', 'posting', 'uploading', 'readingBusy', 'starting', 'checking', 'deleting', 'removing', 'paying', 'charging', 'saving.current', 'pending.current']);

export interface Finding { line: number; expr: string; tag: string }

/** The end of a JSX opening tag that starts at `from` (braces and strings skipped). */
function tagEnd(src: string, from: number): number {
  let depth = 0; let q: string | null = null;
  for (let i = from; i < src.length; i++) {
    const c = src[i];
    if (q) { if (c === '\\') { i++; continue; } if (c === q) q = null; continue; }
    if (depth > 0 && (c === '"' || c === "'" || c === '`')) { q = c; continue; }
    if (c === '{') depth++;
    else if (c === '}') depth--;
    else if (c === '>' && depth === 0) return i;
  }
  return src.length - 1;
}

/** The expression of disabled={...} in a tag ('true' for a bare `disabled`), or null. */
export function disabledExpr(tag: string): string | null {
  const m = /\sdisabled(?=[\s=/>])/.exec(tag);
  if (!m) return null;
  let i = m.index + m[0].length;
  while (tag[i] === ' ') i++;
  if (tag[i] !== '=') return 'true';
  i++;
  if (tag[i] !== '{') return tag.slice(i).split(/\s/)[0] ?? 'true';
  let depth = 0;
  for (let j = i; j < tag.length; j++) {
    if (tag[j] === '{') depth++;
    else if (tag[j] === '}' && --depth === 0) return tag.slice(i + 1, j).trim();
  }
  return tag.slice(i + 1).trim();
}

/** True when the expression is only "the action is running" flags (a || b), or false. */
export function inFlightOnly(expr: string): boolean {
  if (expr === 'false') return true;
  const parts = expr.split('||').map((x) => x.trim().replace(/^\(|\)$/g, '').trim());
  return parts.every((p) => {
    const bare = p.replace(/^!!/, '');
    const last = bare.split('.').pop() ?? bare;
    return IN_FLIGHT.has(bare) || IN_FLIGHT.has(last) || /^(pending|busy)[A-Z]\w*$/.test(last)
      || /^(busy|pending|state|phase|status|st\.\w+|state\.\w+) === '(busy|pending|working|saving|sending|uploading)'$/.test(p)
      || /^(busy|pending) === /.test(p) || /^(busy|uploading|pending) > 0$/.test(p) || /^(state|status) !== 'idle'$/.test(p);
  });
}

/** Each <button> greyed out for a reason other than its own action running, without aria-describedby or a title. */
export function findUnhinted(src: string): Finding[] {
  const out: Finding[] = [];
  const re = /<button\b/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src))) {
    const end = tagEnd(src, m.index + 7);
    const tag = src.slice(m.index, end + 1);
    const expr = disabledExpr(tag);
    if (expr === null || inFlightOnly(expr)) continue;
    if (/\saria-describedby=|\stitle=/.test(tag)) continue;
    out.push({ line: src.slice(0, m.index).split('\n').length, expr: expr.replace(/\s+/g, ' ').slice(0, 120), tag: tag.replace(/\s+/g, ' ').slice(0, 160) });
  }
  return out;
}
