// Make, model and trim in the case people write them (migration 0087; the same rule as app.car_name_case in the
// database): only a value written entirely in capitals is changed ("VOLKSWAGEN JETTA COMFORTLINE SPORT" is
// "Volkswagen Jetta Comfortline Sport"); mixed case is left as typed. Known brand spellings win (Mercedes-Benz, BMW,
// GMC, MINI, Kia), a word with a digit stays (CLA250, 4MATIC, F-150), known trim and drive acronyms stay in capitals
// (SE, XLT, AWD, TSI), a word or a hyphen part without a vowel stays (LXS, SXT, CR-V), R-Line, S-Line, xDrive and
// SuperCrew keep their form, every other word is Title case.
export const BRANDS: Record<string, string> = {
  'MERCEDES-BENZ': 'Mercedes-Benz', 'MERCEDES BENZ': 'Mercedes-Benz', BMW: 'BMW', GMC: 'GMC', MINI: 'MINI', KIA: 'Kia', VOLKSWAGEN: 'Volkswagen', VW: 'VW',
  'LAND ROVER': 'Land Rover', 'ALFA ROMEO': 'Alfa Romeo', 'ROLLS-ROYCE': 'Rolls-Royce', 'ASTON MARTIN': 'Aston Martin', MCLAREN: 'McLaren', RAM: 'Ram',
  FIAT: 'FIAT', SMART: 'smart', JAC: 'JAC', BYD: 'BYD', MG: 'MG', DS: 'DS', 'MERCEDES-AMG': 'Mercedes-AMG', 'MERCEDES-MAYBACH': 'Mercedes-Maybach'
};
export const ACRONYMS = ['SE', 'SEL', 'LE', 'XLE', 'XSE', 'LX', 'EX', 'EX-L', 'FE', 'GT', 'GTI', 'GLI', 'GTE', 'XLT', 'LT', 'LS', 'LTZ', 'RS', 'SR', 'SV',
  'SL', 'AMG', 'AWD', 'FWD', 'RWD', '4WD', 'SUV', 'TDI', 'TSI', 'EV', 'HEV', 'PHEV', 'ES', 'IS', 'UX', 'SE-R', 'GLA', 'GLB', 'GLC', 'GLE', 'GLS', 'CLA',
  'CLS', 'EQB', 'EQE', 'EQS', 'TRD', 'ESV', 'EXT'];
export const SPECIAL: Record<string, string> = { 'R-LINE': 'R-Line', 'S-LINE': 'S-Line', XDRIVE: 'xDrive', SDRIVE: 'sDrive', SUPERCREW: 'SuperCrew', SUPERCAB: 'SuperCab' };

const title = (w: string) => w.toLowerCase().replace(/(^|[^\p{L}\p{N}])(\p{L})/gu, (_, a: string, b: string) => a + b.toUpperCase());

/** True when the text has letters and none of them is lower case. */
export const allCaps = (s: string) => s !== s.toLowerCase() && s === s.toUpperCase();

function word(w: string, kind: 'make' | 'model' | 'trim'): string {
  if (/\d/.test(w)) return w;
  const core = w.replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, '');
  if (!core) return w;
  const at = w.indexOf(core), pre = w.slice(0, at), post = w.slice(at + core.length);
  if (SPECIAL[core]) return pre + SPECIAL[core] + post;
  if (ACRONYMS.includes(core)) return w;
  if (kind === 'make' && BRANDS[core]) return pre + BRANDS[core] + post;
  return pre + core.split('-').map((p) => (/[AEIOUY]/.test(p) ? title(p) : p)).join('-') + post;
}

export function nameCase(raw: string | null | undefined, kind: 'make' | 'model' | 'trim' = 'model'): string {
  const s = (raw ?? '').trim();
  if (!s || !allCaps(s)) return raw ?? '';
  const whole = BRANDS[s.replace(/\s+/g, ' ')];
  if (kind === 'make' && whole) return whole;
  return s.split(/\s+/).map((w) => word(w, kind)).join(' ');
}
