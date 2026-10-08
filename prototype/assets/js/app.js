/* CarmaCars prototype: core behaviour and shared components. Vanilla JS, no dependencies.
   CC.init(root) wires everything inside root, so the same code runs for separate
   page files and for the single-file build (where views are swapped by hash). */
(function () {
  'use strict';
  var CC = (window.CC = window.CC || {});
  CC.SINGLE = !!window.CC_SINGLE;
  CC.TODAY = (window.CC_FLEET && window.CC_FLEET.today) || '2026-10-15';
  document.documentElement.classList.add('js');
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)');

  /* ---------- tiny helpers ---------- */
  var $ = (CC.$ = function (s, r) { return (r || document).querySelector(s); });
  var $$ = (CC.$$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); });
  CC.on = function (el, ev, fn, o) { if (el) el.addEventListener(ev, fn, o); };
  CC.esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };
  CC.money = function (n, cents) {
    var v = Math.round(n * 100) / 100;
    var show = cents || Math.round(v * 100) % 100 !== 0;
    return '$' + v.toLocaleString('en-CA', { minimumFractionDigits: show ? 2 : 0, maximumFractionDigits: 2 });
  };

  /* ---------- routing abstraction (page files vs single file) ---------- */
  // 'fleet.html?from=..#rates' stays as is for page files. In the single file it
  // becomes '#/fleet.html?from=..~rates'.
  CC.url = function (u) {
    if (!CC.SINGLE || /^(https?:|mailto:|tel:|#)/.test(u)) return u;
    var a = u.split('#');
    return '#/' + a[0] + (a[1] ? '~' + a[1] : '');
  };
  CC.route = function () {
    if (!CC.SINGLE) return { page: (location.pathname.split('/').pop() || 'index.html'), query: location.search.slice(1), anchor: location.hash.slice(1) };
    var h = location.hash.replace(/^#\/?/, '');
    var anchor = ''; var t = h.indexOf('~'); if (t > -1) { anchor = h.slice(t + 1); h = h.slice(0, t); }
    var q = ''; var i = h.indexOf('?'); if (i > -1) { q = h.slice(i + 1); h = h.slice(0, i); }
    h = h.replace(/\/+$/, ''); if (h && !/\.html$/.test(h)) h += '.html'; // '#/fleet' works as well as '#/fleet.html'
    return { page: h || 'index.html', query: q, anchor: anchor };
  };
  CC.params = function () { return new URLSearchParams(CC.route().query); };
  CC.go = function (u) { location.href = CC.url(u); };
  CC.setParams = function (obj) { // reflect state in the address bar without a reload
    var r = CC.route(); var p = new URLSearchParams();
    Object.keys(obj).forEach(function (k) { if (obj[k] !== '' && obj[k] != null && obj[k] !== false) p.set(k, obj[k]); });
    var q = p.toString(); var u = r.page + (q ? '?' + q : '');
    try { history.replaceState(null, '', CC.SINGLE ? CC.url(u) : u); } catch (e) { /* file:// may refuse; harmless */ }
  };
  CC.photo = function (src) { return (window.CC_PHOTOS && window.CC_PHOTOS[src]) || src; }; // single file: inlined images
  CC.store = {
    get: function (k) { try { return JSON.parse(localStorage.getItem(k)); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* private mode */ } },
    del: function (k) { try { localStorage.removeItem(k); } catch (e) { /* ignore */ } }
  };

  /* ---------- dates (ISO strings, no time zones involved) ---------- */
  var D = (CC.date = {});
  var MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  var DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  D.parse = function (iso) { var a = iso.split('-'); return new Date(Date.UTC(+a[0], +a[1] - 1, +a[2])); };
  D.iso = function (d) { return d.toISOString().slice(0, 10); };
  D.add = function (iso, n) { var d = D.parse(iso); d.setUTCDate(d.getUTCDate() + n); return D.iso(d); };
  D.diff = function (a, b) { return Math.round((D.parse(b) - D.parse(a)) / 864e5); };
  D.dow = function (iso) { return D.parse(iso).getUTCDay(); };
  D.short = function (iso) { var d = D.parse(iso); return DAYS[d.getUTCDay()].slice(0, 3) + ', ' + MONTHS[d.getUTCMonth()].slice(0, 3) + ' ' + d.getUTCDate(); };
  D.long = function (iso) { var d = D.parse(iso); return DAYS[d.getUTCDay()] + ', ' + MONTHS[d.getUTCMonth()] + ' ' + d.getUTCDate() + ', ' + d.getUTCFullYear(); };
  D.valid = function (iso) { return /^\d{4}-\d{2}-\d{2}$/.test(iso || '') && !isNaN(D.parse(iso)); };
  D.time = function (t) { var a = t.split(':'); var h = +a[0]; return ((h + 11) % 12 + 1) + ':' + a[1] + (h < 12 ? ' a.m.' : ' p.m.'); };
  D.overlaps = function (from, to, ranges) { return (ranges || []).some(function (r) { return from <= r[1] && to >= r[0]; }); };
  // Availability with times. A booking [start, end, startTime, endTime] blocks the car from the
  // turnaround time before its start to the turnaround time after its end (Admin > Policies).
  var hm = function (t) { var a = (t || '10:00').split(':'); return +a[0] * 60 + +a[1]; };
  D.at = function (iso, t) { return D.parse(iso).getTime() / 6e4 + hm(t); };
  D.blocks = function (booked) {
    var R = window.CC_FLEET.rules; var buf = R.turnaroundHours * 60;
    return (booked || []).map(function (b) { return [D.at(b[0], b[2] || R.sampleHandover) - buf, D.at(b[1], b[3] || R.sampleHandover) + buf]; });
  };
  D.clash = function (from, tf, to, tt, booked) { var a = D.at(from, tf); var z = D.at(to, tt); return D.blocks(booked).some(function (w) { return a < w[1] && z > w[0]; }); };
  // A day is free, fully blocked, or partly free: freeFrom (a block ends that day) and freeUntil (one starts).
  D.day = function (iso, booked) {
    var s = D.at(iso, '00:00'); var e = s + 1440; var st = null;
    D.blocks(booked).forEach(function (w) {
      if (w[0] <= s && w[1] >= e) { st = { full: true }; return; }
      if (w[0] < e && w[1] > s && !(st && st.full)) { st = st || {}; if (w[1] < e) st.freeFrom = w[1] - s; if (w[0] > s) st.freeUntil = w[0] - s; }
    });
    return st;
  };
  D.clock = function (m) { return D.time(String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0')); };
  // Problems with the chosen times: notice, and the turnaround around other bookings. '' when fine.
  D.timeProblem = function (car, from, tf, to, tt) {
    var R = window.CC_FLEET.rules; var F = window.CC_FLEET;
    if (D.at(from, tf) < D.at(F.today, F.now) + R.minNoticeHours * 60) return 'Pickup needs at least ' + CC.t('notice') + '’ notice. The earliest today is ' + D.clock(hm(F.now) + R.minNoticeHours * 60) + '.';
    if (car && D.clash(from, tf, to, tt, car.booked)) {
      var a = D.day(from, car.booked); var z = D.day(to, car.booked);
      if (a && a.freeFrom != null) return 'The ' + car.name + ' is free from ' + D.clock(a.freeFrom) + ' on ' + D.short(from) + ', ' + CC.t('turnaround') + ' after the booking before yours. Choose a later pickup time.';
      if (z && z.freeUntil != null) return 'The ' + car.name + ' has to be back by ' + D.clock(z.freeUntil) + ' on ' + D.short(to) + ', ' + CC.t('turnaround') + ' before the next booking. Choose an earlier return time.';
      return 'Those times cross another booking of the ' + car.name + '.';
    }
    return '';
  };

  /* ---------- pricing: the rate rule from the renter billing spec, section 2 ---------- */
  var P = (CC.pricing = {});
  // Policy numbers and their wording come from the data file (Admin > Pricing and Policies), never from this script.
  var RL = function () { return window.CC_FLEET.rules; }; var TK = (CC.t = function (k) { return window.CC_FLEET.tokens[k]; });
  P.round = function (n) { return Math.round((n + Number.EPSILON) * 100) / 100; };
  // Hours from pickup to return, divided by 24, rounded up. Minimum 1, maximum 30.
  P.days = function (from, tFrom, to, tTo) {
    var a = D.parse(from).getTime() + mins(tFrom) * 6e4; var b = D.parse(to).getTime() + mins(tTo) * 6e4;
    var raw = Math.ceil((b - a) / 36e5 / 24);
    return { days: Math.max(1, raw), over: raw > RL().maxDays, invalid: b <= a };
  };
  function mins(t) { var a = (t || '10:00').split(':'); return +a[0] * 60 + +a[1]; }
  P.rental = function (rates, from, days) {
    if (days >= RL().maxDays) return { amount: rates.monthly, basis: 'Monthly rate (' + RL().maxDays + ' days)', capped: false };
    if (days >= RL().weeklyFromDays) {
      var w = P.round(rates.weekly / 7 * days);
      if (w > rates.monthly) return { amount: rates.monthly, basis: days + ' days at the weekly rate, capped at the monthly rate', capped: true };
      return { amount: w, basis: days + ' days at ' + CC.money(rates.weekly) + ' a week (' + CC.money(P.round(rates.weekly / 7), true) + ' a day)', capped: false };
    }
    var nd = 0; var nw = 0; var start = D.dow(from);
    for (var i = 0; i < days; i++) { var dw = (start + i) % 7; if (dw === 5 || dw === 6) nw++; else nd++; }
    var sum = nd * rates.daily + nw * rates.weekend; var parts = [];
    if (nd) parts.push(nd + ' ' + (nd === 1 ? 'day' : 'days') + ' at ' + CC.money(rates.daily));
    if (nw) parts.push(nw + ' weekend ' + (nw === 1 ? 'day' : 'days') + ' at ' + CC.money(rates.weekend));
    if (sum > rates.weekly) return { amount: rates.weekly, basis: parts.join(' + ') + ', capped at the weekly rate', capped: true };
    return { amount: sum, basis: parts.join(' + '), capped: false };
  };
  // Estimate shown before a request. Charges and caps are the Schedule of Fees defaults.
  P.estimate = function (car, s) {
    var R = window.CC_FLEET.rules; var d = P.days(s.from, s.tFrom, s.to, s.tTo); var days = Math.min(d.days, R.maxDays);
    var rent = P.rental(car.rates, s.from, days); var lines = [];
    lines.push({ k: 'Rental charge', note: rent.basis, v: rent.amount });
    var discount = s.nonRefundable ? P.round(rent.amount * R.nonRefundableDiscount) : 0;
    if (discount) lines.push({ k: 'Non-refundable booking, ' + TK('nonRef') + ' off', v: -discount });
    var dist = 'Plus distance from our location, priced in your offer'; var air = '. An airport surcharge may apply';
    if (s.deliver) lines.push({ k: s.deliverKind === 'airport' ? 'Delivery to the airport' : 'Delivery to you', note: dist + (s.deliverKind === 'airport' ? air : ''), v: car.delivery });
    if (s.collect) lines.push({ k: s.collectKind === 'airport' ? 'Pickup at the airport at the end' : 'Pickup from you at the end', note: dist + (s.collectKind === 'airport' ? air : ''), v: car.delivery });
    var yf = car.youngFees && car.youngFees[s.age]; // per day, no maximum; set per car
    if (yf) lines.push({ k: 'Young driver fee, ages ' + s.age.replace('-', ' to '), note: CC.money(yf) + ' a day, no maximum', v: yf * days });
    if (s.addDrivers) { var per = P.round(car.rates.daily * R.additionalDriverPct); lines.push({ k: 'Additional driver' + (s.addDrivers > 1 ? 's (' + s.addDrivers + ')' : ''), note: CC.money(per, true) + ' a day each, ' + TK('addDrvPct') + ' of the daily rate', v: P.round(s.addDrivers * per * days) }); }
    if (s.winter) lines.push({ k: 'Winter tires', note: TK('winter') + ' a day, up to ' + TK('winterCap'), v: Math.min(R.winterTire.perDay * days, R.winterTire.cap) });
    if (s.babySeats) lines.push({ k: 'Baby seat' + (s.babySeats > 1 ? 's (' + s.babySeats + ')' : ''), note: TK('baby') + ' a day each, up to ' + TK('babyCap') + ' each', v: s.babySeats * Math.min(R.babySeat.perDay * days, R.babySeat.cap) });
    var sub = P.round(lines.reduce(function (t, l) { return t + l.v; }, 0)); var hst = P.round(sub * R.hst);
    return { days: days, over: d.over, invalid: d.invalid, lines: lines, subtotal: sub, hst: hst, total: P.round(sub + hst), deposit: car.deposit, depositMethod: days <= R.depositHoldMaxDays ? 'card hold' : 'charged, then refunded', km: car.kmPerDay * days, coverageExtra: s.coverage === '3' };
  };

  /* ---------- number tween (used for totals) ---------- */
  CC.tween = function (el, to, fmt) {
    var from = parseFloat(el.dataset.v || '0'); el.dataset.v = to;
    if (reduce.matches || from === to || !('requestAnimationFrame' in window)) { el.textContent = fmt(to); return; }
    var t0 = performance.now(); var dur = 380;
    (function step(now) { var k = Math.min(1, (now - t0) / dur); k = 1 - Math.pow(1 - k, 3); el.textContent = fmt(from + (to - from) * k); if (k < 1 && el.dataset.v == to) requestAnimationFrame(step); else el.textContent = fmt(parseFloat(el.dataset.v)); })(t0);
  };

  /* ---------- toast ---------- */
  CC.toast = function (msg, ms) {
    var box = $('.toasts'); if (!box) { box = document.createElement('div'); box.className = 'toasts'; box.setAttribute('role', 'status'); box.setAttribute('aria-live', 'polite'); document.body.appendChild(box); }
    var t = document.createElement('div'); t.className = 'toast'; t.innerHTML = '<span>' + CC.esc(msg) + '</span><button type="button" aria-label="Dismiss">×</button>';
    var kill = function () { t.classList.add('is-out'); setTimeout(function () { t.remove(); }, 250); };
    t.querySelector('button').onclick = kill; box.appendChild(t); setTimeout(kill, ms || 4500);
  };

  /* ---------- calendar (single or range, keyboard usable) ---------- */
  CC.Calendar = function (root, o) {
    o = Object.assign({ months: 1, min: CC.TODAY, booked: [], from: '', to: '', maxDays: window.CC_FLEET.rules.maxDays, onChange: function () {} }, o);
    var view = (o.from || o.min).slice(0, 7); var focus = o.from || o.min; var self = { from: o.from, to: o.to };
    var uid = 'cal' + Math.random().toString(36).slice(2, 7);
    root.classList.add('cal'); if (o.months === 2) root.classList.add('cal--two');
    root.innerHTML = '<div class="cal__head"><button type="button" class="icon-btn" data-nav="-1" aria-label="Previous month"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M12.5 4l-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2"/></svg></button><div class="cal__title" id="' + uid + '" aria-live="polite"></div><button type="button" class="icon-btn" data-nav="1" aria-label="Next month"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M7.5 4l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2"/></svg></button></div><div class="cal__months"></div>' +
      '<p class="cal__status" role="status" aria-live="polite"></p>' +
      (o.legend === false ? '' : '<div class="cal__legend" aria-hidden="true"><span><i class="k-sel"></i>Your dates</span><span><i class="k-booked"></i>Not available</span><span><i class="k-part"></i>Part of the day</span><span><i class="k-open"></i>Available</span></div>');
    var monthsEl = $('.cal__months', root); var title = $('.cal__title', root); var status = $('.cal__status', root);
    var isBooked = function (iso) { var d = D.day(iso, o.booked); return !!(d && d.full); };
    var partOf = function (iso) { var d = D.day(iso, o.booked); return d && !d.full ? d : null; };
    var crosses = function (a, z) { var x = partOf(a); var y = partOf(z); if ((x && x.freeUntil != null) || (y && y.freeFrom != null)) return true; for (var d = D.add(a, 1); d < z; d = D.add(d, 1)) if (D.day(d, o.booked)) return true; return false; };
    var partText = function (p) { return p.freeFrom != null && p.freeUntil != null ? 'free from ' + D.clock(p.freeFrom) + ' to ' + D.clock(p.freeUntil) : p.freeFrom != null ? 'free from ' + D.clock(p.freeFrom) : 'free until ' + D.clock(p.freeUntil); };
    var ym = function (s, n) { var y = +s.slice(0, 4); var m = +s.slice(5, 7) - 1 + n; y += Math.floor(m / 12); m = ((m % 12) + 12) % 12; return y + '-' + String(m + 1).padStart(2, '0'); };
    function monthHTML(m) {
      var y = +m.slice(0, 4); var mo = +m.slice(5, 7) - 1; var first = new Date(Date.UTC(y, mo, 1)).getUTCDay(); var n = new Date(Date.UTC(y, mo + 1, 0)).getUTCDate();
      var h = '<div><div class="cal__month-name">' + MONTHS[mo] + ' ' + y + '</div><table role="grid" aria-labelledby="' + uid + '"><thead><tr>' + ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'].map(function (d, i) { return '<th scope="col" abbr="' + DAYS[i] + '">' + d + '</th>'; }).join('') + '</tr></thead><tbody><tr>';
      for (var i = 0; i < first; i++) h += '<td></td>';
      for (var d = 1; d <= n; d++) {
        var iso = m + '-' + String(d).padStart(2, '0'); var cls = ['cal__day']; var dis = false; var label = D.long(iso);
        if (iso < o.min) { cls.push('is-past'); dis = true; label += ', in the past'; }
        else if (isBooked(iso)) { cls.push('is-booked'); dis = true; label += ', not available'; }
        else if (partOf(iso)) { cls.push('is-part'); label += ', partly available, ' + partText(partOf(iso)); }
        if (iso === CC.TODAY) cls.push('is-today');
        if (self.from && iso === self.from) { cls.push('is-start'); label += ', pickup date'; }
        if (self.to && iso === self.to) { cls.push('is-end'); label += ', return date'; }
        if (self.from && self.to && iso > self.from && iso < self.to) cls.push('is-in');
        h += '<td><button type="button" class="' + cls.join(' ') + '" data-date="' + iso + '" tabindex="' + (iso === focus ? 0 : -1) + '" aria-label="' + label + '"' + (dis ? ' aria-disabled="true"' : '') + (cls.indexOf('is-start') > -1 || cls.indexOf('is-end') > -1 ? ' aria-pressed="true"' : '') + '>' + d + '</button></td>';
        if ((first + d) % 7 === 0 && d < n) h += '</tr><tr>';
      }
      return h + '</tr></tbody></table></div>';
    }
    function render(keepFocus) {
      if (focus < view + '-01') view = focus.slice(0, 7);
      var last = ym(view, o.months - 1); if (focus.slice(0, 7) > last) view = ym(focus.slice(0, 7), -(o.months - 1));
      var h = ''; for (var i = 0; i < o.months; i++) h += monthHTML(ym(view, i));
      monthsEl.innerHTML = h;
      var a = +view.slice(5, 7) - 1; title.textContent = o.months === 1 ? MONTHS[a] + ' ' + view.slice(0, 4) : MONTHS[a] + ' and ' + MONTHS[(a + 1) % 12];
      $('[data-nav="-1"]', root).disabled = view <= o.min.slice(0, 7);
      if (!monthsEl.querySelector('[tabindex="0"]')) { var f = monthsEl.querySelector('.cal__day:not(.is-past)') || monthsEl.querySelector('.cal__day'); if (f) f.tabIndex = 0; }
      if (keepFocus) { var b = monthsEl.querySelector('[data-date="' + focus + '"]'); if (b) b.focus(); }
    }
    function say(msg, bad) { status.textContent = msg || ''; status.classList.toggle('red', !!bad); status.classList.toggle('strong', !!bad); }
    function pick(iso) {
      if (iso < o.min) return say('That date has passed.', true);
      if (isBooked(iso)) return say(D.short(iso) + ' is not available for this car.', true);
      if (!self.from || self.to || iso < self.from) { self.from = iso; self.to = ''; var pp = partOf(iso); say('Pickup ' + D.short(iso) + (pp ? ', ' + partText(pp) : '') + '. Now pick a return date.'); }
      else {
        if (crosses(self.from, iso)) return say('Those dates cross another booking. Pick an earlier return date, or start after it.', true);
        if (D.diff(self.from, iso) > o.maxDays) return say('One booking covers up to ' + o.maxDays + ' days. For longer, you renew with a new booking.', true);
        self.to = iso; var n = Math.max(1, D.diff(self.from, iso)); var zp = partOf(iso); say(D.short(self.from) + ' to ' + D.short(iso) + ', ' + n + (n === 1 ? ' day' : ' days') + '.' + (zp ? ' On ' + D.short(iso) + ' the car is ' + partText(zp) + '.' : ''));
      }
      focus = iso; render(true); o.onChange({ from: self.from, to: self.to });
    }
    root.addEventListener('click', function (e) {
      var nav = e.target.closest('[data-nav]'); if (nav) { view = ym(view, +nav.dataset.nav); focus = view + '-01'; if (focus < o.min) focus = o.min; render(); return; }
      var day = e.target.closest('[data-date]'); if (day) pick(day.dataset.date);
    });
    root.addEventListener('keydown', function (e) {
      var day = e.target.closest('[data-date]'); if (!day) return;
      var step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }[e.key]; var next;
      if (step) next = D.add(day.dataset.date, step);
      else if (e.key === 'PageDown') next = D.add(day.dataset.date, 28);
      else if (e.key === 'PageUp') next = D.add(day.dataset.date, -28);
      else if (e.key === 'Home') next = D.add(day.dataset.date, -D.dow(day.dataset.date));
      else if (e.key === 'End') next = D.add(day.dataset.date, 6 - D.dow(day.dataset.date));
      if (next) { e.preventDefault(); if (next < o.min) next = o.min; focus = next; render(true); }
    });
    self.set = function (from, to) { self.from = from || ''; self.to = to || ''; if (from) { focus = from; view = from.slice(0, 7); } render(); };
    self.setBooked = function (b) { o.booked = b || []; render(); };
    self.focus = function () { var b = monthsEl.querySelector('[tabindex="0"]'); if (b) b.focus(); };
    self.say = say;
    render();
    if (self.from && self.to) { var n0 = Math.max(1, D.diff(self.from, self.to)); say(D.short(self.from) + ' to ' + D.short(self.to) + ', ' + n0 + (n0 === 1 ? ' day' : ' days') + '.'); }
    return self;
  };

  /* ---------- date range field: two buttons, one popover calendar ---------- */
  CC.DateRange = function (el, o) {
    o = o || {}; var pop = $('.popover', el); var calEl = $('[data-cal]', el); var btns = $$('[data-dr]', el);
    var inFrom = $('input[name="from"]', el); var inTo = $('input[name="to"]', el); var scrim; var opener;
    var p = CC.params();
    if (!inFrom.value && D.valid(p.get('from'))) inFrom.value = p.get('from');
    if (!inTo.value && D.valid(p.get('to'))) inTo.value = p.get('to');
    var cal = CC.Calendar(calEl, { months: window.matchMedia('(max-width: 43.99rem)').matches ? 1 : 2, from: inFrom.value, to: inTo.value, booked: o.booked || [], onChange: function (v) { inFrom.value = v.from; inTo.value = v.to; paint(); if (o.onChange) o.onChange(v); } });
    function paint() {
      btns.forEach(function (b) { var v = b.dataset.dr === 'from' ? inFrom.value : inTo.value; var s = $('span', b); s.textContent = v ? D.short(v) : b.dataset.empty; b.classList.toggle('is-empty', !v); });
      var f = el.closest('.field') || el; f.classList.remove('has-error');
    }
    var home = pop.parentNode;
    function open(b) {
      opener = b; pop.hidden = false; btns.forEach(function (x) { x.setAttribute('aria-expanded', 'true'); });
      if (window.matchMedia('(max-width: 43.99rem)').matches) { // phone: a bottom sheet, lifted to <body> so no parent stacking context can trap it
        scrim = document.createElement('div'); scrim.className = 'popover-scrim'; scrim.onclick = close; document.body.appendChild(scrim); document.body.appendChild(pop); document.body.style.overflow = 'hidden';
      } else { pop.style.left = '0px'; var r = el.getBoundingClientRect(); pop.style.left = Math.min(0, window.innerWidth - r.left - pop.offsetWidth - 16) + 'px'; }
      cal.focus(); document.addEventListener('mousedown', outside); document.addEventListener('keydown', esc);
    }
    function close() { if (pop.hidden) return; pop.hidden = true; btns.forEach(function (x) { x.setAttribute('aria-expanded', 'false'); }); if (scrim) { scrim.remove(); scrim = null; home.appendChild(pop); document.body.style.overflow = ''; } document.removeEventListener('mousedown', outside); document.removeEventListener('keydown', esc); if (opener && document.contains(opener)) opener.focus(); }
    CC.onCleanup(function () { close(); if (pop.parentNode === document.body) pop.remove(); });
    function outside(e) { if (!el.contains(e.target) && !pop.contains(e.target)) close(); }
    function esc(e) { if (e.key === 'Escape') { e.stopPropagation(); close(); } }
    btns.forEach(function (b) { b.setAttribute('aria-haspopup', 'dialog'); b.setAttribute('aria-expanded', 'false'); b.addEventListener('click', function () { pop.hidden ? open(b) : close(); }); });
    CC.on($('[data-dr-done]', el), 'click', close);
    CC.on($('[data-dr-clear]', el), 'click', function () { inFrom.value = ''; inTo.value = ''; cal.set('', ''); cal.say(''); paint(); if (o.onChange) o.onChange({ from: '', to: '' }); });
    paint();
    return { cal: cal, close: close, value: function () { return { from: inFrom.value, to: inTo.value }; }, set: function (f, t) { inFrom.value = f; inTo.value = t; cal.set(f, t); paint(); } };
  };

  /* ---------- header + mobile menu (wired once) ---------- */
  function header() {
    var btn = $('.menu-btn'); var panel = $('.menu-panel'); if (!btn || !panel) return;
    var setOpen = function (open) {
      btn.setAttribute('aria-expanded', open); panel.classList.toggle('is-open', open); btn.querySelector('span').textContent = open ? 'Close' : 'Menu';
      document.body.style.overflow = open ? 'hidden' : ''; panel.inert = !open; if (open) { var a = $('a', panel); if (a) a.focus(); }
    };
    panel.inert = true;
    btn.addEventListener('click', function () { setOpen(btn.getAttribute('aria-expanded') !== 'true'); });
    panel.addEventListener('click', function (e) { if (e.target.closest('a')) setOpen(false); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && btn.getAttribute('aria-expanded') === 'true') { setOpen(false); btn.focus(); } });
    window.matchMedia('(min-width: 64rem)').addEventListener('change', function () { setOpen(false); });
    CC.closeMenu = function () { setOpen(false); };
  }
  CC.markNav = function (page) {
    var key = /^car-/.test(page) ? 'fleet.html' : page;
    $$('.site-header a[data-nav], .menu-panel a[data-nav]').forEach(function (a) { if (a.dataset.nav === key) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current'); });
  };

  /* ---------- per-view initialisers ---------- */
  var inits = (CC.inits = []);
  var cleanups = [];
  CC.onCleanup = function (fn) { cleanups.push(fn); };
  CC.init = function (root) {
    cleanups.splice(0).forEach(function (fn) { try { fn(); } catch (e) { /* ignore */ } });
    inits.forEach(function (fn) { fn(root || document); });
  };

  // Scroll effects fallback: browsers without scroll-driven animations get an
  // IntersectionObserver that adds .is-in once.
  inits.push(function (root) {
    var native = window.CSS && CSS.supports && CSS.supports('animation-timeline: view()');
    var els = $$('.fx-wipe, .fx-line, .fx-grow-y', root);
    if (native || reduce.matches || !('IntersectionObserver' in window)) { els.forEach(function (e) { e.classList.add('is-in'); }); return; }
    var io = new IntersectionObserver(function (es) { es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('is-in'); io.unobserve(e.target); } }); }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });
    els.forEach(function (e) { io.observe(e); }); CC.onCleanup(function () { io.disconnect(); });
  });

  // Horizontal rail: buttons, keyboard, progress fallback.
  inits.push(function (root) {
    $$('[data-rail]', root).forEach(function (wrap) {
      var rail = $('.rail', wrap); var prev = $('[data-rail-prev]', wrap); var next = $('[data-rail-next]', wrap); var bar = $('.rail-progress i', wrap);
      var native = window.CSS && CSS.supports && CSS.supports('animation-timeline: scroll()');
      var step = function () { var c = rail.firstElementChild; return c ? c.getBoundingClientRect().width + parseFloat(getComputedStyle(rail).columnGap || 0) : 300; };
      var ticking = false;
      var sync = function () {
        ticking = false; var max = rail.scrollWidth - rail.clientWidth; var k = max > 0 ? rail.scrollLeft / max : 0;
        if (prev) prev.disabled = rail.scrollLeft < 4; if (next) next.disabled = rail.scrollLeft > max - 4;
        if (bar && !native) bar.style.transform = 'scaleX(' + Math.max(0.08, k) + ')';
      };
      rail.addEventListener('scroll', function () { if (!ticking) { ticking = true; requestAnimationFrame(sync); } }, { passive: true });
      CC.on(prev, 'click', function () { rail.scrollBy({ left: -step(), behavior: reduce.matches ? 'auto' : 'smooth' }); });
      CC.on(next, 'click', function () { rail.scrollBy({ left: step(), behavior: reduce.matches ? 'auto' : 'smooth' }); });
      sync();
    });
  });

  // Tabs
  inits.push(function (root) {
    $$('[role="tablist"]', root).forEach(function (list) {
      var tabs = $$('[role="tab"]', list);
      var select = function (t, focus) { tabs.forEach(function (x) { var on = x === t; x.setAttribute('aria-selected', on); x.tabIndex = on ? 0 : -1; var p = document.getElementById(x.getAttribute('aria-controls')); if (p) p.hidden = !on; }); if (focus) t.focus(); };
      tabs.forEach(function (t, i) {
        t.addEventListener('click', function () { select(t); });
        t.addEventListener('keydown', function (e) { var d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0; if (d) { e.preventDefault(); select(tabs[(i + d + tabs.length) % tabs.length], true); } });
      });
    });
  });

  // Modal open/close by attribute; toast triggers; prototype toggles.
  inits.push(function (root) {
    $$('[data-modal-open]', root).forEach(function (b) { b.addEventListener('click', function () { var d = document.getElementById(b.dataset.modalOpen); if (d && d.showModal) d.showModal(); }); });
    $$('dialog.modal', root).forEach(function (d) {
      d.addEventListener('click', function (e) { if (e.target === d || e.target.closest('[data-modal-close]')) d.close(); });
    });
    $$('[data-toast]', root).forEach(function (b) { b.addEventListener('click', function () { CC.toast(b.dataset.toast); }); });
    $$('[data-toggle-state]', root).forEach(function (sw) {
      var apply = function () { var g = sw.dataset.toggleState; $$('[data-state-of="' + g + '"]', root).forEach(function (el) { el.hidden = (el.dataset.state === 'on') !== sw.checked; }); };
      sw.addEventListener('change', apply); apply();
    });
    $$('.range', root).forEach(function (r) { var f = function () { r.style.setProperty('--fill', ((r.value - r.min) / (r.max - r.min) * 100) + '%'); }; r.addEventListener('input', f); f(); });
    $$('.qty', root).forEach(function (q) {
      var out = $('output', q); var inp = $('input', q); var min = +q.dataset.min || 0; var max = +q.dataset.max || 9; var b = $$('button', q);
      var set = function (v) { v = Math.max(min, Math.min(max, v)); out.textContent = v; if (inp) { inp.value = v; inp.dispatchEvent(new Event('change', { bubbles: true })); } b[0].disabled = v <= min; b[1].disabled = v >= max; };
      b[0].addEventListener('click', function () { set(+out.textContent - 1); }); b[1].addEventListener('click', function () { set(+out.textContent + 1); });
      q._set = set; set(+(inp && inp.value) || min);
    });
  });

  // FAQ filter (FAQ page)
  inits.push(function (root) {
    var box = $('[data-faq-filter]', root); if (!box) return;
    var items = $$('.faq details', root); var groups = $$('[data-faq-group]', root); var none = $('[data-faq-none]', root);
    box.addEventListener('input', function () {
      var q = box.value.trim().toLowerCase(); var hits = 0;
      items.forEach(function (d) { var hit = !q || d.textContent.toLowerCase().indexOf(q) > -1; d.hidden = !hit; if (hit) hits++; });
      groups.forEach(function (g) { g.hidden = !$$('details:not([hidden])', g).length; });
      none.hidden = hits > 0; $('[data-faq-count]', root).textContent = q ? hits + (hits === 1 ? ' answer' : ' answers') : '';
    });
  });

  // Simple forms with inline validation (contact, owner application, sign in).
  CC.validators = {
    required: function (v) { return v.trim() ? '' : 'This is needed.'; },
    email: function (v) { return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v.trim()) ? '' : 'Enter an email address like name@example.com.'; },
    phone: function (v) { return v.replace(/\D/g, '').length >= 10 ? '' : 'Enter a phone number with area code.'; },
    year: function (v) { var y = +v; return y >= 1990 && y <= 2027 ? '' : 'Enter the model year, for example 2021.'; },
    password: function (v) { return v.length >= 8 ? '' : 'Use at least 8 characters.'; }
  };
  CC.checkField = function (inp) {
    var field = inp.closest('.field'); if (!field) return true; var rules = (inp.dataset.v || '').split(' ').filter(Boolean); var msg = '';
    if (inp.type === 'checkbox') { if (rules.length && !inp.checked) msg = inp.dataset.msg || 'Tick this box to continue.'; }
    else if (rules.indexOf('required') === -1 && !inp.value.trim()) msg = '';
    else for (var i = 0; i < rules.length && !msg; i++) msg = CC.validators[rules[i]] ? CC.validators[rules[i]](inp.value) : '';
    if (msg && inp.dataset.msg && !inp.value.trim()) msg = inp.dataset.msg;
    var err = $('.error', field); field.classList.toggle('has-error', !!msg); field.classList.toggle('is-ok', !msg && !!inp.value.trim() && inp.type !== 'checkbox' && inp.tagName === 'INPUT');
    if (err) { err.textContent = msg; if (msg) { err.id = err.id || 'e' + Math.random().toString(36).slice(2, 8); inp.setAttribute('aria-describedby', err.id); inp.setAttribute('aria-invalid', 'true'); } else { inp.removeAttribute('aria-invalid'); } }
    return !msg;
  };
  CC.checkAll = function (scope) {
    var bad = null; $$('[data-v]', scope).forEach(function (i) { if (i.closest('[hidden]')) return; if (!CC.checkField(i) && !bad) bad = i; });
    if (bad) bad.focus({ preventScroll: false }); return !bad;
  };
  inits.push(function (root) {
    $$('[data-v]', root).forEach(function (i) {
      i.addEventListener('blur', function () { if (i.value || i.closest('.field').classList.contains('has-error')) CC.checkField(i); });
      i.addEventListener('input', function () { if (i.closest('.field').classList.contains('has-error')) CC.checkField(i); });
      i.addEventListener('change', function () { if (i.type === 'checkbox' || i.tagName === 'SELECT') CC.checkField(i); });
    });
    $$('form[data-simple-form]', root).forEach(function (f) {
      f.setAttribute('novalidate', '');
      f.addEventListener('submit', function (e) {
        e.preventDefault(); if (!CC.checkAll(f)) return;
        var done = document.getElementById(f.dataset.simpleForm);
        if (done) { f.hidden = true; done.hidden = false; done.setAttribute('tabindex', '-1'); done.focus(); } else CC.toast(f.dataset.toastMsg || 'Sent.');
      });
    });
  });

  // Hero search and any other form that carries dates to the fleet page.
  inits.push(function (root) {
    $$('form[data-search]', root).forEach(function (f) {
      var dr = CC.DateRange($('[data-daterange]', f));
      f.addEventListener('submit', function (e) {
        e.preventDefault(); var v = dr.value(); var q = new URLSearchParams();
        if (v.from && !v.to) { var field = $('[data-daterange]', f).closest('.field'); field.classList.add('has-error'); $('.error', field).textContent = 'Add a return date, or clear the dates to see every car.'; return; }
        if (v.from) { q.set('from', v.from); q.set('to', v.to); q.set('tf', f.elements.tf.value); q.set('tt', f.elements.tt.value); }
        var mode = f.elements.mode ? f.elements.mode.value : ''; if (mode === 'delivery') q.set('mode', 'delivery');
        var s = q.toString(); CC.go('fleet.html' + (s ? '?' + s : ''));
      });
    });
  });

  // In-page anchors in the single file must not change the route.
  document.addEventListener('click', function (e) {
    var a = e.target.closest('a[data-anchor]'); if (!a) return;
    var t = document.getElementById(a.dataset.anchor); if (!t) return;
    e.preventDefault(); t.scrollIntoView({ behavior: reduce.matches ? 'auto' : 'smooth', block: 'start' }); if (!t.hasAttribute('tabindex')) t.setAttribute('tabindex', '-1'); t.focus({ preventScroll: true });
  });

  /* ---------- featured cars: a random pick on each visit ---------- */
  inits.push(function (root) {
    $$('[data-featured]', root).forEach(function (ul) {
      var lis = $$('[data-feature]', ul); var n = Math.min(+ul.dataset.featured, lis.length); var idx = lis.map(function (_, i) { return i; });
      for (var i = idx.length - 1; i > 0; i--) { var j = Math.floor(Math.random() * (i + 1)); var t = idx[i]; idx[i] = idx[j]; idx[j] = t; }
      var keep = idx.slice(0, n); var end = $('.rail__end', ul);
      lis.forEach(function (li, k) { li.hidden = keep.indexOf(k) < 0; });
      keep.forEach(function (k) { ul.insertBefore(lis[k], end); });
    });
  });

  /* ---------- address lookup while typing ---------- */
  // PROTOTYPE: suggestions come from a small SAMPLE list (CC_FLEET.addressSamples).
  // Production asks a maps service as the person types and keeps the same markup.
  CC.addressLookup = function (inp) {
    if (inp._lookup) return; inp._lookup = true;
    var list = document.createElement('ul'); list.className = 'lookup'; list.id = inp.id + '-list'; list.setAttribute('role', 'listbox'); list.setAttribute('aria-label', 'Address suggestions'); list.hidden = true;
    inp.setAttribute('aria-controls', list.id); inp.insertAdjacentElement('afterend', list);
    var items = []; var idx = -1; var all = (window.CC_FLEET && window.CC_FLEET.addressSamples) || [];
    function render() {
      list.innerHTML = items.map(function (a, i) { return '<li role="option" id="' + list.id + '-' + i + '" aria-selected="' + (i === idx) + '">' + CC.esc(a) + '</li>'; }).join('') + (items.length ? '<li class="lookup__note" role="presentation">Sample addresses in this prototype</li>' : '');
      list.hidden = !items.length; inp.setAttribute('aria-expanded', items.length ? 'true' : 'false');
      if (idx > -1) inp.setAttribute('aria-activedescendant', list.id + '-' + idx); else inp.removeAttribute('aria-activedescendant');
    }
    function search() { var q = inp.value.trim().toLowerCase(); var words = q.split(/[\s,]+/).filter(Boolean); idx = -1; items = q.length < 2 ? [] : all.filter(function (a) { var l = a.toLowerCase(); return words.every(function (w) { return l.indexOf(w) > -1; }); }).slice(0, 6); render(); }
    function choose(i) { if (i < 0 || !items[i]) return; inp.value = items[i]; items = []; idx = -1; render(); inp.dispatchEvent(new Event('change', { bubbles: true })); }
    inp.addEventListener('input', search);
    inp.addEventListener('keydown', function (e) {
      if (list.hidden) return;
      if (e.key === 'ArrowDown') { e.preventDefault(); idx = Math.min(items.length - 1, idx + 1); render(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); idx = Math.max(0, idx - 1); render(); }
      else if (e.key === 'Enter' && idx > -1) { e.preventDefault(); choose(idx); }
      else if (e.key === 'Escape') { e.preventDefault(); items = []; render(); }
    });
    list.addEventListener('mousedown', function (e) { var li = e.target.closest('[role="option"]'); if (li) { e.preventDefault(); choose(+li.id.split('-').pop()); } });
    inp.addEventListener('blur', function () { setTimeout(function () { items = []; idx = -1; render(); }, 120); });
  };
  inits.push(function (root) { $$('input[data-addr-lookup]', root).forEach(CC.addressLookup); });

  /* ---------- cookie consent ---------- */
  // Remembered for the browser session in the prototype. Production stores the answer with
  // public.record_cookie_choice(visitor, choice, wording version, analytics) and loads
  // analytics only when analytics is true.
  var CK = 'cc.cookies';
  CC.cookieChoice = function () { try { var v = JSON.parse(sessionStorage.getItem(CK)); var C = window.CC_FLEET.cookies; return v && v.version === C.version ? v : null; } catch (e) { return null; } };
  function cookieSave(choice, analytics) {
    var C = window.CC_FLEET.cookies; var v = { version: C.version, choice: choice, analytics: !!analytics, at: Date.now() };
    try { sessionStorage.setItem(CK, JSON.stringify(v)); } catch (e) { /* private mode: asks again next page */ }
    window.CC_CONSENT = v; var b = $('.cookie'); if (b) b.remove();
    CC.toast(analytics ? 'Saved. Analytics cookies are on.' : 'Saved. Only necessary cookies are used.');
  }
  function cookieDialog(opener) {
    var C = window.CC_FLEET.cookies; var cur = CC.cookieChoice(); var d = $('#cookie-prefs');
    if (!d) {
      d = document.createElement('dialog'); d.className = 'modal'; d.id = 'cookie-prefs'; d.setAttribute('aria-labelledby', 'ck-pt');
      d.innerHTML = '<div class="modal__head"><h2 class="d3" id="ck-pt">' + CC.esc(C.title) + '</h2><button type="button" class="modal__close" data-ck-close aria-label="Close">×</button></div><div class="modal__body stack"><p class="small">' + CC.esc(C.text) + '</p>' +
        C.groups.map(function (g) { return '<label class="check cookie__opt"><input type="checkbox" name="' + g.code + '"' + (g.always ? ' checked disabled' : '') + '><span><b>' + CC.esc(g.name) + '</b><br><span class="small muted">' + CC.esc(g.text) + '</span></span></label>'; }).join('') +
        '</div><div class="modal__foot"><button type="button" class="btn btn--ghost" data-ck-necessary>' + CC.esc(C.necessary) + '</button><button type="button" class="btn btn--primary" data-ck-save>' + CC.esc(C.save) + '</button></div>';
      document.body.appendChild(d);
      d.addEventListener('click', function (e) {
        if (e.target === d || e.target.closest('[data-ck-close]')) d.close();
        if (e.target.closest('[data-ck-save]')) { cookieSave('custom', $('[name="analytics_cookies"]', d).checked); d.close(); }
        if (e.target.closest('[data-ck-necessary]')) { cookieSave('necessary_only', false); d.close(); }
      });
      d.addEventListener('close', function () { var o = d._opener; if (o && document.contains(o)) o.focus(); });
    }
    $('[name="analytics_cookies"]', d).checked = !!(cur && cur.analytics); d._opener = opener;
    if (d.showModal) d.showModal();
  }
  function cookieBanner() {
    var C = window.CC_FLEET && window.CC_FLEET.cookies; if (!C) return;
    document.addEventListener('click', function (e) { var b = e.target.closest('[data-cookie-prefs]'); if (b) cookieDialog(b); });
    var have = CC.cookieChoice(); if (have) { window.CC_CONSENT = have; return; }
    var box = document.createElement('section'); box.className = 'cookie on-dark'; box.setAttribute('aria-labelledby', 'ck-t');
    box.innerHTML = '<div class="cookie__in"><div class="cookie__text"><h2 class="d4" id="ck-t">' + CC.esc(C.title) + '</h2><p class="small">' + CC.esc(C.text) + ' <a class="link" href="' + CC.url('privacy.html#cookies-and-analytics') + '">How we use cookies</a></p></div>' +
      '<div class="cookie__btns"><button type="button" class="btn btn--quiet btn--sm" data-ck-prefs>' + CC.esc(C.prefs) + '</button><button type="button" class="btn btn--light btn--sm" data-ck-necessary>' + CC.esc(C.necessary) + '</button><button type="button" class="btn btn--primary btn--sm" data-ck-all>' + CC.esc(C.accept) + '</button></div></div>';
    var skip = $('.skip'); document.body.insertBefore(box, skip ? skip.nextSibling : document.body.firstChild);
    box.addEventListener('click', function (e) {
      if (e.target.closest('[data-ck-all]')) cookieSave('accept_all', true);
      else if (e.target.closest('[data-ck-necessary]')) cookieSave('necessary_only', false);
      else if (e.target.closest('[data-ck-prefs]')) cookieDialog(e.target.closest('[data-ck-prefs]'));
    });
  }

  CC.boot = function () { header(); cookieBanner(); if (!CC.SINGLE) { CC.markNav(CC.route().page); CC.init(document); } };
})();
