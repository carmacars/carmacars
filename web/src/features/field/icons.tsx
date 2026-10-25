// The field portal's line icons (24 x 24, stroke in currentColor, always beside words, so hidden from screen readers).
const P = {
  pin: <path d="M12 21s-6.5-6.2-6.5-11a6.5 6.5 0 0 1 13 0c0 4.8-6.5 11-6.5 11zM12 12.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z" />,
  phone: <path d="M6.6 3.5h3l1.5 4-2 1.3a10.5 10.5 0 0 0 6.1 6.1l1.3-2 4 1.5v3A2 2 0 0 1 18.4 19.5 15.9 15.9 0 0 1 4.5 5.6a2 2 0 0 1 2.1-2.1z" />,
  camera: <path d="M3.5 8.5A1.5 1.5 0 0 1 5 7h2.5L9 4.5h6L16.5 7H19a1.5 1.5 0 0 1 1.5 1.5v9A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5zM12 16a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z" />,
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
  cross: <path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />,
  key: <path d="M14.5 9.5a4 4 0 1 1-1.2-2.8 4 4 0 0 1 1.2 2.8zM13.3 12.3L20 19M17 16l2-2M15 14l1.5-1.5" />,
  bag: <path d="M5 8.5h14l-1 11H6zM9 8.5V7a3 3 0 0 1 6 0v1.5" />,
  car: <path d="M4 15.5v-4l2.2-5A1.8 1.8 0 0 1 7.8 5.5h8.4a1.8 1.8 0 0 1 1.6 1l2.2 5v4M4 15.5h16M4 15.5V18h3v-2.5M17 15.5V18h3v-2.5M4.5 11.5h15M7 13.5h1.5M15.5 13.5H17" />,
  cloud: <path d="M7 18.5h10a4 4 0 0 0 .6-8A5.5 5.5 0 0 0 7 9.5a4.5 4.5 0 0 0 0 9z" />,
  offline: <path d="M7 18.5h10a4 4 0 0 0 1.8-.4M20.6 15A4 4 0 0 0 17.6 10.5 5.5 5.5 0 0 0 9.5 6M6.3 9.6A4.5 4.5 0 0 0 7 18.5M4 4l16 16" />,
  retry: <path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4.5v4h-4" />,
  back: <path d="M15 5l-7 7 7 7" />,
  arrow: <path d="M4.5 12h14M13.5 6.5l5.5 5.5-5.5 5.5" />
};
export type FieldIconName = keyof typeof P;
export function FdIcon({ name, className = 'fd-ico' }: { name: FieldIconName; className?: string }) {
  return <svg className={className} viewBox="0 0 24 24" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">{P[name]}</svg>;
}
