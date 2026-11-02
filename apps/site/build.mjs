// Builds the main website (royalglowgh.com) as plain HTML files in apps/site/dist.
// Run: node apps/site/build.mjs        (no packages to install; needs Node 20+)
// Content comes from site.json (company text) and Supabase (articles, products, spa treatments).
// If Supabase can't be reached the build stops, so a broken site is never published.

import { readFileSync, writeFileSync, mkdirSync, rmSync, cpSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { md } from './lib/md.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, 'dist');
const SITE = JSON.parse(readFileSync(join(HERE, 'site.json'), 'utf8'));
const BASE = SITE.site_url.replace(/\/$/, '');
const SHOP = SITE.shop_url.replace(/\/$/, '');

// ---------- Supabase connection: env vars, or the staff app's config.js ----------
function readConfig() {
  let url = process.env.SUPABASE_URL, key = process.env.SUPABASE_KEY;
  const cfgPath = join(HERE, '..', 'production', 'config.js');
  if ((!url || !key) && existsSync(cfgPath)) {
    const txt = readFileSync(cfgPath, 'utf8');
    url = url || (txt.match(/SUPABASE_URL:\s*'([^']+)'/) || [])[1];
    key = key || (txt.match(/SUPABASE_KEY:\s*'([^']+)'/) || [])[1];
  }
  if (!url || !key || /PASTE_/.test(url + key)) throw new Error('Supabase URL/key not found (set SUPABASE_URL and SUPABASE_KEY, or fill in apps/production/config.js).');
  return { url: url.replace(/\/$/, ''), key };
}
const CFG = readConfig();
// Publishable keys go on the apikey header only (not Authorization: Bearer).
async function api(path, body) {
  const res = await fetch(CFG.url + '/rest/v1/' + path, {
    method: body ? 'POST' : 'GET',
    headers: { apikey: CFG.key, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: body ? JSON.stringify(body) : undefined
  });
  if (!res.ok) throw new Error(`Supabase ${path} -> ${res.status} ${await res.text()}`);
  return res.json();
}
async function optional(promise, fallback) { try { return await promise; } catch (e) { console.warn('warning:', e.message); return fallback; } }

// ---------- helpers ----------
const esc = s => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const money = v => 'GH₵ ' + Number(v || 0).toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const dateLong = t => new Date(t).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'Africa/Accra' });
const clean = s => String(s || '').replace(/\s*\(sample\)/g, '');
const img = (bucket, p) => p ? `${CFG.url}/storage/v1/object/public/${bucket}/${String(p).split('/').map(encodeURIComponent).join('/')}` : '';
const write = (rel, html) => { const f = join(OUT, rel); mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, html); };
const plain = s => String(s || '').replace(/!\[[^\]]*\]\([^)]*\)/g, '').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/[#*>`_-]+/g, ' ').replace(/\s+/g, ' ').trim();
const C = SITE.contact || {};
const waLink = n => 'https://wa.me/' + String(n).replace(/[^0-9]/g, '').replace(/^0/, '233');

// ---------- layout ----------
function page({ path, title, description, image, type = 'website', body, jsonld, nav }) {
  const url = BASE + path;
  const t = title ? `${title} — ${SITE.brand}` : `${SITE.brand} — ${SITE.tagline}`;
  const d = description || SITE.intro;
  const ogImg = image || BASE + '/assets/og-default.jpg';
  const link = (href, label, key) => `<a href="${href}"${nav === key ? ' aria-current="page"' : ''}>${label}</a>`;
  const year = new Date().getUTCFullYear();
  const social = Object.entries(SITE.social || {}).filter(([, v]) => v).map(([k, v]) => `<a href="${esc(v)}" rel="noopener">${k[0].toUpperCase() + k.slice(1)}</a>`).join(' · ');
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(t)}</title>
<meta name="description" content="${esc(d)}">
<link rel="canonical" href="${esc(url)}">
<meta property="og:site_name" content="${esc(SITE.brand)}">
<meta property="og:type" content="${type}">
<meta property="og:title" content="${esc(title || SITE.brand)}">
<meta property="og:description" content="${esc(d)}">
<meta property="og:url" content="${esc(url)}">
<meta property="og:image" content="${esc(ogImg)}">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="/assets/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/favicon-32.png">
<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
<link rel="alternate" type="application/rss+xml" title="${esc(SITE.brand)} blog" href="/feed.xml">
<meta name="theme-color" content="#0d0d0c">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600;700&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/assets/site.css">
${jsonld ? `<script type="application/ld+json">${JSON.stringify(jsonld).replace(/</g, '\\u003c')}</script>` : ''}
</head>
<body>
<header class="top"><div class="wrap">
  <a href="/" aria-label="${esc(SITE.brand)} home"><img class="logo" src="/assets/logo.png" alt="${esc(SITE.brand)}" width="160" height="51"></a>
  <nav>${link('/about/', 'About', 'about')}${link(SHOP + '/', 'Shop', 'shop')}${link(SHOP + '/#spa', 'Spa', 'spa')}${link('/blog/', 'Blog', 'blog')}${link('/contact/', 'Contact', 'contact')}</nav>
</div></header>
<main>
${body}
</main>
<footer><div class="wrap fgrid">
  <div><img src="/assets/logo.png" alt="" width="130" height="41" style="margin-bottom:8px"><div>© ${year} ${esc(SITE.company)}</div></div>
  <div><b>Visit</b><a href="${SHOP}/">Online shop</a><a href="${SHOP}/#spa">Book the spa</a><a href="/blog/">Blog</a></div>
  <div><b>Contact</b>${C.email ? `<a href="mailto:${esc(C.email)}">${esc(C.email)}</a>` : ''}${C.phone ? `<span>${esc(C.phone)}</span>` : ''}${C.whatsapp ? `<a href="${waLink(C.whatsapp)}" rel="noopener">WhatsApp ${esc(C.whatsapp)}</a>` : ''}${social ? `<span>${social}</span>` : ''}</div>
</div></footer>
</body>
</html>
`;
}

// Subscribe box: a tiny form that calls the public subscribe_blog function.
const subscribeBox = () => `
<section class="sub">
  <h2>Get new articles</h2>
  <p>Skincare tips and spa news from ${esc(SITE.brand)}, now and then. No spam.</p>
  <form class="subform" onsubmit="return rgSubscribe(this)">
    <input name="name" placeholder="Your name" autocomplete="name">
    <input name="email" type="email" placeholder="Your email" autocomplete="email" required>
    <button class="btn gold">Subscribe</button>
  </form>
  <p class="submsg" role="status"></p>
</section>
<script>
function rgSubscribe(f){var m=f.parentNode.querySelector('.submsg');m.textContent='…';
 fetch(${JSON.stringify(CFG.url + '/rest/v1/rpc/subscribe_blog')},{method:'POST',headers:{apikey:${JSON.stringify(CFG.key)},'Content-Type':'application/json'},
  body:JSON.stringify({p_email:f.email.value,p_name:f.name.value})}).then(function(r){return r.ok?null:r.json()}).then(function(e){
  m.textContent=e?(e.message||'Something went wrong.'):'Thank you! You\\u2019re subscribed.';if(!e)f.reset()}).catch(function(){m.textContent='Something went wrong. Please try again.'});return false}
</script>`;

const postCard = p => `<a class="card" href="/blog/${esc(p.slug)}/">
  <div class="cimg${p.cover_path ? '' : ' ph'}"${p.cover_path ? ` style="background-image:url('${esc(img('blog-images', p.cover_path))}')"` : ''}>${p.cover_path ? '' : '<img src="/assets/crown.png" alt="">'}</div>
  <div class="cbody"><div class="cat">${esc(p.category)}</div><h3>${esc(p.title)}</h3><div class="meta">${dateLong(p.published_at)}</div>${p.excerpt ? `<p>${esc(p.excerpt)}</p>` : ''}</div></a>`;

// ---------- build ----------
async function main() {
  const [posts, products, spa] = await Promise.all([
    api('blog_posts?select=slug,title,excerpt,body,category,cover_path,author_name,published_at,updated_at&status=eq.published&order=published_at.desc'),
    optional(api('rpc/shop_catalog', {}), []),
    optional(api('rpc/spa_info', {}), null)
  ]);
  rmSync(OUT, { recursive: true, force: true });
  mkdirSync(OUT, { recursive: true });
  cpSync(join(HERE, 'assets'), join(OUT, 'assets'), { recursive: true });
  writeFileSync(join(OUT, 'assets', 'site.css'), readFileSync(join(HERE, 'site.css')));

  const services = spa && Array.isArray(spa.services) ? spa.services : [];
  const urls = [];

  // Home
  const prodCards = products.slice(0, 4).map(p => `<a class="card" href="${SHOP}/#p/${esc(p.id)}">
    <div class="cimg${p.image_path ? '' : ' ph'}"${p.image_path ? ` style="background-image:url('${esc(img('product-images', p.image_path))}')"` : ''}>${p.image_path ? '' : '<img src="/assets/crown.png" alt="">'}</div>
    <div class="cbody"><h3>${esc(clean(p.name))}</h3><div class="price">${money(p.price)}</div>${p.description ? `<p>${esc(p.description)}</p>` : ''}</div></a>`).join('');
  const spaRows = services.slice(0, 5).map(s => `<a class="srow" href="${SHOP}/#spa/${esc(s.id)}"><span><b>${esc(clean(s.name))}</b><small>${s.duration_min} min${s.description ? ' · ' + esc(s.description) : ''}</small></span><span class="price">${money(s.price)}</span></a>`).join('');
  write('index.html', page({
    path: '/', nav: 'home',
    jsonld: { '@context': 'https://schema.org', '@type': 'Organization', name: SITE.company, url: BASE + '/', logo: BASE + '/assets/logo.png', email: C.email || undefined, telephone: C.phone || undefined },
    body: `
<section class="hero"><div class="wrap">
  <h1>${esc(SITE.tagline)}</h1>
  <p>${esc(SITE.intro)}</p>
  <div class="cta"><a class="btn gold" href="${SHOP}/">Shop products</a><a class="btn outline" href="${SHOP}/#spa">Book a spa treatment</a></div>
</div></section>
<section class="wrap pillars">
  <div><h2>Made by Royal Glow</h2><p>Skincare, personal care and spa products, many made in-house in small batches.</p><a href="${SHOP}/">Browse the shop →</a></div>
  <div><h2>The Royal Glow spa</h2><p>Facials, massages and body treatments using our own products. Book online in a minute.</p><a href="${SHOP}/#spa">See treatments →</a></div>
  <div><h2>For stockists</h2><p>${esc(SITE.partners)}</p><a href="/contact/">Contact us →</a></div>
</section>
${prodCards ? `<section class="wrap block"><div class="bhead"><h2>From the shop</h2><a href="${SHOP}/">All products →</a></div><div class="grid">${prodCards}</div></section>` : ''}
${spaRows ? `<section class="wrap block"><div class="bhead"><h2>Spa treatments</h2><a href="${SHOP}/#spa">Book online →</a></div><div class="slist">${spaRows}</div></section>` : ''}
${posts.length ? `<section class="wrap block"><div class="bhead"><h2>From the blog</h2><a href="/blog/">All articles →</a></div><div class="grid">${posts.slice(0, 3).map(postCard).join('')}</div></section>` : ''}
<div class="wrap">${subscribeBox()}</div>`
  }));
  urls.push({ loc: '/', lastmod: posts[0] && posts[0].updated_at });

  // About
  write('about/index.html', page({
    path: '/about/', nav: 'about', title: SITE.about_title, description: (SITE.about || [])[0],
    body: `<section class="wrap narrow"><h1 class="ptitle">${esc(SITE.about_title)}</h1>
${(SITE.about || []).map(p => `<p class="lead">${esc(p)}</p>`).join('\n')}
<h2 class="h2">${esc(SITE.partners_title)}</h2><p class="lead">${esc(SITE.partners)}</p>
<div class="cta"><a class="btn" href="${SHOP}/">Visit the shop</a><a class="btn ghost" href="/contact/">Contact us</a></div></section>`
  }));
  urls.push({ loc: '/about/' });

  // Contact
  const rows = [
    C.email && `<div><b>Email</b><a href="mailto:${esc(C.email)}">${esc(C.email)}</a></div>`,
    C.phone && `<div><b>Phone</b><a href="tel:${esc(C.phone.replace(/\s/g, ''))}">${esc(C.phone)}</a></div>`,
    C.whatsapp && `<div><b>WhatsApp</b><a href="${waLink(C.whatsapp)}" rel="noopener">${esc(C.whatsapp)}</a></div>`,
    C.address && `<div><b>Address</b><span>${esc(C.address)}</span></div>`,
    C.hours && `<div><b>Opening hours</b><span>${esc(C.hours)}</span></div>`
  ].filter(Boolean).join('');
  write('contact/index.html', page({
    path: '/contact/', nav: 'contact', title: 'Contact us', description: `Get in touch with ${SITE.brand}: orders, spa bookings, stockists and partnerships.`,
    body: `<section class="wrap narrow"><h1 class="ptitle">Contact us</h1>
<p class="lead">Questions about a product, an order or a spa booking? Want to stock ${esc(SITE.brand)}? We would love to hear from you.</p>
<div class="contact">${rows}</div>
<h2 class="h2">${esc(SITE.partners_title)}</h2><p class="lead">${esc(SITE.partners)}</p></section>`
  }));
  urls.push({ loc: '/contact/' });

  // Blog index
  const cats = [...new Set(posts.map(p => p.category))];
  write('blog/index.html', page({
    path: '/blog/', nav: 'blog', title: 'Blog', description: `Skincare tips, ingredients and spa advice from ${SITE.brand}.`,
    body: `<section class="wrap"><h1 class="ptitle">Blog</h1><p class="lead" style="margin-top:-6px">Skincare tips, ingredients we love, and what to expect at the spa.</p>
${cats.length > 1 ? `<div class="chips"><button class="chip on" data-c="">All</button>${cats.map(c => `<button class="chip" data-c="${esc(c)}">${esc(c)}</button>`).join('')}</div>` : ''}
${posts.length ? `<div class="grid" id="posts">${posts.map(p => postCard(p).replace('<a class="card"', `<a class="card" data-c="${esc(p.category)}"`)).join('')}</div>` : '<p class="lead">Articles are coming soon.</p>'}
${subscribeBox()}</section>
<script>document.querySelectorAll('.chip').forEach(function(b){b.onclick=function(){document.querySelectorAll('.chip').forEach(function(x){x.classList.toggle('on',x===b)});
 document.querySelectorAll('#posts .card').forEach(function(c){c.style.display=!b.dataset.c||c.dataset.c===b.dataset.c?'':'none'})}})</script>`
  }));
  urls.push({ loc: '/blog/', lastmod: posts[0] && posts[0].updated_at });

  // Articles
  for (const p of posts) {
    const url = `/blog/${p.slug}/`;
    const cover = img('blog-images', p.cover_path);
    const desc = p.excerpt || plain(p.body).slice(0, 160);
    const author = clean(p.author_name) || SITE.brand;
    const more = posts.filter(x => x.slug !== p.slug).slice(0, 3);
    write(`blog/${p.slug}/index.html`, page({
      path: url, nav: 'blog', title: p.title, description: desc, image: cover || undefined, type: 'article',
      jsonld: { '@context': 'https://schema.org', '@type': 'BlogPosting', headline: p.title, description: desc, image: cover || BASE + '/assets/og-default.jpg',
        datePublished: p.published_at, dateModified: p.updated_at, author: { '@type': 'Person', name: author },
        publisher: { '@type': 'Organization', name: SITE.company, logo: { '@type': 'ImageObject', url: BASE + '/assets/logo.png' } }, mainEntityOfPage: BASE + url },
      body: `<article class="wrap narrow">
<a class="back" href="/blog/">← All articles</a>
<div class="cat">${esc(p.category)}</div>
<h1 class="atitle">${esc(p.title)}</h1>
<div class="meta">${dateLong(p.published_at)} · ${esc(author)}</div>
${cover ? `<img class="cover" src="${esc(cover)}" alt="">` : ''}
<div class="prose">${md(p.body)}</div>
<div class="share"><a class="btn ghost" href="https://wa.me/?text=${encodeURIComponent(p.title + ' ' + BASE + url)}" rel="noopener">Share on WhatsApp</a>
<a class="btn ghost" href="https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(BASE + url)}" rel="noopener">Share on Facebook</a></div>
${subscribeBox()}
${more.length ? `<h2 class="h2">More from the blog</h2><div class="grid">${more.map(postCard).join('')}</div>` : ''}
</article>`
    }));
    urls.push({ loc: url, lastmod: p.updated_at });
  }

  // Unsubscribe
  write('blog/unsubscribe/index.html', page({
    path: '/blog/unsubscribe/', nav: 'blog', title: 'Unsubscribe', description: 'Stop receiving new-article emails.',
    body: `<section class="wrap narrow"><h1 class="ptitle">Unsubscribe</h1>
<p class="lead">Enter your email to stop receiving new-article emails. If you have a ${esc(SITE.brand)} shop account, you can also untick the option under Account in the shop.</p>
<form class="subform" onsubmit="return rgUnsub(this)"><input name="email" type="email" placeholder="Your email" required><button class="btn">Unsubscribe</button></form><p class="submsg" role="status"></p></section>
<script>function rgUnsub(f){var m=f.parentNode.querySelector('.submsg');fetch(${JSON.stringify(CFG.url + '/rest/v1/rpc/unsubscribe_blog')},{method:'POST',headers:{apikey:${JSON.stringify(CFG.key)},'Content-Type':'application/json'},
 body:JSON.stringify({p_email:f.email.value})}).then(function(r){m.textContent=r.ok?'Done. You won\\u2019t receive new-article emails from the blog list.':'Something went wrong.'});return false}</script>`
  }).replace('<meta name="description"', '<meta name="robots" content="noindex">\n<meta name="description"'));

  // 404
  write('404.html', page({ path: '/404.html', title: 'Page not found', description: 'This page could not be found.',
    body: `<section class="wrap narrow" style="text-align:center"><img src="/assets/crown.png" alt="" width="110" style="margin:0 auto 10px"><h1 class="ptitle">Page not found</h1>
<p class="lead">The page you were looking for isn't here. It may have moved.</p><div class="cta" style="justify-content:center"><a class="btn" href="/">Go to the home page</a><a class="btn ghost" href="/blog/">Read the blog</a></div></section>` }));

  // sitemap, robots, RSS
  write('sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map(u =>
    `  <url><loc>${esc(BASE + u.loc)}</loc>${u.lastmod ? `<lastmod>${new Date(u.lastmod).toISOString().slice(0, 10)}</lastmod>` : ''}</url>`).join('\n')}\n</urlset>\n`);
  write('robots.txt', `User-agent: *\nAllow: /\n\nSitemap: ${BASE}/sitemap.xml\n`);
  write('feed.xml', `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel>
<title>${esc(SITE.brand)} blog</title><link>${BASE}/blog/</link><description>${esc('Skincare tips, ingredients and spa advice from ' + SITE.brand + '.')}</description><language>en</language>
<atom:link href="${BASE}/feed.xml" rel="self" type="application/rss+xml"/>
${posts[0] ? `<lastBuildDate>${new Date(posts[0].updated_at).toUTCString()}</lastBuildDate>` : ''}
${posts.slice(0, 20).map(p => `<item><title>${esc(p.title)}</title><link>${BASE}/blog/${esc(p.slug)}/</link><guid>${BASE}/blog/${esc(p.slug)}/</guid><pubDate>${new Date(p.published_at).toUTCString()}</pubDate><category>${esc(p.category)}</category><description>${esc(p.excerpt || plain(p.body).slice(0, 300))}</description></item>`).join('\n')}
</channel></rss>
`);
  // Hostinger (Apache): show our 404 page for missing addresses
  write('.htaccess', 'ErrorDocument 404 /404.html\n');

  console.log(`Built ${OUT}: ${posts.length} articles, ${products.length} products, ${services.length} spa treatments.`);
}

main().catch(e => { console.error('Build failed:', e.message); process.exit(1); });
