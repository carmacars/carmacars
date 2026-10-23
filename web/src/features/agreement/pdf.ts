import 'server-only';
// The agreement renderer for the server (render.ts holds it, so the unit tests can run it in Node).
export { agreementPdf, pdfSafe, type PdfExtras } from './render';
