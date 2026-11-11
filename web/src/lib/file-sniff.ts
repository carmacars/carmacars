// What an uploaded file really is, read from its first bytes (never from its name or the type the browser claims).
// r35: one place for the checks every upload made on its own (some read two bytes, some four). No imports: the Worker,
// the server actions and the unit tests all use it.

/** JPEG (FF D8 FF) or PNG (89 50 4E 47 0D 0A 1A 0A, the first four checked), from the file's own bytes. */
export function imageSniff(b: Uint8Array): { jpg: boolean; png: boolean } {
  const jpg = b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
  const png = b.length >= 4 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
  return { jpg, png };
}

/** A PDF starts with "%PDF-". */
export function isPdf(b: Uint8Array): boolean {
  return b.length >= 5 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46 && b[4] === 0x2d;
}
