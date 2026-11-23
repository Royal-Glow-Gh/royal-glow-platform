// Royal Glow staff apps: "Excel · CSV" download links on every table.
// Added automatically to each card that holds a table (including tables drawn later).
// Amounts become real numbers in Excel; buttons and form controls are left out.
// Excel files are written with SheetJS, loaded only when someone downloads.
(function () {
  var XLSXp = null;
  function loadXLSX() {
    return XLSXp || (XLSXp = new Promise(function (res, rej) {
      if (window.XLSX) return res(window.XLSX);
      var s = document.createElement('script');
      s.src = 'https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js';
      s.onload = function () { res(window.XLSX); };
      s.onerror = function () { XLSXp = null; rej(new Error('Could not load the Excel tool. Check the internet connection and try again.')); };
      document.head.appendChild(s);
    }));
  }
  // Text of a cell: selected option or input value instead of the control; buttons ignored.
  function cellText(td) {
    var c = td.cloneNode(true);
    [].forEach.call(c.querySelectorAll('button,script,style,.noexport'), function (x) { x.remove(); });
    [].forEach.call(td.querySelectorAll('select'), function (sel, i) {
      var t = sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].text : '';
      var cs = c.querySelectorAll('select')[i]; if (cs) cs.replaceWith(document.createTextNode(t));
    });
    [].forEach.call(td.querySelectorAll('input:not([type=checkbox]):not([type=file]),textarea'), function (inp, i) {
      var ci = c.querySelectorAll('input:not([type=checkbox]):not([type=file]),textarea')[i]; if (ci) ci.replaceWith(document.createTextNode(inp.value));
    });
    [].forEach.call(c.querySelectorAll('input'), function (x) { x.remove(); });
    return c.textContent.replace(/\s+/g, ' ').trim();
  }
  // "GH₵ 1,234.50" -> 1234.5; "12" -> 12; but keep codes like "0101" and phone numbers as text.
  function value(t) {
    var s = t.replace(/^GH₵\s*/, '').replace(/^-\s*GH₵\s*/, '-');
    if (/^-?\d{1,3}(,\d{3})+(\.\d+)?$/.test(s) || /^-?\d+\.\d+$/.test(s) || /^-?(0|[1-9]\d{0,8})$/.test(s)) return Number(s.replace(/,/g, ''));
    return t;
  }
  function rowsOf(table) {
    var out = [];
    [].forEach.call(table.rows, function (tr) {
      if (table.offsetParent !== null && tr.offsetParent === null && tr.closest('tbody')) return; // rows hidden by a filter
      var r = [];
      [].forEach.call(tr.cells, function (td) {
        var t = cellText(td);
        r.push(td.tagName === 'TH' ? t : value(t));
        for (var i = 1; i < (td.colSpan || 1); i++) r.push('');
      });
      if (r.some(function (v) { return v !== ''; })) out.push(r);
    });
    return out;
  }
  function fileName(card, table) {
    var app = (document.querySelector('header .applabel') || {}).textContent || 'export';
    var h = card && card.querySelector('h2');
    var tab = document.querySelector('nav button.on');
    var t = (h ? h.firstChild && h.firstChild.textContent || h.textContent : '') || table.getAttribute('aria-label') || (tab && tab.textContent) || 'table';
    var d = new Date().toISOString().slice(0, 10);
    return ('royal-glow-' + app + '-' + t + '-' + d).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-+$/, '');
  }
  function download(blob, name) {
    var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name;
    document.body.appendChild(a); a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }
  function csv(rows) {
    return rows.map(function (r) {
      return r.map(function (v) { v = String(v == null ? '' : v); return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; }).join(',');
    }).join('\r\n');
  }
  function exportTable(table, card, kind, btn) {
    var rows = rowsOf(table), name = fileName(card, table);
    if (rows.length < 2) { btn.textContent = 'Nothing to download'; setTimeout(function () { btn.textContent = kind === 'xlsx' ? 'Excel' : 'CSV'; }, 2000); return; }
    if (kind === 'csv') return download(new Blob(['﻿' + csv(rows)], { type: 'text/csv;charset=utf-8' }), name + '.csv');
    btn.textContent = '…';
    loadXLSX().then(function (X) {
      var ws = X.utils.aoa_to_sheet(rows), rg = X.utils.decode_range(ws['!ref'] || 'A1'), w = [];
      for (var R = rg.s.r; R <= rg.e.r; R++) for (var C = rg.s.c; C <= rg.e.c; C++) {
        var c = ws[X.utils.encode_cell({ r: R, c: C })]; if (!c) continue;
        if (c.t === 'n' && !Number.isInteger(c.v)) c.z = '#,##0.00';
        w[C] = Math.min(Math.max(w[C] || 8, String(c.v).length + 2), 60);
      }
      ws['!cols'] = w.map(function (x) { return { wch: x || 10 }; });
      var wb = X.utils.book_new(); X.utils.book_append_sheet(wb, ws, 'Sheet1');
      X.writeFile(wb, name + '.xlsx'); btn.textContent = 'Excel';
    }).catch(function (e) { btn.textContent = 'Excel'; alert(e.message); });
  }
  function attach(table) {
    if (table.dataset.xdone || table.closest('#gate') || table.classList.contains('noexport')) return;
    table.dataset.xdone = '1';
    var card = table.closest('.card') || table.parentNode;
    // forms for entering things (a new sale, purchase, transfer, booking…) get no download link
    var head = card.querySelector && card.querySelector('h2');
    if (head && /^\s*(Record|Move stock|New booking|Opening hours|Booking rules)/i.test(head.textContent)) return;
    var bar = document.createElement('span');
    bar.className = 'xdl';
    bar.setAttribute('style', 'float:right;font-size:12px;font-weight:400;display:inline-flex;gap:8px;margin-left:10px');
    [['xlsx', 'Excel'], ['csv', 'CSV']].forEach(function (k) {
      var b = document.createElement('a'); b.href = '#'; b.textContent = k[1]; b.title = 'Download this table as ' + k[1];
      b.setAttribute('style', 'color:var(--accent);text-decoration:underline;cursor:pointer');
      b.addEventListener('click', function (e) { e.preventDefault(); exportTable(table, card, k[0], b); });
      bar.appendChild(b);
    });
    // one bar per table: in the card's heading when the card has a single table, else just above the table
    var h2 = card.querySelector && card.querySelector('h2');
    var tables = card.querySelectorAll ? card.querySelectorAll('table') : [];
    if (h2 && tables.length === 1 && !h2.querySelector('.xdl')) h2.appendChild(bar);
    else { var wrap = document.createElement('div'); wrap.setAttribute('style', 'overflow:hidden;margin:4px 0'); wrap.appendChild(bar); table.parentNode.insertBefore(wrap, table); }
  }
  function scan() { [].forEach.call(document.querySelectorAll('main table'), attach); }
  var t = null;
  new MutationObserver(function () { clearTimeout(t); t = setTimeout(scan, 150); }).observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', scan);
  scan();
})();
