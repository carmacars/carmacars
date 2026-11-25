// The feedback words of the motion kit (release 50): pure, no DOM, unit tested (feedback.test.ts). Portable: no brand.
//   doneWord: the word a button shows for a moment after its action worked ("Save" -> "Saved"), or null for a button
//     whose label is not an action that finishes (Next, Search, Continue): those never morph by themselves;
//   isSuccessText: a status line that says something finished ("Saved.", "Link copied", "Done."), which gets the tick;
//   SHAKE_MS: the error nudge's length (feedback.css mo-shake: 4 oscillations that die away).

const VERBS: Array<[RegExp, string]> = [
  [/^(save|keep)\b/i, 'Saved'],
  [/^(send|resend|email|text|share|invite|notify|reply)\b/i, 'Sent'],
  [/^sign\b(?!\s*(in|up|out)\b)/i, 'Signed'],
  [/^(pay|charge)\b/i, 'Paid'],
  [/^approve\b/i, 'Approved'],
  [/^(accept|agree)\b/i, 'Accepted'],
  [/^(add|attach|upload|record|log)\b/i, 'Added'],
  [/^(update|change|edit|set|rename|move|assign|reassign)\b/i, 'Updated'],
  [/^(create|issue|open a|make)\b/i, 'Created'],
  [/^copy\b/i, 'Copied'],
  [/^(book|reserve)\b/i, 'Booked'],
  [/^(confirm|verify)\b/i, 'Confirmed'],
  [/^(request|submit|apply)\b/i, 'Sent'],
  [/^(publish|list)\b/i, 'Published'],
  [/^(release|refund|return|pay out)\b/i, 'Done'],
  [/^(remove|delete|archive|dismiss|put aside|cancel the|void|withdraw|end)\b/i, 'Done'],
  [/^(mark|complete|finish|close|resolve|clear|claim|match)\b/i, 'Done']
];

/** The word a button shows after its action worked; null when the label is not a finishing action. */
export function doneWord(label: string | null | undefined): string | null {
  const s = (label ?? '').replace(/\s+/g, ' ').trim();
  if (!s || s.length > 60) return null;
  if (/^(next|back|continue|search|find|filter|show|hide|view|see|go|check|try|start|load|more|cancel|close this|sign (in|up|out)|log ?(in|out))\b/i.test(s)) return null;
  for (const [re, word] of VERBS) if (re.test(s)) return word;
  return null;
}

const DONE = /^(saved|sent|copied|done|signed|paid|approved|accepted|added|updated|created|booked|confirmed|published|submitted|uploaded|removed|deleted|archived|released|refunded|undone)\b/i;
const DONE_END = /\b(saved|sent|copied|signed|paid|approved|updated|added|confirmed|published|uploaded)\.?$/i;
/** A status line that reports something finished (and is not a question or a refusal). */
export function isSuccessText(text: string | null | undefined): boolean {
  const s = (text ?? '').replace(/\s+/g, ' ').trim();
  if (!s || s.length > 120 || /\b(not|could not|couldn't|failed|unsaved|error)\b/i.test(s) || s.endsWith('?')) return false;
  return DONE.test(s) || DONE_END.test(s);
}

/** The error nudge's length (feedback.css, mo-shake), within the kit's 300 ms ceiling. */
export const SHAKE_MS = 280;

/** How many rows went at once: one or two are a person removing them (collapse); more is the list being replaced. */
export function isRemoval(removed: number, added: number): boolean {
  return removed >= 1 && removed <= 2 && added === 0;
}
