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

// The larger set (portal-ui, renter portal first): one 24 px grid, 1.6 stroke, round joins, currentColor. Decorative by default
// (aria-hidden); the text beside an icon always says what it is.
const P24 = {
  car: <><path d="M4 15.5V12l1.6-4.3A2 2 0 0 1 7.5 6.4h9a2 2 0 0 1 1.9 1.3L20 12v3.5" /><path d="M3 15.5h18v2.2a.8.8 0 0 1-.8.8h-1.7a.8.8 0 0 1-.8-.8V17H6.3v.7a.8.8 0 0 1-.8.8H3.8a.8.8 0 0 1-.8-.8z" /><path d="M4.5 12h15" /><circle cx="7.5" cy="14.2" r=".6" /><circle cx="16.5" cy="14.2" r=".6" /></>,
  calendar: <><rect x="3.5" y="5" width="17" height="15" rx="2.5" /><path d="M3.5 10h17M8 3v4M16 3v4" /></>,
  pin: <><path d="M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11z" /><circle cx="12" cy="10" r="2.3" /></>,
  clock: <><circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 2" /></>,
  gauge: <><path d="M4.2 17a8.5 8.5 0 1 1 15.6 0" /><path d="M12 13.5l4-4" /><circle cx="12" cy="13.5" r="1.2" /></>,
  fuel: <><path d="M5 20V5.5A1.5 1.5 0 0 1 6.5 4h6A1.5 1.5 0 0 1 14 5.5V20M4 20h11M6.5 9h6" /><path d="M14 9.5h1.5a1.5 1.5 0 0 1 1.5 1.5v5a1.5 1.5 0 0 0 3 0V8.5L17.5 6" /></>,
  key: <><circle cx="8" cy="15" r="3.8" /><path d="M10.8 12.3L19 4M16 7l2.5 2.5M13.8 9.2l2 2" /></>,
  doc: <><path d="M7 3.5h7l4.5 4.5v11a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 19V5A1.5 1.5 0 0 1 7 3.5z" /><path d="M13.5 3.5V8.5h5M8.5 13h7M8.5 16.5h5" /></>,
  receipt: <><path d="M6 3.5h12v17l-2-1.4-2 1.4-2-1.4-2 1.4-2-1.4-2 1.4z" /><path d="M9 8h6M9 11.5h6M9 15h3.5" /></>,
  camera: <><path d="M4 8.5A1.5 1.5 0 0 1 5.5 7h2.2l1.5-2h5.6l1.5 2h2.2A1.5 1.5 0 0 1 20 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z" /><circle cx="12" cy="13" r="3.4" /></>,
  phone: <path d="M6.6 3.8l2.6-.3 1.4 4-1.9 1.3a11 11 0 0 0 6.5 6.5l1.3-1.9 4 1.4-.3 2.6a2 2 0 0 1-2.1 1.8A16.5 16.5 0 0 1 4.8 5.9a2 2 0 0 1 1.8-2.1z" />,
  chat: <path d="M4.5 6.5A2.5 2.5 0 0 1 7 4h10a2.5 2.5 0 0 1 2.5 2.5v7A2.5 2.5 0 0 1 17 16h-6.5L6 19.5V16h0a2.5 2.5 0 0 1-1.5-2.3z" />,
  userPlus: <><circle cx="9.5" cy="8.5" r="3.5" /><path d="M3.5 19.5a6 6 0 0 1 12 0M18.5 8v6M15.5 11h6" /></>,
  alert: <><path d="M12 4l9 15.5H3z" /><path d="M12 10v4.5M12 17.2v.1" /></>,
  extend: <><rect x="3.5" y="5" width="17" height="15" rx="2.5" /><path d="M3.5 10h17M8 3v4M16 3v4M12 13v4.5M9.8 15.2H14.2" /></>,
  card: <><rect x="3" y="6" width="18" height="12.5" rx="2.2" /><path d="M3 10h18M6.5 15h4" /></>,
  check: <path d="M5 12.5l4.2 4.2L19 7" />,
  arrow: <path d="M5 12h13.5M13 6.5l5.5 5.5-5.5 5.5" />,
  arrowUpRight: <path d="M7.5 16.5l9-9M9 7.5h7.5V15" />,
  shield: <><path d="M12 3.5l7 2.8v5.2c0 4.4-3 7.8-7 9-4-1.2-7-4.6-7-9V6.3z" /><path d="M9 12l2.2 2.2L15.5 10" /></>,
  download: <path d="M12 4v11M7.5 10.5L12 15l4.5-4.5M5 19.5h14" />,
  star: <path d="M12 4l2.4 5 5.4.7-4 3.7 1 5.4L12 16.2 7.2 18.8l1-5.4-4-3.7 5.4-.7z" />,
  repeat: <><path d="M17 3.5l3 3-3 3" /><path d="M4 11.5v-1a4 4 0 0 1 4-4h12M7 20.5l-3-3 3-3" /><path d="M20 12.5v1a4 4 0 0 1-4 4H4" /></>,
  id: <><rect x="3" y="5.5" width="18" height="13" rx="2.2" /><circle cx="8.5" cy="11" r="2" /><path d="M5.5 15.5a3 3 0 0 1 6 0M14 10h4.5M14 13.5h3" /></>,
  swap: <path d="M7 4.5L4 7.5l3 3M4 7.5h12M17 13.5l3 3-3 3M20 16.5H8" />,
  x: <path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />,
  sparkle: <path d="M12 3.5l1.8 5.2 5.2 1.8-5.2 1.8L12 17.5l-1.8-5.2L5 10.5l5.2-1.8zM18.5 15.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z" />,
  route: <><circle cx="6" cy="18" r="2" /><circle cx="18" cy="6" r="2" /><path d="M8 18h7.5a3 3 0 0 0 0-6h-7a3 3 0 0 1 0-6H16" /></>
} as const;

export type PortalIconName = keyof typeof P24;

export function PortalIcon({ name, size = 20, className }: { name: PortalIconName; size?: number; className?: string }) {
  return (
    <svg className={className ? `pu-icon ${className}` : 'pu-icon'} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">{P24[name]}</svg>
  );
}
