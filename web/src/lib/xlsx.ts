// A minimal Excel workbook writer (Office Open XML, ECMA-376): sheets of values and formulas, number formats, fonts,
// fills, borders, column widths, merged cells, frozen panes, list and number validations, notes in a cell's comment-free
// "note" column instead of comment drawings. Formulas are written without cached values and the workbook asks to be
// recalculated on open (calcPr fullCalcOnLoad), so Excel, Numbers, LibreOffice and Google Sheets show live results.
// Strings are inline (no shared-strings part). Packed with the dependency-free ZIP writer (src/lib/zip.ts), so it runs
// on Cloudflare Workers with no library and almost no CPU.
import { zip } from './zip.ts';

export type Value = string | number | boolean | null | undefined;
export interface Style {
  bold?: boolean; italic?: boolean; size?: number; color?: string; bg?: string;
  fmt?: string; align?: 'left' | 'center' | 'right'; wrap?: boolean; border?: 'box' | 'top' | 'double'; indent?: number;
}
export interface CellIn { v?: Value; f?: string; date?: string; s?: Style }
export interface Validation { sqref: string; list?: string[]; min?: number; max?: number; kind?: 'decimal' | 'whole' | 'date'; error?: string }
export interface SheetOptions { tab?: string; widths?: Record<string, number>; freeze?: string; grid?: boolean; landscape?: boolean }

export const FMT = {
  CUR: '"CA$"#,##0;("CA$"#,##0);"-"',
  CUR2: '"CA$"#,##0.00;("CA$"#,##0.00);"-"',
  USD: '"US$"#,##0;("US$"#,##0);"-"',
  PCT: '0.0%;(0.0%);"-"',
  NUM: '#,##0.0;(#,##0.0);"-"',
  INT: '#,##0;(#,##0);"-"',
  DATE: 'mmm d, yyyy',
  MON: 'mmm yyyy',
  MULT: '0.00"x"',
  RATIO: '0.000'
} as const;

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
  // characters XML 1.0 does not allow
  .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');

/** Column letters to a 1-based index and back. */
export function colIndex(letters: string): number { let n = 0; for (const ch of letters.toUpperCase()) n = n * 26 + (ch.charCodeAt(0) - 64); return n; }
export function colLetter(n: number): string { let s = ''; while (n > 0) { const m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - 1) / 26); } return s; }
export function splitRef(ref: string): { col: number; row: number } {
  const m = /^([A-Z]+)(\d+)$/.exec(ref.replace(/\$/g, '').toUpperCase());
  if (!m) throw new Error(`Bad cell reference ${ref}`);
  return { col: colIndex(m[1]!), row: Number(m[2]) };
}
export const ref = (col: number, row: number) => `${colLetter(col)}${row}`;

/** A calendar date (YYYY-MM-DD) as an Excel serial day number (1900 system). */
export function serial(date: string): number {
  const [y = 1900, m = 1, d = 1] = date.slice(0, 10).split('-').map(Number);
  return (Date.UTC(y, m - 1, d) - Date.UTC(1899, 11, 30)) / 86_400_000;
}

