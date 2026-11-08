// What a government form still misses, in words (r34, part Q). app.fill_government_form (0022) also lists each required
// box of the official PDF as "PDF field <its internal name>" (form1[0].page1[0]...): a code for the form filler, not for
// people, and so long it pushed the owner's checklist off a phone screen. Those entries are left out where the list is
// shown; the boxes stay listed by name on the staff form page (the field map), and the onboarding step already leaves
// them out (0823).
const PDF_FIELD = /^PDF field /;

export function readableMissing(list: readonly string[]): string[] {
  const words = list.filter((m) => !PDF_FIELD.test(m));
  return words.length || !list.length ? words : ['a box of the official form (we fill it in)'];
}

/** The same for a sentence such as "Missing: Body type, PDF field form1[0].x[0]" (the owner checklist's detail). */
export function readableDetail(text: string): string {
  if (!text.includes('PDF field ')) return text;
  const m = /^(.*?Missing: )(.*)$/.exec(text);
  if (!m) return text.replace(/,?\s*PDF field \S+/g, '');
  return `${m[1]}${readableMissing(m[2]!.split(/,\s*/)).join(', ')}`;
}
