// While an admin page loads (admin portal design, October 25, 2026): the shape of a page header, a row of filters and a
// list, in grey, so the frame and the menu stay put and the page does not jump when it arrives.
export default function AdminLoading() {
  return (
    <div className="ad-skel" aria-busy="true" aria-live="polite" data-testid="admin-loading">
      <p className="vh">Loading the page</p>
      <div className="ad-skel__head"><span className="skeleton ad-skel__kicker" /><span className="skeleton ad-skel__title" /></div>
      <div className="ad-skel__chips">{[0, 1, 2, 3].map((i) => <span key={i} className="skeleton ad-skel__chip" />)}</div>
      <div className="ad-skel__card">{[0, 1, 2, 3, 4, 5].map((i) => <span key={i} className="skeleton ad-skel__row" />)}</div>
    </div>
  );
}
