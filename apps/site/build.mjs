// Builds the main website (royalglowgh.com) as plain HTML files in apps/site/dist.
// Run: node apps/site/build.mjs        (no packages to install; needs Node 20+)
// Content comes from Supabase: website settings, slides and testimonials (staff app -> Website page),
// articles, products and spa treatments. site.json only holds the two web addresses.
// If Supabase can't be reached the build stops, so a broken site is never published.
// Design: settings.design.home ("classic" | "editorial" | "showcase") and .blog ("magazine" | "minimal").
// Every style is also built under /preview/ so it can be seen before switching.

import { readFileSync, writeFileSync, mkdirSync, rmSync, cpSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { md } from './lib/md.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, 'dist');
const URLS = JSON.parse(readFileSync(join(HERE, 'site.json'), 'utf8'));
const BASE = URLS.site_url.replace(/\/$/, '');
const SHOP = URLS.shop_url.replace(/\/$/, '');

export const HOME_STYLES = ['classic', 'editorial', 'showcase'];
export const BLOG_STYLES = ['magazine', 'minimal'];
// Image slots (sizes in the design guide). Section photos are uploaded on the Website page (site-images bucket).
export const SLOTS = {
  slide:         { w: 2400, h: 1200, label: 'Slide (computer)', used: 'Classic and Showcase home' },
  slide_m:       { w: 1080, h: 1620, label: 'Slide (phone)', used: 'Classic and Showcase home on phones' },
  hero_portrait: { w: 1200, h: 1500, label: 'Editorial hero (arch)', used: 'Editorial home' },
  making:        { w: 1200, h: 900,  label: 'Our products / making', used: 'Editorial and Showcase home' },
  spa:           { w: 1200, h: 900,  label: 'Spa', used: 'Editorial and Showcase home' },
  stockists:     { w: 1200, h: 900,  label: 'Stockists / partners', used: 'Editorial and Showcase home' },
  about:         { w: 1600, h: 900,  label: 'About page banner', used: 'About page (all styles)' }
};
// Filled from the database in main().
let SITE = {}, HOME_STYLE = 'classic', BLOG_STYLE = 'magazine', IMAGES = {}, C = {}, HIGHLIGHTS = [], BADGES = [], SLIDES = [], TESTI = [];
function applySettings(data) {
  SITE = { ...data, site_url: BASE, shop_url: SHOP };
  const d = SITE.design || {};
  HOME_STYLE = HOME_STYLES.includes(d.home) ? d.home : 'classic';
  BLOG_STYLE = BLOG_STYLES.includes(d.blog) ? d.blog : 'magazine';
  IMAGES = SITE.images || {};
  C = SITE.contact || {};
  HIGHLIGHTS = (SITE.highlights || []).filter(h => h && h.title);
  BADGES = (SITE.badges || []).filter(Boolean);
  SITE.brand = SITE.brand || 'Royal Glow'; SITE.company = SITE.company || 'Royal Glow Company Limited';
  SITE.tagline = SITE.tagline || SITE.brand; SITE.intro = SITE.intro || '';
}
// URL of a slot's image: the uploaded photo if set; on preview pages a labelled placeholder; otherwise ''.
let PREVIEW = false;
const slotUrl = (key, path) => path ? img('site-images', path) : PREVIEW ? `/preview/slots/${key}.svg` : '';
const slot = key => slotUrl(key, IMAGES[key]);

// ---------- Supabase connection: env vars, or the staff app's config.js ----------
function readConfig() {
  let url = process.env.SUPABASE_URL, key = process.env.SUPABASE_KEY;
  const cfgPath = join(HERE, '..', 'staff', 'config.js');
  if ((!url || !key) && existsSync(cfgPath)) {
    const txt = readFileSync(cfgPath, 'utf8');
    url = url || (txt.match(/SUPABASE_URL:\s*'([^']+)'/) || [])[1];
    key = key || (txt.match(/SUPABASE_KEY:\s*'([^']+)'/) || [])[1];
  }
  if (!url || !key || /PASTE_/.test(url + key)) throw new Error('Supabase URL/key not found (set SUPABASE_URL and SUPABASE_KEY, or fill in apps/staff/config.js).');
  return { url: url.replace(/\/$/, ''), key };
}
const CFG = readConfig();
// Publishable keys go on the apikey header only (not Authorization: Bearer).
async function api(path, body) {
  const r = await fetch(`${CFG.url}/rest/v1/${path}`, {
    method: body ? 'POST' : 'GET',
    headers: { apikey: CFG.key, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: body ? JSON.stringify(body) : undefined
  });
  if (!r.ok) throw new Error(`${path}: ${r.status} ${await r.text()}`);
  return r.json();
}
async function optional(promise, fallback) { try { return await promise; } catch (e) { console.warn('warning:', e.message); return fallback; } }

// ---------- helpers ----------
const esc = s => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const money = v => 'GH₵ ' + Number(v || 0).toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const dateLong = t => new Date(t).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'Africa/Accra' });
const dateShort = t => new Date(t).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Africa/Accra' });
const clean = s => String(s || '').replace(/\s*\(sample\)/g, '');
const img = (bucket, p) => p ? `${CFG.url}/storage/v1/object/public/${bucket}/${String(p).split('/').map(encodeURIComponent).join('/')}` : '';
const write = (rel, html) => { const f = join(OUT, rel); mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, html); };
const plain = s => String(s || '').replace(/!\[[^\]]*\]\([^)]*\)/g, '').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/[#*>`_-]+/g, ' ').replace(/\s+/g, ' ').trim();
const waLink = n => 'https://wa.me/' + String(n).replace(/[^0-9]/g, '').replace(/^0/, '233');
const bg = u => u ? ` style="background-image:url('${esc(u)}')"` : '';
// Hero background: wide image, plus an optional phone image (used by CSS below 700px wide).
const heroBg = (w, m) => w || m ? ` style="${w ? `--hero:url('${esc(w)}');` : ''}${m ? `--hero-m:url('${esc(m)}');` : ''}"` : '';
// Links in site.json may be a keyword (shop, spa, blog, about, contact) or a full address.
const LINKS = { shop: SHOP + '/', spa: SHOP + '/#spa', blog: '/blog/', about: '/about/', contact: '/contact/' };
const linkTo = l => LINKS[l] || l || '/';

// ---------- layout ----------
function page({ path, title, description, image, type = 'website', body, jsonld, nav, home = HOME_STYLE, blog = BLOG_STYLE, noindex = false }) {
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
${noindex ? '<meta name="robots" content="noindex">\n' : ''}<meta name="description" content="${esc(d)}">
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
<meta name="theme-color" content="${home === 'editorial' ? '#faf7f1' : '#0d0d0c'}">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600;700&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/assets/site.css">
${jsonld ? `<script type="application/ld+json">${JSON.stringify(jsonld).replace(/</g, '\\u003c')}</script>` : ''}
</head>
<body class="t-${home} b-${blog}${nav === 'home' ? ' is-home' : ''}">
<div class="annbar" id="annbar" hidden></div>
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
<script>window.RG={url:${JSON.stringify(CFG.url)},key:${JSON.stringify(CFG.key)},shop:${JSON.stringify(SHOP)}};</script>
<script src="/assets/site.js" defer></script>
</body>
</html>
`;
}

// Subscribe box: a tiny form that calls the public subscribe_blog function.
const subscribeBox = () => `
<section class="sub">
  <div><h2>Get new articles</h2>
  <p>Skincare tips and spa news from ${esc(SITE.brand)}, now and then. No spam.</p></div>
  <div><form class="subform" onsubmit="return rgSubscribe(this)">
    <input name="name" placeholder="Your name" autocomplete="name">
    <input name="email" type="email" placeholder="Your email" autocomplete="email" required>
    <button class="btn gold">Subscribe</button>
  </form>
  <p class="submsg" role="status"></p></div>
</section>
<script>
function rgSubscribe(f){var m=f.parentNode.querySelector('.submsg');m.textContent='…';
 fetch(${JSON.stringify(CFG.url + '/rest/v1/rpc/subscribe_blog')},{method:'POST',headers:{apikey:${JSON.stringify(CFG.key)},'Content-Type':'application/json'},
  body:JSON.stringify({p_email:f.email.value,p_name:f.name.value})}).then(function(r){return r.ok?null:r.json()}).then(function(e){
  m.textContent=e?(e.message||'Something went wrong.'):'Thank you! You\\u2019re subscribed.';if(!e)f.reset()}).catch(function(){m.textContent='Something went wrong. Please try again.'});return false}
</script>`;

const crownPh = '<img src="/assets/crown.png" alt="">';
const postCard = p => `<a class="card" href="/blog/${esc(p.slug)}/" data-c="${esc(p.category)}">
  <div class="cimg wide${p.cover_path ? '' : ' ph'}"${bg(img('blog-images', p.cover_path))}>${p.cover_path ? '' : crownPh}</div>
  <div class="cbody"><div class="cat">${esc(p.category)}</div><h3>${esc(p.title)}</h3><div class="meta">${dateLong(p.published_at)}</div>${p.excerpt ? `<p>${esc(p.excerpt)}</p>` : ''}</div></a>`;
const postRow = p => `<a class="prow" href="/blog/${esc(p.slug)}/" data-c="${esc(p.category)}">
  <div class="meta">${dateShort(p.published_at)} · <span class="cat">${esc(p.category)}</span></div>
  <h3>${esc(p.title)}</h3>${p.excerpt ? `<p>${esc(p.excerpt)}</p>` : ''}<span class="more">Read →</span></a>`;
const featuredPost = p => `<a class="feat" href="/blog/${esc(p.slug)}/" data-c="${esc(p.category)}">
  <div class="cimg wide${p.cover_path ? '' : ' ph'}"${bg(img('blog-images', p.cover_path))}>${p.cover_path ? '' : crownPh}</div>
  <div class="fbody"><div class="cat">${esc(p.category)} · Latest</div><h2>${esc(p.title)}</h2><div class="meta">${dateLong(p.published_at)}</div>${p.excerpt ? `<p>${esc(p.excerpt)}</p>` : ''}<span class="more">Read the article →</span></div></a>`;
const productCard = p => `<a class="card" href="${SHOP}/#p/${esc(p.id)}">
  <div class="cimg sq${p.image_path ? '' : ' ph'}"${bg(img('product-images', p.image_path))}>${p.image_path ? '' : crownPh}</div>
  <div class="cbody"><h3>${esc(clean(p.name))}</h3><div class="price">${money(p.price)}</div>${p.description ? `<p>${esc(p.description)}</p>` : ''}</div></a>`;
const spaRow = s => `<a class="srow" href="${SHOP}/#spa/${esc(s.id)}"><span><b>${esc(clean(s.name))}</b><small>${s.duration_min} min${s.description ? ' · ' + esc(s.description) : ''}</small></span><span class="price">${money(s.price)}</span></a>`;
const ctaButtons = (dark) => `<div class="cta"><a class="btn gold" href="${SHOP}/">Shop products</a><a class="btn ${dark ? 'outline' : 'ghost'}" href="${SHOP}/#spa">Book a spa treatment</a></div>`;
const head = (title, href, label) => `<div class="bhead"><h2>${esc(title)}</h2><a href="${href}">${label}</a></div>`;
const HL_SLOTS = ['making', 'spa', 'stockists'];

// ---------- hero slides (Classic and Showcase) ----------
// Slides come from the Website page. With none, one slide is made from the tagline and introduction.
// Several slides stack in the same place and fade; site.js rotates them (pauses on hover/touch,
// still for visitors who prefer reduced motion). Only the first headline is the page's <h1>.
function heroSlides(kind) {
  let list = SLIDES.slice(0, 3);
  if (!list.length) list = [{}];
  if (PREVIEW && !SLIDES.length) list = [{ image_path: '', image_mobile_path: '' }];
  const slides = list.map((s, i) => {
    const w = slotUrl('slide', s.image_path), m = slotUrl('slide_m', s.image_mobile_path);
    const H = i ? 'h2' : 'h1';
    const btn = s.button_label ? `<div class="cta"><a class="btn gold" href="${esc(linkTo(s.button_link))}">${esc(s.button_label)}</a>${s.button_link !== 'spa' ? `<a class="btn outline" href="${SHOP}/#spa">Book a spa treatment</a>` : ''}</div>` : ctaButtons(true);
    const cls = kind === 'classic' ? `hero${w || m ? ' has-img' : ''}` : `shero${w || m ? '' : ' ph'}`;
    return `<div class="${cls} slide${i ? '' : ' on'}"${heroBg(w, m)}${i ? ' aria-hidden="true"' : ''}><div class="wrap">
  <${H} class="hl">${esc(s.headline || SITE.tagline)}</${H}>
  <p>${esc(s.text || SITE.intro)}</p>
  ${btn}
</div></div>`;
  });
  const dots = slides.length > 1 ? `<div class="dots wrap">${slides.map((_, i) => `<button type="button" aria-label="Slide ${i + 1}"${i ? '' : ' class="on"'}></button>`).join('')}</div>` : '';
  return `<section class="slider ${kind}-slider" data-rotate="7000" aria-roledescription="carousel">${slides.join('\n')}${dots}</section>`;
}

// ---------- testimonials ----------
// Real, published quotes only. Preview pages show clearly labelled samples when there are none.
const SAMPLE_TESTI = [
  { quote: 'Sample quote: this is where a customer’s own words about a facial or a product will appear.', name: 'Sample', town: 'Kumasi', about: 'Not shown on the live site' },
  { quote: 'Sample quote: add real testimonials on the Website page to replace these.', name: 'Sample', town: 'Accra', about: 'Not shown on the live site' },
  { quote: 'Sample quote: only words customers agreed to share are published.', name: 'Sample', town: '', about: 'Not shown on the live site' }];
const testiList = () => TESTI.length ? TESTI : PREVIEW ? SAMPLE_TESTI : [];
const who = t => `<b>${esc(t.name)}</b>${t.town ? `, ${esc(t.town)}` : ''}${t.about ? `<small>${esc(t.about)}</small>` : ''}`;
function testimonials(style, title = 'What customers say') {
  const list = testiList();
  if (!list.length) return '';
  if (style === 'cards') return `<section class="wrap block">${`<div class="bhead"><h2>${esc(title)}</h2></div>`}<div class="tcards">${list.slice(0, 3).map(t =>
    `<figure class="tcard"><blockquote>${esc(t.quote)}</blockquote><figcaption>${who(t)}</figcaption></figure>`).join('')}</div></section>`;
  // 'single' (Editorial) and 'band' (Showcase): one quote at a time, rotating.
  const items = list.slice(0, 6).map((t, i) => `<figure class="tq slide${i ? '' : ' on'}"${i ? ' aria-hidden="true"' : ''}><blockquote>${esc(t.quote)}</blockquote><figcaption>${who(t)}</figcaption></figure>`).join('');
  const dots = list.length > 1 ? `<div class="dots">${list.slice(0, 6).map((_, i) => `<button type="button" aria-label="Quote ${i + 1}"${i ? '' : ' class="on"'}></button>`).join('')}</div>` : '';
  return `<section class="${style === 'band' ? 'tband' : 'wrap tsingle'}"><div class="${style === 'band' ? 'wrap' : ''}"><div class="kicker">${esc(title)}</div><div class="slider" data-rotate="9000">${items}${dots}</div></div></section>`;
}

// ---------- home page styles ----------
const HOMES = {
  // Classic: dark gold-glow hero, three cards overlapping it, then shop, spa, testimonials and blog.
  classic({ products, services, posts }) {
    return `
${heroSlides('classic')}
${HIGHLIGHTS.length ? `<section class="wrap pillars">${HIGHLIGHTS.slice(0, 3).map(h => `<div><h2>${esc(h.title)}</h2><p>${esc(h.text)}</p>${h.link_label ? `<a href="${esc(linkTo(h.link))}">${esc(h.link_label)} →</a>` : ''}</div>`).join('')}</section>` : ''}
${products.length ? `<section class="wrap block">${head('From the shop', SHOP + '/', 'All products →')}<div class="grid">${products.slice(0, 4).map(productCard).join('')}</div></section>` : ''}
${services.length ? `<section class="wrap block">${head('Spa treatments', SHOP + '/#spa', 'Book online →')}<div class="slist">${services.slice(0, 5).map(spaRow).join('')}</div></section>` : ''}
${testimonials('cards')}
${posts.length ? `<section class="wrap block">${head('From the blog', '/blog/', 'All articles →')}<div class="grid">${posts.slice(0, 3).map(postCard).join('')}</div></section>` : ''}
<div class="wrap">${subscribeBox()}</div>`;
  },

  // Light editorial: light page, big serif headline beside a tall arched photo,
  // numbered story sections with photos alternating left and right.
  editorial({ products, services, posts }) {
    const portrait = slot('hero_portrait');
    const rows = HIGHLIGHTS.slice(0, 3).map((h, i) => {
      const u = slot(HL_SLOTS[i]);
      return `<div class="erow${i % 2 ? ' flip' : ''}">
  <div class="eimg${u ? '' : ' ph'}"${bg(u)}>${u ? '' : crownPh}</div>
  <div class="etext"><div class="num">0${i + 1}</div><h2>${esc(h.title)}</h2><p>${esc(h.text)}</p>${h.link_label ? `<a class="btn ghost" href="${esc(linkTo(h.link))}">${esc(h.link_label)}</a>` : ''}</div></div>`;
    }).join('');
    return `
<section class="ehero"><div class="wrap">
  <div class="etxt"><div class="kicker">${esc(SITE.brand)}</div><h1>${esc(SITE.tagline)}</h1><p>${esc(SITE.intro)}</p>${ctaButtons(false)}</div>
  <div class="arch${portrait ? '' : ' ph'}"${bg(portrait)}>${portrait ? '' : crownPh}</div>
</div></section>
${BADGES.length ? `<div class="wrap"><ul class="eline">${BADGES.map(b => `<li>${esc(b)}</li>`).join('')}</ul></div>` : ''}
${rows ? `<section class="wrap erows">${rows}</section>` : ''}
${testimonials('single', 'Kind words')}
${products.length ? `<section class="wrap block">${head('From the shop', SHOP + '/', 'All products →')}<div class="grid four">${products.slice(0, 4).map(productCard).join('')}</div></section>` : ''}
${services.length ? `<section class="wrap block espa"><div><h2>Spa treatments</h2><p class="lead">Book online in a minute and pay at the spa.</p><a class="btn" href="${SHOP}/#spa">Book a treatment</a></div><div class="slist">${services.slice(0, 5).map(spaRow).join('')}</div></section>` : ''}
${posts.length ? `<section class="wrap block">${head('From the journal', '/blog/', 'All articles →')}<div class="plist">${posts.slice(0, 3).map(postRow).join('')}</div></section>` : ''}
<div class="wrap">${subscribeBox()}</div>`;
  },

  // Showcase: full-width photo slides, a gold strip of short promises, photo tiles,
  // large product cards, a spa block with a photo, testimonials band, stockist band.
  showcase({ products, services, posts }) {
    const spaImg = slot('spa');
    const tiles = HIGHLIGHTS.slice(0, 3).map((h, i) => {
      const u = slot(HL_SLOTS[i]);
      return `<a class="tile${u ? '' : ' ph'}" href="${esc(linkTo(h.link))}"${bg(u)}><span><b>${esc(h.title)}</b><small>${esc(h.link_label || 'Find out more')} →</small></span></a>`;
    }).join('');
    const stock = HIGHLIGHTS[2];
    return `
${heroSlides('showcase')}
${BADGES.length ? `<div class="strip"><div class="wrap">${BADGES.map(b => `<span>${esc(b)}</span>`).join('')}</div></div>` : ''}
${tiles ? `<section class="wrap tiles">${tiles}</section>` : ''}
${products.length ? `<section class="wrap block">${head('Bestsellers', SHOP + '/', 'Shop all →')}<div class="grid big">${products.slice(0, 3).map(productCard).join('')}</div></section>` : ''}
${services.length ? `<section class="sspa"><div class="simg${spaImg ? '' : ' ph'}"${bg(spaImg)}>${spaImg ? '' : crownPh}</div><div class="stext"><h2>The ${esc(SITE.brand)} spa</h2><div class="slist">${services.slice(0, 4).map(spaRow).join('')}</div><a class="btn gold" href="${SHOP}/#spa">Book a treatment</a></div></section>` : ''}
${testimonials('band')}
${posts.length ? `<section class="wrap block">${head('From the blog', '/blog/', 'All articles →')}<div class="grid">${posts.slice(0, 3).map(postCard).join('')}</div></section>` : ''}
${stock ? `<section class="band"><div class="wrap"><div><h2>${esc(stock.title)}</h2><p>${esc(stock.text)}</p></div><a class="btn" href="${esc(linkTo(stock.link))}">${esc(stock.link_label || 'Contact us')}</a></div></section>` : ''}
<div class="wrap">${subscribeBox()}</div>`;
  }
};

// ---------- blog styles ----------
function blogIndexBody(posts, style) {
  const cats = [...new Set(posts.map(p => p.category))];
  const chips = cats.length > 1 ? `<div class="chips"><button class="chip on" data-c="">All</button>${cats.map(c => `<button class="chip" data-c="${esc(c)}">${esc(c)}</button>`).join('')}</div>` : '';
  let list = '<p class="lead">Articles are coming soon.</p>';
  if (posts.length && style === 'minimal') list = `<div class="plist" id="posts">${posts.map(postRow).join('')}</div>`;
  else if (posts.length) list = `<div id="posts">${featuredPost(posts[0])}${posts.length > 1 ? `<div class="grid">${posts.slice(1).map(postCard).join('')}</div>` : ''}</div>`;
  return `<section class="wrap${style === 'minimal' ? ' narrow' : ''}"><h1 class="ptitle">Blog</h1><p class="lead" style="margin-top:-6px">Skincare tips, ingredients we love, and what to expect at the spa.</p>
${chips}
${list}
${subscribeBox()}</section>
<script>document.querySelectorAll('.chip').forEach(function(b){b.onclick=function(){document.querySelectorAll('.chip').forEach(function(x){x.classList.toggle('on',x===b)});
 document.querySelectorAll('#posts [data-c]').forEach(function(c){c.style.display=!b.dataset.c||c.dataset.c===b.dataset.c?'':'none'})}})</script>`;
}

function articleBody(p, posts, style, url) {
  const cover = img('blog-images', p.cover_path);
  const author = clean(p.author_name) || SITE.brand;
  const more = posts.filter(x => x.slug !== p.slug).slice(0, 3);
  const share = `<div class="share"><a class="btn ghost" href="https://wa.me/?text=${encodeURIComponent(p.title + ' ' + BASE + url)}" rel="noopener">Share on WhatsApp</a>
<a class="btn ghost" href="https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(BASE + url)}" rel="noopener">Share on Facebook</a></div>`;
  if (style === 'minimal') return `<article class="wrap narrow amin">
<a class="back" href="/blog/">← All articles</a>
<div class="meta">${dateLong(p.published_at)} · <span class="cat">${esc(p.category)}</span></div>
<h1 class="atitle">${esc(p.title)}</h1>
${p.excerpt ? `<p class="lead">${esc(p.excerpt)}</p>` : ''}
<div class="meta">By ${esc(author)}</div>
${cover ? `<img class="cover" src="${esc(cover)}" alt="">` : '<hr class="rule">'}
<div class="prose">${md(p.body)}</div>
${share}
${subscribeBox()}
${more.length ? `<h2 class="h2">More from the blog</h2><div class="plist">${more.map(postRow).join('')}</div>` : ''}
</article>`;
  return `${cover ? `<div class="acover"${bg(cover)}></div>` : ''}<article class="wrap narrow amag${cover ? ' over' : ''}">
<a class="back" href="/blog/">← All articles</a>
<div class="cat">${esc(p.category)}</div>
<h1 class="atitle">${esc(p.title)}</h1>
<div class="meta">${dateLong(p.published_at)} · ${esc(author)}</div>
<div class="prose">${md(p.body)}</div>
${share}
${subscribeBox()}
</article>
${more.length ? `<section class="wrap block"><h2 class="h2">More from the blog</h2><div class="grid">${more.map(postCard).join('')}</div></section>` : ''}`;
}

// Labelled placeholder images for the preview pages, so designers see each slot and its size.
function slotSvg(key) {
  const s = SLOTS[key];
  const fs = Math.round(Math.min(s.w, s.h) / 14);
  const x = key === 'slide' ? '74%' : '50%'; // the left of the wide banner sits under the headline
  const cy = key === 'slide' || key === 'slide_m' ? s.h * 0.2 : s.h / 2; // hero text sits lower down
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${s.w}" height="${s.h}" viewBox="0 0 ${s.w} ${s.h}">
<defs><pattern id="p" width="60" height="60" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="60" height="60" fill="#2a2416"/><rect width="30" height="60" fill="#30291a"/></pattern></defs>
<rect width="100%" height="100%" fill="url(#p)"/>
<rect x="${s.w * 0.05}" y="${s.h * 0.05}" width="${s.w * 0.9}" height="${s.h * 0.9}" fill="none" stroke="#c8961e" stroke-width="4" stroke-dasharray="18 12"/>
<g font-family="Arial, sans-serif" text-anchor="middle" fill="#f7e7bf">
<text x="${x}" y="${cy - fs * 0.4}" font-size="${fs}" font-weight="700">${esc(s.label.toUpperCase())}</text>
<text x="${x}" y="${cy + fs * 0.9}" font-size="${Math.round(fs * 0.8)}">${s.w} × ${s.h} px · images.${key}</text>
</g></svg>`;
}

// ---------- build ----------
async function main() {
  const [settings, posts, products, spa, slides, testi] = await Promise.all([
    api('site_settings?select=data&id=eq.1').catch(e => { throw new Error('website settings could not be read (has 011_website.sql been run?): ' + e.message); }),
    api('blog_posts?select=slug,title,excerpt,body,category,cover_path,author_name,published_at,updated_at&status=eq.published&order=published_at.desc'),
    optional(api('rpc/shop_catalog', {}), []),
    optional(api('rpc/spa_info', {}), null),
    optional(api('site_slides?select=headline,text,button_label,button_link,image_path,image_mobile_path&active=eq.true&order=sort,created_at'), []),
    optional(api('testimonials?select=quote,name,town,about,service_id&order=sort,created_at.desc&limit=12'), [])
  ]);
  if (!settings.length) throw new Error('website settings are empty (run 011_website.sql).');
  applySettings(settings[0].data || {});
  SLIDES = slides; TESTI = testi;
  rmSync(OUT, { recursive: true, force: true });
  mkdirSync(OUT, { recursive: true });
  cpSync(join(HERE, 'assets'), join(OUT, 'assets'), { recursive: true });
  writeFileSync(join(OUT, 'assets', 'site.css'), readFileSync(join(HERE, 'site.css')));
  writeFileSync(join(OUT, 'assets', 'site.js'), readFileSync(join(HERE, 'site.js')));

  const services = spa && Array.isArray(spa.services) ? spa.services : [];
  const data = { posts, products, services };
  const urls = [];
  const orgLd = { '@context': 'https://schema.org', '@type': 'Organization', name: SITE.company, url: BASE + '/', logo: BASE + '/assets/logo.png', email: C.email || undefined, telephone: C.phone || undefined };

  // Home (the chosen style)
  write('index.html', page({ path: '/', nav: 'home', jsonld: orgLd, body: HOMES[HOME_STYLE](data) }));
  urls.push({ loc: '/', lastmod: posts[0] && posts[0].updated_at });

  // About
  const aboutImg = slot('about');
  write('about/index.html', page({
    path: '/about/', nav: 'about', title: SITE.about_title, description: (SITE.about || [])[0],
    body: `${aboutImg ? `<div class="abanner"${bg(aboutImg)}></div>` : ''}<section class="wrap narrow"><h1 class="ptitle">${esc(SITE.about_title)}</h1>
${(SITE.about || []).map(p => `<p class="lead">${esc(p)}</p>`).join('\n')}
<h2 class="h2">${esc(SITE.partners_title)}</h2><p class="lead">${esc(SITE.partners)}</p>
<div class="cta"><a class="btn" href="${SHOP}/">Visit the shop</a><a class="btn ghost" href="/contact/">Contact us</a></div></section>
${testimonials('cards')}`
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

  // Blog index and articles (the chosen blog style)
  const blogMeta = { title: 'Blog', description: `Skincare tips, ingredients and spa advice from ${SITE.brand}.` };
  write('blog/index.html', page({ path: '/blog/', nav: 'blog', ...blogMeta, body: blogIndexBody(posts, BLOG_STYLE) }));
  urls.push({ loc: '/blog/', lastmod: posts[0] && posts[0].updated_at });
  const articleLd = (p, url, desc) => ({ '@context': 'https://schema.org', '@type': 'BlogPosting', headline: p.title, description: desc, image: img('blog-images', p.cover_path) || BASE + '/assets/og-default.jpg',
    datePublished: p.published_at, dateModified: p.updated_at, author: { '@type': 'Person', name: clean(p.author_name) || SITE.brand },
    publisher: { '@type': 'Organization', name: SITE.company, logo: { '@type': 'ImageObject', url: BASE + '/assets/logo.png' } }, mainEntityOfPage: BASE + url });
  for (const p of posts) {
    const url = `/blog/${p.slug}/`;
    const desc = p.excerpt || plain(p.body).slice(0, 160);
    write(`blog/${p.slug}/index.html`, page({
      path: url, nav: 'blog', title: p.title, description: desc, image: img('blog-images', p.cover_path) || undefined, type: 'article',
      jsonld: articleLd(p, url, desc), body: articleBody(p, posts, BLOG_STYLE, url)
    }));
    urls.push({ loc: url, lastmod: p.updated_at });
  }

  // Unsubscribe
  write('blog/unsubscribe/index.html', page({
    path: '/blog/unsubscribe/', nav: 'blog', title: 'Unsubscribe', description: 'Stop receiving new-article emails.', noindex: true,
    body: `<section class="wrap narrow"><h1 class="ptitle">Unsubscribe</h1>
<p class="lead">Enter your email to stop receiving new-article emails. If you have a ${esc(SITE.brand)} shop account, you can also untick the option under Account in the shop.</p>
<form class="subform" onsubmit="return rgUnsub(this)"><input name="email" type="email" placeholder="Your email" required><button class="btn">Unsubscribe</button></form><p class="submsg" role="status"></p></section>
<script>function rgUnsub(f){var m=f.parentNode.querySelector('.submsg');fetch(${JSON.stringify(CFG.url + '/rest/v1/rpc/unsubscribe_blog')},{method:'POST',headers:{apikey:${JSON.stringify(CFG.key)},'Content-Type':'application/json'},
 body:JSON.stringify({p_email:f.email.value})}).then(function(r){m.textContent=r.ok?'Done. You won\\u2019t receive new-article emails from the blog list.':'Something went wrong.'});return false}</script>`
  }));

  // "How was your visit?" form, opened from a one-time link staff send (feedback/?t=...)
  write('feedback/index.html', page({
    path: '/feedback/', title: 'How was your visit?', description: `Tell ${SITE.brand} how it went.`, noindex: true,
    body: `<section class="wrap narrow fb"><h1 class="ptitle">How was your visit?</h1>
<p class="lead" id="fbAbout">Thank you for choosing ${esc(SITE.brand)}. We read every reply.</p>
<form id="fbForm" class="hidden" onsubmit="return rgFeedback(this)">
  <label>Your words<textarea name="quote" rows="5" maxlength="600" required placeholder="What did you enjoy? Anything we could do better?"></textarea></label>
  <div class="fbrow"><label>Your first name<input name="name" maxlength="60" required autocomplete="given-name"></label><label>Town (optional)<input name="town" maxlength="60"></label></div>
  <label class="chk"><input type="checkbox" name="consent"> ${esc(SITE.brand)} may show my words, first name and town on its website.</label>
  <button class="btn gold">Send</button><p class="submsg" role="status"></p>
</form>
<p class="lead hidden" id="fbDone"></p></section>
<script>
(function(){var t=new URLSearchParams(location.search).get('t'),f=document.getElementById('fbForm'),done=document.getElementById('fbDone');
 var H={apikey:${JSON.stringify(CFG.key)},'Content-Type':'application/json'},U=${JSON.stringify(CFG.url + '/rest/v1/rpc/')};
 function end(m){f.classList.add('hidden');done.textContent=m;done.classList.remove('hidden')}
 if(!/^[0-9a-f-]{36}$/i.test(t||''))return end('This link is not complete. Please open the link you were sent.');
 fetch(U+'feedback_info',{method:'POST',headers:H,body:JSON.stringify({p_token:t})}).then(function(r){return r.json()}).then(function(i){
  if(!i||!i.ok)return end((i&&i.message)||'This link is not valid.');
  if(i.about)document.getElementById('fbAbout').textContent='Thank you for choosing ${esc(SITE.brand)}. How was your '+i.about+'?';
  f.classList.remove('hidden')}).catch(function(){end('Something went wrong. Please try again later.')});
 window.rgFeedback=function(f){var m=f.querySelector('.submsg');m.textContent='Sending…';
  fetch(U+'submit_feedback',{method:'POST',headers:H,body:JSON.stringify({p_token:t,p_quote:f.quote.value,p_name:f.name.value,p_town:f.town.value,p_consent:f.consent.checked})})
  .then(function(r){return r.ok?null:r.json()}).then(function(e){if(e)m.textContent=e.message||'Something went wrong.';else end('Thank you! We have received your feedback.')})
  .catch(function(){m.textContent='Something went wrong. Please try again.'});return false};
})();
</script>`
  }));

  // 404
  write('404.html', page({ path: '/404.html', title: 'Page not found', description: 'This page could not be found.', noindex: true,
    body: `<section class="wrap narrow" style="text-align:center"><img src="/assets/crown.png" alt="" width="110" style="margin:0 auto 10px"><h1 class="ptitle">Page not found</h1>
<p class="lead">The page you were looking for isn't here. It may have moved.</p><div class="cta" style="justify-content:center"><a class="btn" href="/">Go to the home page</a><a class="btn ghost" href="/blog/">Read the blog</a></div></section>` }));

  // Previews of every style (hidden from Google), with labelled placeholders for missing images.
  PREVIEW = true;
  for (const k of Object.keys(SLOTS)) write(`preview/slots/${k}.svg`, slotSvg(k));
  for (const s of HOME_STYLES) write(`preview/home-${s}/index.html`, page({ path: `/preview/home-${s}/`, nav: 'home', home: s, title: `Preview: ${s} home`, noindex: true, body: HOMES[s](data) }));
  for (const s of BLOG_STYLES) {
    write(`preview/blog-${s}/index.html`, page({ path: `/preview/blog-${s}/`, nav: 'blog', blog: s, ...blogMeta, title: `Preview: ${s} blog`, noindex: true, body: blogIndexBody(posts, s) }));
    if (posts[0]) write(`preview/blog-${s}/article/index.html`, page({ path: `/preview/blog-${s}/article/`, nav: 'blog', blog: s, title: `Preview: ${s} article`, noindex: true, body: articleBody(posts[0], posts, s, `/blog/${posts[0].slug}/`) }));
  }
  PREVIEW = false;
  const cur = s => s ? ' <span class="cur">in use</span>' : '';
  write('preview/index.html', page({ path: '/preview/', title: 'Design previews', noindex: true, body: `<section class="wrap narrow"><h1 class="ptitle">Design previews</h1>
<p class="lead">Every design style, built with the current content. Dashed gold boxes mark images that haven't been added yet, with their size. To switch, change <code>design</code> in <code>apps/site/site.json</code>.</p>
<h2 class="h2">Home page</h2><div class="plist">${HOME_STYLES.map(s => `<a class="prow" href="/preview/home-${s}/"><h3>${s[0].toUpperCase() + s.slice(1)}${cur(s === HOME_STYLE)}</h3><span class="more">Open →</span></a>`).join('')}</div>
<h2 class="h2">Blog</h2><div class="plist">${BLOG_STYLES.map(s => `<a class="prow" href="/preview/blog-${s}/"><h3>${s[0].toUpperCase() + s.slice(1)}${cur(s === BLOG_STYLE)}</h3><p>Article list. <span class="more">Open →</span></p></a>${posts[0] ? `<a class="prow" href="/preview/blog-${s}/article/"><h3>${s[0].toUpperCase() + s.slice(1)}: article page</h3><span class="more">Open →</span></a>` : ''}`).join('')}</div></section>` }));

  // sitemap, robots, RSS
  write('sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map(u =>
    `  <url><loc>${esc(BASE + u.loc)}</loc>${u.lastmod ? `<lastmod>${new Date(u.lastmod).toISOString().slice(0, 10)}</lastmod>` : ''}</url>`).join('\n')}\n</urlset>\n`);
  write('robots.txt', `User-agent: *\nAllow: /\nDisallow: /preview/\n\nSitemap: ${BASE}/sitemap.xml\n`);
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

  console.log(`Built ${OUT}: home "${HOME_STYLE}", blog "${BLOG_STYLE}"; ${posts.length} articles, ${products.length} products, ${services.length} spa treatments.`);
}

main().catch(e => { console.error('Build failed:', e.message); process.exit(1); });
