// The few line icons portal-ui uses (20 x 20, stroke in currentColor, always beside words).
const P = {
  arrow: <path d="M3 10h13M11 4.5l5.5 5.5-5.5 5.5" />,
  left: <path d="M12.5 4l-6 6 6 6" />,
  right: <path d="M7.5 4l6 6-6 6" />,
  sign: <path d="M3 16.5h14M4.5 13l8.8-8.8a1.6 1.6 0 0 1 2.3 2.3L6.8 15.3 3.5 16l.7-3.3z" />,
  pay: <path d="M2.5 5.5h15v10h-15zM2.5 8.5h15M5.5 12.5h3" />,
  bank: <path d="M3 8h14L10 3.5zM4.5 8v6.5M8 8v6.5M12 8v6.5M15.5 8v6.5M3 16.5h14" />,
  doc: <path d="M5 2.5h6.5L15 6v11.5H5zM11.5 2.5V6H15M7.5 10h5M7.5 13h5" />,
  clock: <path d="M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM10 6v4.2l2.8 1.8" />,
  alert: <path d="M10 3l7.5 13.5h-15zM10 8.5v3.5M10 14.2v.3" />,
  car: <path d="M3 13.5V10l1.8-4.2A1.5 1.5 0 0 1 6.2 5h7.6a1.5 1.5 0 0 1 1.4.8L17 10v3.5M3 13.5h14M3 13.5V15h2.5v-1.5M14.5 13.5V15H17v-1.5M3.5 10h13M6 11.8h1M13 11.8h1" />,
  play: <path d="M7 5v10l8-5z" />,
  chart: <path d="M3 16.5h14M5.5 13.5v-4M9.5 13.5v-8M13.5 13.5v-6" />,
  check: <path d="M4 10.5l4 4 8-9" />
};
export type IconName = keyof typeof P;
export function PuIcon({ name }: { name: IconName }) {
  return <svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">{P[name]}</svg>;
}