class Styles {
  private fonts: string[] = ['<font><sz val="10"/><color rgb="FF111111"/><name val="Arial"/></font>'];
  private fills: string[] = ['<fill><patternFill patternType="none"/></fill>', '<fill><patternFill patternType="gray125"/></fill>'];
  private borders: string[] = ['<border><left/><right/><top/><bottom/><diagonal/></border>'];
  private fmts: string[] = [];
  private xfs: string[] = ['<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'];
  private keys = new Map<string, number>();
  private idx(list: string[], x: string) { const i = list.indexOf(x); if (i >= 0) return i; list.push(x); return list.length - 1; }
  id(s?: Style): number {
    if (!s) return 0;
    const k = JSON.stringify(s);
    const hit = this.keys.get(k);
    if (hit !== undefined) return hit;
    const font = this.idx(this.fonts, `<font>${s.bold ? '<b/>' : ''}${s.italic ? '<i/>' : ''}<sz val="${s.size ?? 10}"/><color rgb="FF${(s.color ?? '111111').toUpperCase()}"/><name val="Arial"/></font>`);
    const fill = s.bg ? this.idx(this.fills, `<fill><patternFill patternType="solid"><fgColor rgb="FF${s.bg.toUpperCase()}"/><bgColor indexed="64"/></patternFill></fill>`) : 0;
    const thin = (c: string) => `style="thin"><color rgb="FF${c}"/>`;
    const border = s.border === 'box' ? this.idx(this.borders, `<border><left ${thin('D9D9D9')}</left><right ${thin('D9D9D9')}</right><top ${thin('D9D9D9')}</top><bottom ${thin('D9D9D9')}</bottom><diagonal/></border>`)
      : s.border === 'top' ? this.idx(this.borders, `<border><left/><right/><top ${thin('111111')}</top><bottom/><diagonal/></border>`)
      : s.border === 'double' ? this.idx(this.borders, `<border><left/><right/><top ${thin('111111')}</top><bottom style="double"><color rgb="FF111111"/></bottom><diagonal/></border>`) : 0;
    let fmt = 0;
    if (s.fmt) { const i = this.fmts.indexOf(s.fmt); fmt = 164 + (i >= 0 ? i : this.fmts.push(s.fmt) - 1); }
    const align = s.align || s.wrap || s.indent ? `<alignment${s.align ? ` horizontal="${s.align}"` : ''} vertical="center"${s.wrap ? ' wrapText="1"' : ''}${s.indent ? ` indent="${s.indent}"` : ''}/>` : '';
    const xf = `<xf numFmtId="${fmt}" fontId="${font}" fillId="${fill}" borderId="${border}" xfId="0"${fmt ? ' applyNumberFormat="1"' : ''} applyFont="1"${fill ? ' applyFill="1"' : ''}${border ? ' applyBorder="1"' : ''}${align ? ' applyAlignment="1">' + align + '</xf>' : '/>'}`;
    this.xfs.push(xf);
    const id = this.xfs.length - 1;
    this.keys.set(k, id);
    return id;
  }
  xml(): string {
    return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">`
      + (this.fmts.length ? `<numFmts count="${this.fmts.length}">${this.fmts.map((f, i) => `<numFmt numFmtId="${164 + i}" formatCode="${esc(f)}"/>`).join('')}</numFmts>` : '')
      + `<fonts count="${this.fonts.length}">${this.fonts.join('')}</fonts><fills count="${this.fills.length}">${this.fills.join('')}</fills>`
      + `<borders count="${this.borders.length}">${this.borders.join('')}</borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>`
      + `<cellXfs count="${this.xfs.length}">${this.xfs.join('')}</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`;
  }
}

export class Sheet {
  readonly cells = new Map<number, Map<number, CellIn>>();
  readonly merges: string[] = [];
  readonly validations: Validation[] = [];
  readonly heights = new Map<number, number>();
  readonly name: string;
  readonly opts: SheetOptions;
  constructor(name: string, opts: SheetOptions = {}) {
    this.name = name; this.opts = opts;
    if (name.length > 31 || /[\\/?*[\]:]/.test(name)) throw new Error(`Sheet name not allowed: ${name}`);
  }
  /** Put a value (a number, text, true/false), a formula ("=..."), or a date ({ date: 'YYYY-MM-DD' }) in a cell. */
  put(at: string, v: Value | { f: string } | { date: string }, s?: Style): this {
    const { col, row } = splitRef(at);
    const cell: CellIn = typeof v === 'object' && v !== null ? ('f' in v ? { f: v.f.replace(/^=/, ''), s } : { date: v.date, s }) : typeof v === 'string' && v.startsWith('=') ? { f: v.slice(1), s } : { v, s };
    if (!this.cells.has(row)) this.cells.set(row, new Map());
    this.cells.get(row)!.set(col, cell);
    return this;
  }
  /** Style a cell without changing its content (a fill across a banner, a border). */
  style(at: string, s: Style): this {
    const { col, row } = splitRef(at);
    const cur = this.cells.get(row)?.get(col);
    if (cur) cur.s = { ...cur.s, ...s }; else this.put(at, null, s);
    return this;
  }
  merge(range: string): this { this.merges.push(range); return this; }
  height(row: number, pt: number): this { this.heights.set(row, pt); return this; }
  validate(v: Validation): this { this.validations.push(v); return this; }
  get(at: string): CellIn | undefined { const { col, row } = splitRef(at); return this.cells.get(row)?.get(col); }

