/* CarmaCars prototype: page behaviour (fleet filters, car page, request flow). */
(function () {
  'use strict';
  var CC = window.CC; var $ = CC.$; var $$ = CC.$$; var D = CC.date; var P = CC.pricing;
  var FLEET = function () { return window.CC_FLEET.cars; };
  var carBy = function (slug) { return FLEET().filter(function (c) { return c.slug === slug; })[0]; };
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  var TIMES = ['08:00', '08:30', '09:00', '09:30', '10:00', '10:30', '11:00', '11:30', '12:00', '12:30', '13:00', '13:30', '14:00', '14:30', '15:00', '15:30', '16:00', '16:30', '17:00', '17:30', '18:00', '18:30', '19:00', '19:30', '20:00'];
  CC.fillTimes = function (sel, val) { if (sel.options.length) { if (val) sel.value = val; return; } sel.innerHTML = TIMES.map(function (t) { return '<option value="' + t + '"' + (t === (val || '10:00') ? ' selected' : '') + '>' + D.time(t) + '</option>'; }).join(''); };
  CC.inits.push(function (root) { $$('select[data-times]', root).forEach(function (s) { var p = CC.params(); CC.fillTimes(s, p.get(s.name) || s.dataset.times || '10:00'); }); });

  /* ---------- estimate block ---------- */
  CC.renderEstimate = function (el, car, st) {
    if (!st.from || !st.to) {
      el.innerHTML = '<p class="estimate__empty">Pick your pickup and return dates to see the price for this car.</p><table class="spec spec--num"><tbody>' +
        row('Daily', CC.money(car.rates.daily)) + row('Weekend day (Fri, Sat)', CC.money(car.rates.weekend)) + row('Weekly', CC.money(car.rates.weekly)) + row('Monthly (' + CC.t('maxDays') + ' days)', CC.money(car.rates.monthly)) + '</tbody></table>';
      return null;
    }
    var e = P.estimate(car, st);
    if (e.invalid) { el.innerHTML = '<p class="alert alert--error"><span class="alert__title">Return is before pickup</span><span>Set a return time after the pickup time.</span></p>'; return null; }
    var h = '<div class="estimate__dates"><div><span class="xs muted">Pickup</span><b>' + D.short(st.from) + '</b><span class="small">' + D.time(st.tFrom) + '</span></div><div><span class="xs muted">Return</span><b>' + D.short(st.to) + '</b><span class="small">' + D.time(st.tTo) + '</span></div><div class="estimate__days"><b class="num">' + e.days + '</b><span class="xs">' + (e.days === 1 ? 'day' : 'days') + '</span></div></div>';
    if (e.over) h += '<p class="alert alert--warn"><span class="alert__title">' + CC.t('maxDays') + ' days is the most for one booking</span><span>This estimate covers the first ' + CC.t('maxDays') + ' days. To keep the car longer you renew with a new booking before this one ends.</span></p>';
    h += '<table class="estimate__lines"><tbody>';
    e.lines.forEach(function (l) { h += '<tr><th scope="row">' + l.k + (l.note ? '<small>' + l.note + '</small>' : '') + '</th><td class="num">' + (l.v < 0 ? '−' + CC.money(-l.v, true) : CC.money(l.v, true)) + '</td></tr>'; });
    if (e.coverageExtra) h += '<tr><th scope="row">Coverage bought through CarmaCars<small>Priced for your car and dates</small></th><td>In your quote</td></tr>';
    h += '<tr><th scope="row">HST (' + CC.t('hst') + ')</th><td class="num">' + CC.money(e.hst, true) + '</td></tr></tbody>';
    h += '<tfoot><tr><th scope="row">Estimated total<small>Due when you approve, sign and pay. Nothing now.</small></th><td class="num"><b data-total></b></td></tr></tfoot></table>';
    h += '<dl class="estimate__after"><div><dt>Deposit at pickup</dt><dd class="num">' + CC.money(e.deposit) + ' <small>' + e.depositMethod + '</small></dd></div><div><dt>Kilometres included</dt><dd class="num">' + e.km.toLocaleString('en-CA') + ' km <small>then ' + CC.money(car.overage, true) + ' per km</small></dd></div></dl>';
    var old = el.querySelector('[data-total]'); var prev = old ? old.dataset.v : '0';
    el.innerHTML = h; var t = el.querySelector('[data-total]'); t.dataset.v = prev; CC.tween(t, e.total, function (n) { return CC.money(n, true); });
    return e;
  };
  function row(k, v) { return '<tr><th scope="row">' + k + '</th><td>' + v + '</td></tr>'; }
  function stateQuery(st, slug) {
    var q = new URLSearchParams(); if (slug) q.set('car', slug);
    if (st.from && st.to) { q.set('from', st.from); q.set('to', st.to); q.set('tf', st.tFrom); q.set('tt', st.tTo); }
    if (st.deliver) q.set('deliver', '1'); if (st.collect) q.set('collect', '1'); if (st.age && st.age !== '26+') q.set('age', st.age);
    return q.toString();
  }

  /* ---------- reviews: honest empty state, sample populated state ---------- */
  CC.inits.push(function (root) {
    // Nothing to wire beyond the generic data-toggle-state switch. Kept as a
    // marker: review content in the markup is SAMPLE and labelled as such.
  });

  /* ---------- fleet page ---------- */
  CC.inits.push(function (root) {
    var main = $('[data-page="fleet"]', root); if (!main) return;
    var form = $('#filters', main); var grid = $('#fleet-grid', main); var items = $$(':scope > li', grid); var p = CC.params();
    var count = $('[data-fleet-count]', main); var empty = $('[data-fleet-empty]', main); var skel = $('[data-fleet-skeleton]', main); var bookedNote = $('[data-fleet-booked]', main);
    var panel = $('.filters', main); var openBtn = $('[data-filters-open]', main); var chips = $('[data-chips]', main);
    var tf = $('select[name="tf"]', main); var tt = $('select[name="tt"]', main); var sort = $('select[name="sort"]', main); var max = form.elements.max;
    // restore from the address
    (p.get('cls') || '').split(',').filter(Boolean).forEach(function (v) { var c = form.querySelector('[name="cls"][value="' + v + '"]'); if (c) c.checked = true; });
    ['seats', 'trans'].forEach(function (k) { if (p.get(k)) { var r = form.querySelector('[name="' + k + '"][value="' + p.get(k) + '"]'); if (r) r.checked = true; } });
    if (p.get('max')) { max.value = p.get('max'); max.dispatchEvent(new Event('input')); }
    if (p.get('young')) form.elements.young.checked = true;
    if (p.get('sort')) sort.value = p.get('sort');
    var dr = CC.DateRange($('[data-daterange]', main), { onChange: function () { apply(true); } });
    var timer;
    function read() {
      var v = dr.value();
      return { from: v.from && v.to ? v.from : '', to: v.from && v.to ? v.to : '', tf: tf.value, tt: tt.value,
        cls: $$('[name="cls"]:checked', form).map(function (c) { return c.value; }), seats: form.elements.seats.value, trans: form.elements.trans.value,
        max: +max.value, young: form.elements.young.checked, showBooked: form.elements.showBooked.checked, sort: sort.value, mode: p.get('mode') || '' };
    }
    function apply(lookup) {
      var s = read(); var shown = []; var booked = 0;
      $('[data-max-out]', main).textContent = s.max >= +max.max ? 'Any price' : 'Up to ' + CC.money(s.max) + ' a day';
      items.forEach(function (li) {
        var c = carBy(li.dataset.slug); var ok = true;
        if (s.cls.length && s.cls.indexOf(c.cls) === -1) ok = false;
        if (s.seats === '2' && c.seats !== 2) ok = false; if (s.seats === '5' && c.seats < 5) ok = false; if (s.seats === '7' && c.seats < 7) ok = false;
        if (s.trans !== 'any' && c.transmission !== s.trans) ok = false;
        if (c.rates.daily > s.max) ok = false; if (s.young && !c.young) ok = false;
        var busy = ok && s.from && D.overlaps(s.from, s.to, c.booked);
        if (busy) booked++;
        var flag = $('[data-flag]', li); var price = $('[data-price]', li); var unit = $('[data-unit]', li); var a = $('a', li);
        li.classList.toggle('is-booked', !!busy);
        if (flag) { flag.hidden = !busy; }
        if (s.from && !busy) { var e = P.estimate(c, { from: s.from, to: s.to, tFrom: s.tf, tTo: s.tt, age: '26+' }); price.textContent = CC.money(e.lines[0].v); unit.textContent = e.days + (e.days === 1 ? ' day' : ' days') + ', before HST'; li.dataset.sortPrice = e.lines[0].v; }
        else { price.textContent = CC.money(c.rates.daily); unit.textContent = 'a day'; li.dataset.sortPrice = c.rates.daily; }
        a.setAttribute('href', CC.url('car-' + c.slug + '.html' + (s.from ? '?' + stateQuery({ from: s.from, to: s.to, tFrom: s.tf, tTo: s.tt, deliver: s.mode === 'delivery', collect: s.mode === 'delivery' }) : '')));
        li.hidden = !ok || (busy && !s.showBooked);
        if (!li.hidden) shown.push(li);
      });
      var by = { 'price-asc': function (a, b) { return a.dataset.sortPrice - b.dataset.sortPrice; }, 'price-desc': function (a, b) { return b.dataset.sortPrice - a.dataset.sortPrice; }, name: function (a, b) { return a.dataset.name.localeCompare(b.dataset.name); }, seats: function (a, b) { return b.dataset.seats - a.dataset.seats || a.dataset.sortPrice - b.dataset.sortPrice; }, featured: function (a, b) { return a.dataset.i - b.dataset.i; } }[s.sort];
      items.slice().sort(function (a, b) { return (a.classList.contains('is-booked') - b.classList.contains('is-booked')) || by(a, b); }).forEach(function (li) { grid.appendChild(li); });
      var free = shown.filter(function (li) { return !li.classList.contains('is-booked'); }).length;
      var filtered = shown.length < items.length; count.textContent = s.from ? free + (free === 1 ? ' car' : ' cars') + ' free ' + D.short(s.from) + ' to ' + D.short(s.to) : filtered ? 'Showing ' + shown.length + (shown.length === 1 ? ' car' : ' cars') : 'Showing every car';
      bookedNote.hidden = !(s.from && booked); if (booked) $('span', bookedNote).textContent = booked + (booked === 1 ? ' car that matches is' : ' cars that match are') + ' booked for those dates.';
      empty.hidden = shown.length > 0; grid.hidden = shown.length === 0;
      $$('[data-filters-count]', main).forEach(function (b) { b.textContent = 'Show ' + shown.length + (shown.length === 1 ? ' car' : ' cars'); });
      // active filter chips
      var ch = [];
      s.cls.forEach(function (v) { ch.push(['cls', v, v]); }); if (s.seats !== 'any') ch.push(['seats', 'any', s.seats === '2' ? '2 seats' : s.seats + '+ seats']);
      if (s.trans !== 'any') ch.push(['trans', 'any', s.trans]); if (s.max < +max.max) ch.push(['max', max.max, 'Up to ' + CC.money(s.max)]); if (s.young) ch.push(['young', '', 'Ages ' + CC.t('youngA')]);
      chips.innerHTML = ch.map(function (c) { return '<button type="button" class="chip" data-chip="' + c[0] + '" data-val="' + c[1] + '"><span class="vh">Remove filter </span>' + c[2] + '<i aria-hidden="true">×</i></button>'; }).join('') + (ch.length > 1 ? '<button type="button" class="chip chip--clear" data-clear>Clear all</button>' : '');
      if (openBtn) $('b', openBtn).textContent = ch.length ? ' (' + ch.length + ')' : '';
      CC.setParams({ from: s.from, to: s.to, tf: s.from ? s.tf : '', tt: s.from ? s.tt : '', mode: s.mode, cls: s.cls.join(','), seats: s.seats === 'any' ? '' : s.seats, trans: s.trans === 'any' ? '' : s.trans, max: s.max < +max.max ? s.max : '', young: s.young ? 1 : '', sort: s.sort === 'featured' ? '' : s.sort });
      // PROTOTYPE: stands in for the availability request the real site makes.
      if (lookup && s.from && !reduce.matches) { clearTimeout(timer); main.classList.add('is-loading'); skel.hidden = false; grid.setAttribute('aria-busy', 'true'); timer = setTimeout(function () { main.classList.remove('is-loading'); skel.hidden = true; grid.removeAttribute('aria-busy'); }, 520); }
    }
    function clearAll() { $$('[name="cls"]', form).forEach(function (c) { c.checked = false; }); form.querySelector('[name="seats"][value="any"]').checked = true; form.querySelector('[name="trans"][value="any"]').checked = true; max.value = max.max; max.dispatchEvent(new Event('input')); form.elements.young.checked = false; apply(); }
    form.addEventListener('change', function () { apply(); }); form.addEventListener('input', function (e) { if (e.target === max) apply(); });
    form.addEventListener('submit', function (e) { e.preventDefault(); });
    sort.addEventListener('change', function () { apply(); }); tf.addEventListener('change', function () { apply(); }); tt.addEventListener('change', function () { apply(); });
    main.addEventListener('click', function (e) {
      var chip = e.target.closest('[data-chip]');
      if (chip) { var k = chip.dataset.chip; if (k === 'cls') form.querySelector('[name="cls"][value="' + chip.dataset.val + '"]').checked = false; else if (k === 'young') form.elements.young.checked = false; else if (k === 'max') { max.value = max.max; max.dispatchEvent(new Event('input')); } else form.querySelector('[name="' + k + '"][value="any"]').checked = true; apply(); return; }
      if (e.target.closest('[data-clear]')) { clearAll(); return; }
      if (e.target.closest('[data-clear-dates]')) { dr.set('', ''); apply(); return; }
      if (e.target.closest('[data-show-booked]')) { form.elements.showBooked.checked = true; apply(); }
    });
    // filter sheet on phones
    var setPanel = function (open) { panel.classList.toggle('is-open', open); document.body.style.overflow = open ? 'hidden' : ''; openBtn.setAttribute('aria-expanded', open); if (open) $('[data-filters-close]', panel).focus(); else openBtn.focus(); };
    CC.on(openBtn, 'click', function () { setPanel(true); });
    $$('[data-filters-close], [data-filters-count]', panel).forEach(function (b) { b.addEventListener('click', function () { setPanel(false); }); });
    panel.addEventListener('keydown', function (e) { if (e.key === 'Escape' && panel.classList.contains('is-open')) setPanel(false); });
    CC.onCleanup(function () { document.body.style.overflow = ''; clearTimeout(timer); });
    apply(!!(p.get('from') && p.get('to')));
  });

  /* ---------- car page ---------- */
  CC.inits.push(function (root) {
    var main = $('[data-page="car"]', root); if (!main) return;
    var car = carBy(main.dataset.slug); var p = CC.params();
    // gallery: native scroll-snap track, so touch, trackpad and keyboard all work
    var track = $('.gallery__track', main); var slides = $$('li', track); var thumbs = $$('[data-thumb]', main); var counter = $('[data-gallery-count]', main); var cur = 0;
    var go = function (i) { i = Math.max(0, Math.min(slides.length - 1, i)); track.scrollTo({ left: slides[i].offsetLeft, behavior: reduce.matches ? 'auto' : 'smooth' }); };
    var mark = function () { var i = Math.round(track.scrollLeft / track.clientWidth); if (i === cur) return; cur = i; paint(); };
    var paint = function () { thumbs.forEach(function (t, j) { t.setAttribute('aria-current', j === cur ? 'true' : 'false'); }); counter.textContent = (cur + 1) + ' / ' + slides.length; $('[data-gallery-label]', main).textContent = slides[cur].dataset.label; $('[data-gallery-prev]', main).disabled = cur === 0; $('[data-gallery-next]', main).disabled = cur === slides.length - 1; };
    var tk = false; track.addEventListener('scroll', function () { if (!tk) { tk = true; requestAnimationFrame(function () { tk = false; mark(); }); } }, { passive: true });
    thumbs.forEach(function (t, i) { t.addEventListener('click', function () { go(i); }); });
    $('[data-gallery-prev]', main).addEventListener('click', function () { go(cur - 1); }); $('[data-gallery-next]', main).addEventListener('click', function () { go(cur + 1); });
    track.addEventListener('keydown', function (e) { if (e.key === 'ArrowRight') { e.preventDefault(); go(cur + 1); } if (e.key === 'ArrowLeft') { e.preventDefault(); go(cur - 1); } });
    paint();

    // dates + estimate
    var tf = $('select[name="tf"]', main); var tt = $('select[name="tt"]', main); var est = $('[data-estimate]', main); var bar = $('.bookbar', root) || $('.bookbar');
    var st = { from: D.valid(p.get('from')) ? p.get('from') : '', to: D.valid(p.get('to')) ? p.get('to') : '', tFrom: tf.value, tTo: tt.value, deliver: p.get('deliver') === '1', collect: p.get('collect') === '1', age: p.get('age') || '26+' };
    if (st.from && (st.from < CC.TODAY || D.overlaps(st.from, st.to || st.from, car.booked))) { var clash = true; }
    var note = $('[data-date-clash]', main);
    if (clash) { note.hidden = false; note.querySelector('span').textContent = 'This car is booked for part of ' + D.short(st.from) + ' to ' + D.short(st.to || st.from) + '. Pick other dates below, or look at similar cars.'; st.from = ''; st.to = ''; }
    $('[name="deliver"]', main).checked = st.deliver; $('[name="collect"]', main).checked = st.collect; $('[name="age"]', main).value = st.age;
    var cal = CC.Calendar($('[data-cal]', main), { months: 1, booked: car.booked, from: st.from, to: st.to, onChange: function (v) { st.from = v.from; st.to = v.to; if (v.to) note.hidden = true; update(); } });
    function update() {
      st.tFrom = tf.value; st.tTo = tt.value; st.deliver = $('[name="deliver"]', main).checked; st.collect = $('[name="collect"]', main).checked; st.age = $('[name="age"]', main).value;
      var ageNote = $('[data-age-note]', main); ageNote.hidden = !(st.age === '18-20' && !car.young);
      var e = CC.renderEstimate(est, car, st); var ready = !!e;
      var href = CC.url('request.html?' + stateQuery(st, car.slug));
      $$('[data-book]', root).forEach(function (a) { a.setAttribute('href', href); });
      $$('[data-book-label]', root).forEach(function (s) { s.textContent = 'Request to book'; });
      if (bar) { $('[data-bar-price]', bar).textContent = ready ? CC.money(e.total, true) : 'From ' + CC.money(car.rates.daily); $('[data-bar-sub]', bar).textContent = ready ? e.days + (e.days === 1 ? ' day' : ' days') + ', ' + D.short(st.from).split(', ')[1] + ' to ' + D.short(st.to).split(', ')[1] + ', with HST' : 'a day. Pick dates for a total'; }
      CC.setParams({ from: st.to ? st.from : '', to: st.to, tf: st.to ? st.tFrom : '', tt: st.to ? st.tTo : '', deliver: st.deliver ? 1 : '', collect: st.collect ? 1 : '', age: st.age === '26+' ? '' : st.age });
    }
    $$('select, input[type="checkbox"]', $('[data-booking]', main)).forEach(function (i) { i.addEventListener('change', update); });
    update();
    // sticky bar: appears once the first call to action has scrolled away
    if (bar && 'IntersectionObserver' in window) {
      var top = $('.car-top', main); var cta = $('.booking__est [data-book]', main); var past = false; var ctaIn = false;
      var sync = function () { var on = past && !ctaIn; bar.classList.toggle('is-on', on); bar.inert = !on; document.documentElement.style.setProperty('--bar-h', on ? bar.offsetHeight + 'px' : '0px'); };
      var io = new IntersectionObserver(function (es) { es.forEach(function (e) { if (e.target === top) past = !e.isIntersecting && e.boundingClientRect.top < 0; else ctaIn = e.isIntersecting; }); sync(); }, { threshold: 0 });
      io.observe(top); io.observe(cta); bar.inert = true; CC.onCleanup(function () { io.disconnect(); document.documentElement.style.setProperty('--bar-h', '0px'); });
    }
  });

  /* ---------- request to book ---------- */
  var KEY = 'cc.request.v1';
  CC.inits.push(function (root) {
    var main = $('[data-page="request"]', root); if (!main) return;
    var form = $('#request', main); var el = form.elements; var p = CC.params(); var saved = CC.store.get(KEY) || {};
    var steps = $$('[data-step]', form); var ind = $$('.steps li', main); var sum = $('[data-summary]', main); var cur = 1; var maxSeen = 1;
    var fresh = (p.get('car') && p.get('car') !== (saved.f || {}).car) || (p.get('from') && p.get('from') !== saved.from); // a different car or dates in the link wins over the saved draft
    // restore saved fields
    Object.keys(saved.f || {}).forEach(function (k) { var i = el[k]; if (!i) return; if (i.type === 'checkbox') i.checked = !!saved.f[k]; else if (i.length && i[0] && i[0].type === 'radio') { $$('[name="' + k + '"]', form).forEach(function (r) { r.checked = r.value === saved.f[k]; }); } else i.value = saved.f[k]; });
    if (p.get('car') && carBy(p.get('car'))) el.car.value = p.get('car');
    CC.fillTimes(el.tf, p.get('tf') || (saved.f && saved.f.tf)); CC.fillTimes(el.tt, p.get('tt') || (saved.f && saved.f.tt));
    if (p.get('deliver')) el.deliver.checked = true; if (p.get('collect')) el.collect.checked = true;
    var from = D.valid(p.get('from')) ? p.get('from') : (!fresh && saved.from) || ''; var to = D.valid(p.get('to')) ? p.get('to') : (!fresh && saved.to) || '';
    if (from && from < CC.TODAY) { from = ''; to = ''; }
    $$('.qty', form).forEach(function (q) { if (q._set) q._set(+$('input', q).value || 0); });
    var car = function () { return carBy(el.car.value); };
    if (from && car() && D.overlaps(from, to || from, car().booked)) { from = ''; to = ''; }
    var cal = CC.Calendar($('[data-cal]', form), { months: window.matchMedia('(min-width: 44rem)').matches ? 2 : 1, booked: car() ? car().booked : [], from: from, to: to, onChange: function (v) { from = v.from; to = v.to; $('[data-dates-field]', form).classList.remove('has-error'); refresh(); } });
    function ageAtPickup() { var y = +el.dobY.value; var m = +el.dobM.value; var d = +el.dobD.value; if (!y || !m || !d || y < 1900) return null; var ref = D.parse(from || CC.TODAY); var a = ref.getUTCFullYear() - y; if (ref.getUTCMonth() + 1 < m || (ref.getUTCMonth() + 1 === m && ref.getUTCDate() < d)) a--; return a; }
    function band() { var a = ageAtPickup(); if (a == null) return p.get('age') || '26+'; var RU = window.CC_FLEET.rules; return a < RU.standardMinAge ? '18-20' : a < RU.noFeeAge ? '21-25' : '26+'; }
    function state() { return { from: from, to: to, tFrom: el.tf.value, tTo: el.tt.value, deliver: el.deliver.checked, collect: el.collect.checked, age: band(), addDrivers: +el.addDrivers.value || 0, winter: el.winter.checked, babySeats: +el.babySeats.value || 0, nonRefundable: el.bookingType.value === 'nonrefundable', coverage: el.coverage.value }; }
    function refresh() {
      var c = car(); $('[data-addr-deliver]', form).hidden = !el.deliver.checked; $('[data-addr-collect]', form).hidden = !el.collect.checked;
      $$('[data-car-fee]', form).forEach(function (s) { s.textContent = c ? CC.money(c.delivery) : '$75 to $200'; });
      var head = $('[data-summary-car]', main);
      if (c) { head.innerHTML = '<img src="' + CC.photo(c.photo) + '" alt="" width="1800" height="1200" loading="lazy"><div><span class="plate">' + c.code + '</span><b>' + c.year + ' ' + c.name + '</b><span class="small muted">' + c.trim + '</span></div>'; }
      else head.innerHTML = '<p class="muted">Choose a car to see the estimate.</p>';
      var e = c ? CC.renderEstimate(sum, c, state()) : null; if (!c) sum.innerHTML = '';
      $('[data-summary-total]', main).textContent = e ? CC.money(e.total, true) : c ? 'From ' + CC.money(c.rates.daily) + ' a day' : '';
      if (cur === 4) review();
      save();
    }
    function save() {
      var f = {}; $$('input, select, textarea', form).forEach(function (i) { if (!i.name || i.type === 'hidden' && !i.closest('.qty')) return; if (i.type === 'checkbox') f[i.name] = i.checked; else if (i.type === 'radio') { if (i.checked) f[i.name] = i.value; } else f[i.name] = i.value; });
      CC.store.set(KEY, { f: f, from: from, to: to, step: cur, at: Date.now() }); var s = $('[data-saved]', main); if (s) s.hidden = false;
    }
    function fieldError(sel, msg) { var f = $(sel, form); f.classList.toggle('has-error', !!msg); var e = $('.error', f); if (e) e.textContent = msg || ''; return f; }
    function validate(n) {
      var scope = steps[n - 1]; var ok = CC.checkAll(scope); var first = null; var bad = function (f) { ok = false; if (!first) first = f; };
      if (n === 1) {
        if (!from || !to) bad(fieldError('[data-dates-field]', !from ? 'Pick a pickup date and a return date.' : 'Pick a return date.'));
        else { var d = P.days(from, el.tf.value, to, el.tt.value); if (d.invalid) bad(fieldError('[data-dates-field]', 'The return time is before the pickup time.')); else if (d.over) bad(fieldError('[data-dates-field]', 'One booking covers up to ' + CC.t('maxDays') + ' days. Shorten the dates; you can renew later.')); else fieldError('[data-dates-field]', ''); }
      }
      if (n === 2) {
        var a = ageAtPickup(); var c = car(); var msg = '';
        if (a == null || +el.dobD.value > 31) msg = 'Enter your full date of birth.';
        else if (a < window.CC_FLEET.rules.minAge) msg = 'Drivers must be ' + CC.t('minAge') + ' or older at pickup.';
        else if (a > 110) msg = 'Check the year.';
        else if (a < window.CC_FLEET.rules.standardMinAge && c && !c.young) msg = 'Drivers aged ' + CC.t('youngA') + ' can book the cars we mark for them. The ' + c.name + ' is not one of them. Go back a step to choose another car.';
        var f = fieldError('[data-dob-field]', msg); if (msg) bad(f);
      }
      if (n === 3) {
        if (!el.licClass.value) bad(fieldError('[data-lic-field]', 'Choose your licence class.')); else fieldError('[data-lic-field]', '');
        var ey = +el.licY.value; var em = +el.licM.value; var m2 = '';
        if (!ey || !em) m2 = 'Enter the month and year your licence expires.'; else if (to && (ey + '-' + String(em).padStart(2, '0')) < to.slice(0, 7)) m2 = 'Your licence must be valid until after the return date.';
        var f2 = fieldError('[data-licexp-field]', m2); if (m2) bad(f2);
        if (!el.coverage.value) bad(fieldError('[data-cov-field]', 'Choose how the car will be covered. You can change it before pickup.')); else fieldError('[data-cov-field]', '');
      }
      if (first && ok === false) { var t = first.querySelector('input, select, button, [tabindex]'); if (!scope.querySelector('.has-error [aria-invalid="true"]') && t) t.focus(); first.scrollIntoView({ block: 'center', behavior: reduce.matches ? 'auto' : 'smooth' }); }
      return ok;
    }
    function show(n, focus) {
      cur = n; maxSeen = Math.max(maxSeen, n);
      steps.forEach(function (s, i) { s.hidden = i !== n - 1; });
      ind.forEach(function (li, i) { li.classList.toggle('is-current', i === n - 1); li.classList.toggle('is-done', i < n - 1); if (i === n - 1) li.setAttribute('aria-current', 'step'); else li.removeAttribute('aria-current'); var b = $('b', li); var label = li.dataset.label; b.innerHTML = i < n - 1 ? '<button type="button" data-goto="' + (i + 1) + '">' + label + '<span class="vh">, done. Edit</span></button>' : label; });
      $('[data-step-count]', main).textContent = 'Step ' + n + ' of 4';
      if (n === 4) review();
      if (focus) { var h = $('h2', steps[n - 1]); h.setAttribute('tabindex', '-1'); h.focus({ preventScroll: true }); var top = main.getBoundingClientRect().top + window.scrollY - 8; window.scrollTo({ top: top, behavior: reduce.matches ? 'auto' : 'smooth' }); }
      save();
    }
    function review() {
      var c = car(); var s = state(); var cov = { 1: 'Option 1: OPCF 27 on my own auto policy', 2: 'Option 2: my credit card rental coverage', 3: 'Option 3: buy coverage through CarmaCars' }[el.coverage.value] || '';
      var rows = [
        ['Car', c ? c.year + ' ' + c.name : '', 1],
        ['Pickup', from ? D.long(from) + ', ' + D.time(el.tf.value) + (el.deliver.checked ? '. Delivered to ' + (el.addrDeliver.value || 'your address') : '. You collect it from us') : '', 1],
        ['Return', to ? D.long(to) + ', ' + D.time(el.tt.value) + (el.collect.checked ? '. We pick it up from ' + (el.addrCollect.value || el.addrDeliver.value || 'your address') : '. You bring it back to us') : '', 1],
        ['Driver', el.first.value + ' ' + el.last.value + (ageAtPickup() != null ? ', ' + ageAtPickup() + ' at pickup' : ''), 2], ['Contact', el.email.value + ', ' + el.phone.value, 2],
        ['Additional drivers', (+el.addDrivers.value || 0) ? el.addDrivers.value : 'None', 2],
        ['Licence', (el.licClass.value === 'other' ? 'Other, for review' : 'Ontario class ' + el.licClass.value) + ', expires ' + el.licM.value + '/' + el.licY.value, 3], ['Coverage', cov, 3],
        ['Booking type', s.nonRefundable ? 'Non-refundable, ' + CC.t('nonRef') + ' off the rental charge' : 'Standard, refund by cancellation tier', 3],
        ['Extras', [el.winter.checked ? 'Winter tires' : '', (+el.babySeats.value || 0) ? el.babySeats.value + ' baby seat' + (+el.babySeats.value > 1 ? 's' : '') : ''].filter(Boolean).join(', ') || 'None', 3]
      ];
      $('[data-review]', form).innerHTML = rows.map(function (r) { return '<tr><th scope="row">' + r[0] + '</th><td>' + CC.esc(r[1]) + '</td><td><button type="button" class="link small" data-goto="' + r[2] + '">Edit<span class="vh"> ' + r[0] + '</span></button></td></tr>'; }).join('');
    }
    main.addEventListener('click', function (e) {
      var g = e.target.closest('[data-goto]'); if (g) { show(+g.dataset.goto, true); return; }
      if (e.target.closest('[data-next]')) { if (validate(cur)) show(cur + 1, true); return; }
      if (e.target.closest('[data-back]')) { show(cur - 1, true); return; }
      if (e.target.closest('[data-reset]')) { CC.store.del(KEY); CC.go('request.html' + (el.car.value ? '?car=' + el.car.value : '')); if (CC.SINGLE) location.reload(); }
    });
    form.addEventListener('change', function (e) { if (e.target === el.car) { var c = car(); cal.setBooked(c ? c.booked : []); if (from && c && D.overlaps(from, to || from, c.booked)) { from = ''; to = ''; cal.set('', ''); fieldError('[data-dates-field]', 'The ' + c.name + ' is booked for part of those dates. Pick new dates.'); } } refresh(); });
    form.addEventListener('input', function (e) { if (e.target.matches('input[type="text"], input[type="email"], input[type="tel"], textarea')) save(); if (e.target.name && /^dob/.test(e.target.name)) refresh(); });
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      for (var n = 1; n <= 4; n++) { if (!validate(n)) { show(n, false); validate(n); return; } }
      var c = car(); var est = P.estimate(c, state());
      // PROTOTYPE: the real site posts this to the booking service.
      var ref = 'R-' + String(Date.now()).slice(-6);
      try { sessionStorage.setItem('cc.lastRequest', JSON.stringify({ ref: ref, car: c.year + ' ' + c.name, slug: c.slug, from: from, to: to, tf: el.tf.value, tt: el.tt.value, deliver: el.deliver.checked, total: est.total, deposit: est.deposit, days: est.days, email: el.email.value, first: el.first.value, coverage: el.coverage.value })); } catch (x) { /* ignore */ }
      CC.store.del(KEY); CC.go('confirmation.html?ref=' + ref);
    });
    var sumBox = $('.req__sum', main); var wide = window.matchMedia('(min-width: 64rem)'); var fit = function () { if (wide.matches) sumBox.open = true; }; fit(); wide.addEventListener('change', fit);
    if (saved.at && !fresh) { var s0 = $('[data-restored]', main); if (s0) s0.hidden = false; }
    refresh(); show(!fresh && saved.step ? Math.min(saved.step, 4) : 1, false);
  });

  /* ---------- confirmation ---------- */
  CC.inits.push(function (root) {
    var main = $('[data-page="confirmation"]', root); if (!main) return; var r = null;
    try { r = JSON.parse(sessionStorage.getItem('cc.lastRequest')); } catch (e) { /* ignore */ }
    var box = $('[data-conf]', main); if (!r) { $('[data-conf-none]', main).hidden = false; box.hidden = true; $('.conf-head .row', main).hidden = true; $('h1', main).textContent = 'No request to show.'; $('.conf-head .lead', main).textContent = 'This page confirms a request right after you send it. Here is what happens once you do.'; return; }
    $('[data-conf-ref]', main).textContent = r.ref; $('[data-conf-name]', main).textContent = r.first ? ', ' + r.first : '';
    $('[data-conf-email]', main).textContent = r.email;
    $('[data-conf-rows]', main).innerHTML = [['Car', r.car], ['Pickup', D.long(r.from) + ', ' + D.time(r.tf) + (r.deliver ? ', delivered' : '')], ['Return', D.long(r.to) + ', ' + D.time(r.tt)], ['Length', r.days + (r.days === 1 ? ' day' : ' days')], ['Estimated total', CC.money(r.total, true) + ' with HST. Not charged.'], ['Deposit at pickup', CC.money(r.deposit)]].map(function (x) { return '<tr><th scope="row">' + x[0] + '</th><td>' + CC.esc(x[1]) + '</td></tr>'; }).join('');
    $$('[data-conf-cov]', main).forEach(function (e) { e.hidden = e.dataset.confCov !== String(r.coverage); });
  });

  CC.inits.push(function (root) { $$('[data-sg-cal]', root).forEach(function (el) { CC.Calendar(el, { months: 2, booked: FLEET()[2].booked, from: '2026-10-23', to: '2026-10-26' }); }); });

  /* ---------- portal sample (styleguide): row opens the side panel ---------- */
  CC.inits.push(function (root) {
    var t = $('[data-bookings]', root); if (!t) return; var panel = $('[data-booking-panel]', root);
    var open = function (tr) { $$('tbody tr', t).forEach(function (r) { r.classList.toggle('is-selected', r === tr); r.setAttribute('aria-selected', r === tr); }); var d = JSON.parse(tr.dataset.b); Object.keys(d).forEach(function (k) { var e = $('[data-f="' + k + '"]', panel); if (e) e.textContent = d[k]; }); var b = $('[data-f-status]', panel); b.className = 'badge ' + d.badge; b.textContent = d.status; panel.classList.add('is-open'); };
    t.addEventListener('click', function (e) { var tr = e.target.closest('tbody tr'); if (tr) open(tr); });
    t.addEventListener('keydown', function (e) { var tr = e.target.closest('tbody tr'); if (!tr) return; if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(tr); } if (e.key === 'ArrowDown' && tr.nextElementSibling) { e.preventDefault(); tr.nextElementSibling.focus(); } if (e.key === 'ArrowUp' && tr.previousElementSibling) { e.preventDefault(); tr.previousElementSibling.focus(); } });
    CC.on($('[data-panel-close]', panel), 'click', function () { panel.classList.remove('is-open'); });
    var filter = $('[data-bookings-filter]', root);
    CC.on(filter, 'click', function (e) { var b = e.target.closest('[role="tab"]'); if (!b) return; var s = b.dataset.status; $$('tbody tr', t).forEach(function (r) { r.hidden = s !== 'all' && JSON.parse(r.dataset.b).status !== s; }); });
  });
})();
