// r47: the page survives the browser translating it. Chrome (Android, desktop and iOS) and Safari translate a page by
// replacing its text nodes with their own <font> elements; React then removes or inserts beside a node that is no longer
// where it put it, and the browser throws NotFoundError ("Failed to execute 'removeChild' on 'Node'", "insertBefore",
// WebKit's "The object can not be found here."): the page crashed for a renter reading it in their language
// (/account/documents, /account/rewards, /pay/...). This inline script, in <head> before React runs, makes those two calls
// forgiving for a node that is not a child any more (the fix React's own issue 11538 gives): removing it again does
// nothing, and inserting before it appends at the end instead. Each such rescue is counted on window.__ccDomGuard.
// Installed once (a second run changes nothing). Plain text with no imports: inlined in the page (the Worker gives it
// the page's nonce), unit tested in Node with a fake Node (dom-guard.test.ts).

export const DOM_GUARD_SCRIPT = `(function(w){try{
var N=w.Node;if(typeof N!=='function'||!N.prototype||w.__ccDomGuard)return;w.__ccDomGuard={rescued:0};
var P=N.prototype,rc=P.removeChild,ib=P.insertBefore;
P.removeChild=function(c){if(c&&c.parentNode!==this){w.__ccDomGuard.rescued++;return c;}return rc.apply(this,arguments);};
P.insertBefore=function(n,r){if(r&&r.parentNode!==this){w.__ccDomGuard.rescued++;return ib.call(this,n,null);}return ib.apply(this,arguments);};
}catch(e){}})(window);`;