  xml(styles: Styles): string {
    const rows = [...this.cells.keys()].sort((a, b) => a - b);
    let maxC = 1, maxR = 1;
    const body = rows.map((r) => {
      maxR = Math.max(maxR, r);
      const cols = [...this.cells.get(r)!.entries()].sort((a, b) => a[0] - b[0]);
      const cs = cols.map(([c, x]) => {
        maxC = Math.max(maxC, c);
        const s = styles.id(x.s);
        const at = `${colLetter(c)}${r}`;
        const sa = s ? ` s="${s}"` : '';
        if (x.f !== undefined) return `<c r="${at}"${sa}><f>${esc(x.f)}</f></c>`;
        if (x.date) return `<c r="${at}"${sa}><v>${serial(x.date)}</v></c>`;
        const v = x.v;
        if (v === null || v === undefined || v === '') return `<c r="${at}"${sa}/>`;
        if (typeof v === 'number') return Number.isFinite(v) ? `<c r="${at}"${sa}><v>${v}</v></c>` : `<c r="${at}"${sa}/>`;
        if (typeof v === 'boolean') return `<c r="${at}"${sa} t="b"><v>${v ? 1 : 0}</v></c>`;
        return `<c r="${at}"${sa} t="inlineStr"><is><t xml:space="preserve">${esc(v)}</t></is></c>`;
      }).join('');
      const h = this.heights.get(r);
      return `<row r="${r}"${h ? ` ht="${h}" customHeight="1"` : ''}>${cs}</row>`;
    }).join('');
    const o = this.opts;
    let pane = '';
    if (o.freeze) {
      const { col, row } = splitRef(o.freeze);
      const xs = col - 1, ys = row - 1;
      const active = xs && ys ? 'bottomRight' : ys ? 'bottomLeft' : 'topRight';
      if (xs || ys) pane = `<pane${xs ? ` xSplit="${xs}"` : ''}${ys ? ` ySplit="${ys}"` : ''} topLeftCell="${o.freeze}" activePane="${active}" state="frozen"/><selection pane="${active}"/>`;
    }
    const widths = Object.entries(o.widths ?? {}).map(([l, w]) => [colIndex(l), w] as const).sort((a, b) => a[0] - b[0]);
    const dv = this.validations.map((v) => v.list
      ? `<dataValidation type="list" allowBlank="1" showErrorMessage="1" sqref="${v.sqref}"><formula1>"${esc(v.list.join(','))}"</formula1></dataValidation>`
      : `<dataValidation type="${v.kind ?? 'decimal'}" operator="${v.max !== undefined && v.min !== undefined ? 'between' : v.min !== undefined ? 'greaterThanOrEqual' : 'lessThanOrEqual'}" allowBlank="1" showErrorMessage="1"${v.error ? ` errorTitle="Check the value" error="${esc(v.error)}"` : ''} sqref="${v.sqref}"><formula1>${v.min ?? v.max}</formula1>${v.max !== undefined && v.min !== undefined ? `<formula2>${v.max}</formula2>` : ''}</dataValidation>`).join('');
    return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">`
      + `<sheetPr>${o.tab ? `<tabColor rgb="FF${o.tab}"/>` : ''}<pageSetUpPr fitToPage="1"/></sheetPr>`
      + `<dimension ref="A1:${colLetter(maxC)}${maxR}"/>`
      + `<sheetViews><sheetView workbookViewId="0"${o.grid === false ? ' showGridLines="0"' : ''}>${pane}</sheetView></sheetViews>`
      + `<sheetFormatPr defaultRowHeight="15"/>`
      + (widths.length ? `<cols>${widths.map(([c, w]) => `<col min="${c}" max="${c}" width="${w}" customWidth="1"/>`).join('')}</cols>` : '')
      + `<sheetData>${body}</sheetData>`
      + (this.merges.length ? `<mergeCells count="${this.merges.length}">${this.merges.map((m) => `<mergeCell ref="${m}"/>`).join('')}</mergeCells>` : '')
      + (dv ? `<dataValidations count="${this.validations.length}">${dv}</dataValidations>` : '')
      + `<pageMargins left="0.4" right="0.4" top="0.5" bottom="0.5" header="0.3" footer="0.3"/>`
      + `<pageSetup paperSize="1" orientation="${o.landscape === false ? 'portrait' : 'landscape'}" fitToWidth="1" fitToHeight="0"/>`
      + `<headerFooter><oddFooter>&amp;CCarmaCars  |  Page &amp;P of &amp;N</oddFooter></headerFooter>`
      + `</worksheet>`;
  }
}

