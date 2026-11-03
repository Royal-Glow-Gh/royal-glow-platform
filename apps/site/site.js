// Royal Glow website: slide/quote rotation and the live announcement bar. No libraries.
(function () {
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Rotating slides and quotes: <section class="slider" data-rotate="ms"> with .slide children.
  // Pauses while the visitor hovers, focuses or touches; swipe left/right on phones;
  // never moves on its own for visitors who ask for reduced motion.
  [].forEach.call(document.querySelectorAll('.slider[data-rotate]'), function (s) {
    var items = [].filter.call(s.children, function (c) { return c.classList.contains('slide'); });
    var dots = [].slice.call(s.querySelectorAll('.dots button'));
    if (items.length < 2) return;
    var i = 0, timer = null, paused = false, ms = +s.getAttribute('data-rotate') || 7000;
    function go(n) {
      items[i].classList.remove('on'); items[i].setAttribute('aria-hidden', 'true'); if (dots[i]) dots[i].classList.remove('on');
      i = (n + items.length) % items.length;
      items[i].classList.add('on'); items[i].removeAttribute('aria-hidden'); if (dots[i]) dots[i].classList.add('on');
    }
    function stop() { if (timer) clearInterval(timer); timer = null; }
    function start() { stop(); if (!reduce && !paused && !document.hidden) timer = setInterval(function () { go(i + 1); }, ms); }
    dots.forEach(function (d, n) { d.addEventListener('click', function () { go(n); start(); }); });
    s.addEventListener('mouseenter', function () { paused = true; stop(); });
    s.addEventListener('mouseleave', function () { paused = false; start(); });
    s.addEventListener('focusin', function () { paused = true; stop(); });
    s.addEventListener('focusout', function () { paused = false; start(); });
    var x0 = null;
    s.addEventListener('touchstart', function (e) { x0 = e.touches[0].clientX; paused = true; stop(); }, { passive: true });
    s.addEventListener('touchend', function (e) {
      if (x0 != null) { var dx = e.changedTouches[0].clientX - x0; if (Math.abs(dx) > 40) go(i + (dx < 0 ? 1 : -1)); }
      x0 = null; paused = false; start();
    });
    document.addEventListener('visibilitychange', start);
    start();
  });

  // Announcement bar: loaded live from the database, so staff changes show at once.
  var bar = document.getElementById('annbar'), RG = window.RG;
  if (!bar || !RG || !RG.url || !window.fetch) return;
  var LINKS = { shop: RG.shop + '/', spa: RG.shop + '/#spa', blog: '/blog/', about: '/about/', contact: '/contact/' };
  fetch(RG.url + '/rest/v1/site_announcements?select=message,link&order=sort,created_at.desc&limit=3', { headers: { apikey: RG.key } })
    .then(function (r) { return r.ok ? r.json() : []; })
    .then(function (list) {
      if (!list || !list.length) return;
      var els = list.map(function (a, n) {
        var href = a.link ? (LINKS[a.link] || a.link) : '';
        var el = document.createElement(href ? 'a' : 'span');
        if (href) { el.href = href; if (/^https?:/.test(href) && href.indexOf(location.host) < 0) el.rel = 'noopener'; }
        el.textContent = a.message + (href ? ' →' : '');
        el.className = 'msg' + (n ? '' : ' on');
        bar.appendChild(el);
        return el;
      });
      bar.hidden = false;
      document.body.classList.add('has-ann');
      document.body.style.setProperty('--ann', bar.offsetHeight + 'px');
      if (els.length > 1 && !reduce) {
        var k = 0;
        setInterval(function () { els[k].classList.remove('on'); k = (k + 1) % els.length; els[k].classList.add('on'); }, 5000);
      } else if (els.length > 1) {
        els.forEach(function (e) { e.classList.add('on'); });
        bar.classList.add('all');
      }
    })
    .catch(function () {});
})();
