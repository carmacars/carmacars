const PATHS = {
  arrow: <path d="M3 10h13M11 4.5l5.5 5.5-5.5 5.5" fill="none" stroke="currentColor" strokeWidth="2" />,
  left: <path d="M12.5 4l-6 6 6 6" fill="none" stroke="currentColor" strokeWidth="2" />,
  right: <path d="M7.5 4l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="2" />,
  cal: <path d="M3 5.5h14v11H3zM3 9h14M6.5 3v4M13.5 3v4" fill="none" stroke="currentColor" strokeWidth="1.6" />,
  filter: <path d="M3 6h14M6 10h8M8.5 14h3" fill="none" stroke="currentColor" strokeWidth="2" />
};
export function Icon({ name }: { name: keyof typeof PATHS }) {
  return <svg viewBox="0 0 20 20" aria-hidden="true">{PATHS[name]}</svg>;
}