export class Workbook {
  readonly sheets: Sheet[] = [];
  readonly title: string;
  constructor(title = 'CarmaCars') { this.title = title; }
  sheet(name: string, opts: SheetOptions = {}): Sheet { const s = new Sheet(name, opts); this.sheets.push(s); return s; }

  /** The .xlsx file's bytes. `when` stamps the archive and the document properties (deterministic output for a given input). */
  bytes(when: Date = new Date()): Uint8Array {
    const enc = new TextEncoder();
    const styles = new Styles();
    const sheetXml = this.sheets.map((s) => s.xml(styles)); // styles first: the sheets register theirs
    const iso = when.toISOString().replace(/\.\d+Z$/, 'Z');
    const files: Array<[string, string]> = [
      ['[Content_Types].xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">`
        + `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>`
        + `<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>`
        + this.sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')
        + `<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>`
        + `<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>`
        + `<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>`],
      ['_rels/.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">`
        + `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>`
        + `<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>`
        + `<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>`],
      ['docProps/core.xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">`
        + `<dc:title>${esc(this.title)}</dc:title><dc:creator>CarmaCars</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">${iso}</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">${iso}</dcterms:modified></cp:coreProperties>`],
      ['docProps/app.xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>CarmaCars</Application></Properties>`],
      ['xl/workbook.xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">`
        + `<bookViews><workbookView activeTab="0"/></bookViews><sheets>${this.sheets.map((s, i) => `<sheet name="${esc(s.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('')}</sheets>`
        + `<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>`],
      ['xl/_rels/workbook.xml.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">`
        + this.sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')
        + `<Relationship Id="rId${this.sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`],
      ['xl/styles.xml', styles.xml()],
      ...sheetXml.map((x, i) => [`xl/worksheets/sheet${i + 1}.xml`, x] as [string, string])
    ];
    return zip(files.map(([name, text]) => ({ name, data: enc.encode(text), date: when })));
  }
}

export const XLSX_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

// ---------------------------------------------------------------- the CarmaCars look (the workbook's own palette)
export const RED = 'D0111B', BLACK = '111111', WHITE = 'FFFFFF', GREY = 'F2F2F2', INFILL = 'FFF8DC', PINK = 'FBE5E6', MUTED = '595959', GREEN = '007A33';
export const S = {
  input: (fmt?: string): Style => ({ color: '0000FF', bg: INFILL, align: 'right', border: 'box', fmt }),
  head: (align: Style['align'] = 'center'): Style => ({ bold: true, color: WHITE, bg: RED, align, border: 'box', wrap: true }),
  dark: (align: Style['align'] = 'center'): Style => ({ bold: true, color: WHITE, bg: BLACK, align, border: 'box', wrap: true }),
  cell: (fmt?: string, extra: Style = {}): Style => ({ border: 'box', fmt, ...extra }),
  note: (): Style => ({ italic: true, size: 9, color: MUTED, wrap: true })
};

/** A red title band across columns A to `last`, with an optional black sub-line under it (the workbook's banner). */
export function banner(ws: Sheet, row: number, text: string, last: number, sub?: string, color = RED) {
  ws.merge(`A${row}:${colLetter(last)}${row}`).put(`A${row}`, text, { bold: true, color: WHITE, bg: color, size: 15, indent: 1 }).height(row, 30);
  for (let c = 2; c <= last; c++) ws.style(ref(c, row), { bg: color });
  if (sub) {
    ws.merge(`A${row + 1}:${colLetter(last)}${row + 1}`).put(`A${row + 1}`, sub, { color: WHITE, bg: BLACK, size: 9, indent: 1 }).height(row + 1, 18);
    for (let c = 2; c <= last; c++) ws.style(ref(c, row + 1), { bg: BLACK });
  }
}
/** A section heading row filled across columns A to `last`. */
export function section(ws: Sheet, row: number, text: string, last: number, color = BLACK) {
  ws.put(`A${row}`, text, { bold: true, color: WHITE, bg: color, size: 11 }).height(row, 20);
  for (let c = 2; c <= last; c++) ws.style(ref(c, row), { bg: color });
}
