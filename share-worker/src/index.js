// ScreenVoicer share links: a Cloudflare Worker + KV (both on the free plan).
//
//   POST   /api/shares            multipart: meta (JSON) + image × N (+ optional preview JPEG)
//                                 → { id, url, deleteToken, expiresAt }
//   GET    /s/:id                 the page people open (screenshots + comments, link previews for messengers)
//   GET    /s/:id.md              the same as Markdown: image links + comments, for AI assistants and agents
//   GET    /s/:id.json            the same as JSON
//   GET    /i/:id/:n.png          one image; /i/:id/p.jpg is the small preview messengers show
//   DELETE /api/shares/:id        Authorization: Bearer <deleteToken>
//
// Everything expires by itself after TTL_DAYS (KV expirationTtl), so storage never grows without bound.
// The page is plain HTML + a little JS: copying (image + comment), downloading (the comment written into the PNG)
// and the ZIP of all screenshots happen in the viewer's browser, so the Worker stays within the free CPU limit.

const TTL_DAYS = 30;
const MAX_IMAGES = 10;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024; // a 4K PNG is ~3–6 MB; KV allows 25 MB per value
const MAX_PREVIEW_BYTES = 1024 * 1024;
const MAX_COMMENT = 4000;
const ID_LENGTH = 10;
const ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'; // no look-alikes (0/O, 1/l/I)
const LANDING = 'https://sv.mospan.com.ua/';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
      let m;
      if (request.method === 'POST' && path === '/api/shares') return await createShare(request, env, url);
      if (request.method === 'POST' && path === '/api/transcribe') return await transcribe(request, env);
      if (request.method === 'DELETE' && (m = path.match(/^\/api\/shares\/([A-Za-z0-9]{10})$/))) return await deleteShare(request, env, m[1]);
      if (request.method === 'GET' && (m = path.match(/^\/i\/([A-Za-z0-9]{10})\/(\d{1,2}|p)\.(png|jpg)$/))) return await getImage(env, m[1], m[2]);
      if (request.method === 'GET' && (m = path.match(/^\/s\/([A-Za-z0-9]{10})(\.md|\.json)?$/))) return await sharePage(env, url, m[1], m[2]);
      if (request.method === 'GET' && path === '/api/health') return json({ ok: true, ttlDays: TTL_DAYS, maxImages: MAX_IMAGES });
      if (request.method === 'GET' && path === '/') return Response.redirect(LANDING, 302);
      return page(404, 'Сторінку не знайдено', notFoundBody());
    } catch (error) {
      console.error(error);
      return json({ error: 'server_error' }, 500);
    }
  }
};

// ───────────────────────────── API ─────────────────────────────

// Voice comments from the apps (from 1.12.7): Workers AI speech recognition on the free plan (10 000 neurons a day,
// about 3.5 hours of speech for everyone together; past that the call fails and the apps recognize on the computer).
const TRANSCRIBE_MODEL = '@cf/openai/whisper-large-v3-turbo';
const MAX_AUDIO_BASE64 = 3 * 1024 * 1024; // ~70 s of 16 kHz mono 16-bit WAV
const UKRAINIAN_PROMPT = 'Коментар до знімка екрана: що не працює і що треба виправити.';
// Google Gemini hears Ukrainian noticeably better than Whisper. It runs when the GEMINI_API_KEY secret is set
// (a free Google AI Studio key: npx wrangler secret put GEMINI_API_KEY); past its free daily limit, or on any error,
// Workers AI Whisper takes over. GEMINI_MODEL (a plain var) can pin another model.
const GEMINI_MODEL = 'gemini-flash-latest';
const GEMINI_PROMPT = 'Transcribe this voice recording word for word, exactly as spoken, in the language spoken ' +
  '(usually Ukrainian, sometimes English or a mix). Keep Ukrainian words in Ukrainian; do not translate. ' +
  'Add normal punctuation. Write numbers as digits when that is natural. ' +
  'Output only the transcript, with no quotes, notes or timestamps. If there is no speech, output nothing.';

async function transcribeWithGemini(env, audio) {
  const model = env.GEMINI_MODEL || GEMINI_MODEL;
  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
    body: JSON.stringify({
      contents: [{ role: 'user', parts: [{ text: GEMINI_PROMPT }, { inline_data: { mime_type: 'audio/wav', data: audio } }] }],
      generationConfig: { temperature: 0 }
    })
  });
  if (!response.ok) throw new Error(`gemini ${response.status}: ${(await response.text()).slice(0, 300)}`);
  const data = await response.json();
  return (data?.candidates?.[0]?.content?.parts || []).map(part => part.text || '').join('').trim();
}

async function transcribe(request, env) {
  if (!env.AI) return json({ error: 'unavailable' }, 503);
  if (!(request.headers.get('user-agent') || '').startsWith('ScreenVoicer/')) return json({ error: 'forbidden' }, 403);
  if (Number(request.headers.get('content-length') || 0) > MAX_AUDIO_BASE64 + 4096) return json({ error: 'audio_too_long' }, 413);
  let body;
  try { body = await request.json(); } catch { return json({ error: 'bad_request' }, 400); }
  const audio = typeof body?.audio === 'string' ? body.audio : '';
  if (!audio || audio.length > MAX_AUDIO_BASE64) return json({ error: 'bad_audio' }, 400);

  if (env.GEMINI_API_KEY) {
    try {
      const text = await transcribeWithGemini(env, audio);
      return json({ text, language: '', engine: 'gemini' });
    } catch (error) {
      console.log('gemini failed, using whisper', String(error));
    }
  }

  const run = language => env.AI.run(TRANSCRIBE_MODEL, {
    audio,
    vad_filter: true,
    condition_on_previous_text: false,
    ...(language ? { language, initial_prompt: UKRAINIAN_PROMPT } : {})
  });
  try {
    let result = await run(null);
    let language = String(result?.transcription_info?.language || '');
    // Whisper now and then hears Ukrainian as Russian; the people using ScreenVoicer speak Ukrainian, so that one is redone
    if (language === 'ru') {
      result = await run('uk');
      language = 'uk';
    }
    return json({ text: String(result?.text || '').trim(), language, engine: 'whisper' });
  } catch (error) {
    console.log('transcription failed', String(error));
    return json({ error: 'unavailable' }, 503);
  }
}

async function createShare(request, env, url) {
  const type = request.headers.get('content-type') || '';
  if (!type.startsWith('multipart/form-data')) return json({ error: 'expected_multipart' }, 415);

  const form = await request.formData();
  let meta;
  try {
    meta = JSON.parse(form.get('meta') || '{}');
  } catch {
    return json({ error: 'bad_meta' }, 400);
  }

  const files = form.getAll('image');
  if (files.length < 1 || files.length > MAX_IMAGES) return json({ error: 'image_count', max: MAX_IMAGES }, 400);

  const items = [];
  const images = [];
  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    if (typeof file === 'string' || file.size > MAX_IMAGE_BYTES) return json({ error: 'image_too_large', maxBytes: MAX_IMAGE_BYTES }, 413);
    const bytes = new Uint8Array(await file.arrayBuffer());
    const kind = sniff(bytes);
    if (!kind) return json({ error: 'not_an_image' }, 415);
    const info = (meta.items && meta.items[i]) || {};
    items.push({
      ext: kind.ext,
      type: kind.type,
      comment: String(info.comment || '').slice(0, MAX_COMMENT),
      width: clampInt(info.width, 1, 20000),
      height: clampInt(info.height, 1, 20000),
      createdAt: typeof info.createdAt === 'string' ? info.createdAt.slice(0, 40) : null
    });
    images.push({ bytes, type: kind.type });
  }

  // A small JPEG of the first screenshot for link previews: WhatsApp and some messengers skip big og:images.
  // Apps before 1.12 don't send it; the page then falls back to the first screenshot.
  let preview = null;
  const previewFile = form.get('preview');
  if (previewFile && typeof previewFile !== 'string' && previewFile.size <= MAX_PREVIEW_BYTES) {
    const bytes = new Uint8Array(await previewFile.arrayBuffer());
    const kind = sniff(bytes);
    if (kind) preview = { bytes, ...kind };
  }

  const id = randomString(ID_LENGTH);
  const deleteToken = randomString(28);
  const ttl = TTL_DAYS * 86400;
  const expiresAt = new Date(Date.now() + ttl * 1000).toISOString();

  // The free plan has a storage and a daily write limit; when either is reached the writes fail, and the apps tell
  // the user to try later instead of showing a server error. Parts already written expire on their own.
  try {
    await Promise.all(images.map((image, n) =>
      env.SHARES.put(`img:${id}:${n}`, image.bytes, { expirationTtl: ttl, metadata: { type: image.type } })));
    if (preview) await env.SHARES.put(`img:${id}:p`, preview.bytes, { expirationTtl: ttl, metadata: { type: preview.type } });
  } catch (error) {
    console.log('share storage refused a write', String(error));
    return json({ error: 'storage_full' }, 503);
  }
  await env.SHARES.put(`share:${id}`, JSON.stringify({
    id,
    createdAt: new Date().toISOString(),
    expiresAt,
    deleteHash: await sha256(deleteToken),
    title: String(meta.title || '').slice(0, 200),
    app: String(meta.app || '').slice(0, 40),
    // caption: the app wrote the comment under the screenshot in the preview picture (apps from 1.12.1)
    preview: preview ? { ext: preview.ext, caption: meta.previewCaption === true } : null,
    items
  }), { expirationTtl: ttl });

  return json({ id, url: `${url.origin}/s/${id}`, deleteToken, expiresAt }, 201);
}

async function deleteShare(request, env, id) {
  const share = await env.SHARES.get(`share:${id}`, { type: 'json' });
  if (!share) return json({ ok: true, alreadyGone: true });
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token || (await sha256(token)) !== share.deleteHash) return json({ error: 'forbidden' }, 403);
  await Promise.all([
    env.SHARES.delete(`share:${id}`),
    env.SHARES.delete(`img:${id}:p`),
    ...share.items.map((_, n) => env.SHARES.delete(`img:${id}:${n}`))
  ]);
  return json({ ok: true });
}

async function getImage(env, id, n) {
  const { value, metadata } = await env.SHARES.getWithMetadata(`img:${id}:${n}`, { type: 'arrayBuffer', cacheTtl: 3600 });
  if (!value) return new Response('Not found', { status: 404 });
  return new Response(value, {
    headers: {
      'content-type': (metadata && metadata.type) || 'image/png',
      'cache-control': 'public, max-age=86400, immutable',
      'access-control-allow-origin': '*',
      'x-content-type-options': 'nosniff'
    }
  });
}

// ───────────────────────────── page ─────────────────────────────

async function sharePage(env, url, id, format) {
  const share = await env.SHARES.get(`share:${id}`, { type: 'json', cacheTtl: 300 });
  if (!share) {
    if (format) return json({ error: 'expired' }, 404);
    return page(404, 'Посилання більше не діє', expiredBody());
  }

  const count = share.items.length;
  const link = `${url.origin}/s/${id}`;
  const imageUrl = n => `${url.origin}/i/${id}/${n}.${share.items[n].ext}`;
  const expiresText = new Date(share.expiresAt).toLocaleDateString('uk-UA', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'Europe/Kyiv' });
  const expiresShort = new Date(share.expiresAt).toLocaleDateString('uk-UA', { day: 'numeric', month: 'long', timeZone: 'Europe/Kyiv' });
  const items = share.items.map((item, n) => ({
    src: imageUrl(n),
    ext: item.ext,
    comment: (item.comment || '').trim(),
    width: item.width || null,
    height: item.height || null
  }));

  if (format === '.json') {
    return json({ id, url: link, expiresAt: share.expiresAt, items: items.map((item, n) => ({ n: n + 1, ...item })) }, 200, true);
  }
  const markdown = toMarkdown(items, link, expiresText);
  if (format === '.md') {
    return new Response(markdown, {
      headers: {
        'content-type': 'text/markdown; charset=utf-8',
        'cache-control': 'public, max-age=300',
        'access-control-allow-origin': '*',
        'x-robots-tag': 'noindex'
      }
    });
  }

  const shots = count === 1 ? 'Знімок екрана' : `${count} ${plural(count, 'знімок', 'знімки', 'знімків')} екрана`;
  const first = items.map(i => i.comment).find(Boolean) || '';
  // Messengers show the site name, a bold title, the description, then the picture, always in that order. The comment
  // goes in exactly once: as the description, or (apps from 1.12.1) written under the screenshot in the preview picture
  // itself, which reads picture first, comment below; then there is no description at all.
  const card = !!(share.preview && share.preview.caption);
  const ogTitle = first ? (count === 1 ? 'Знімок екрана з коментарем' : `${shots} з коментарями`) : shots;
  const ogDescription = card || !first ? ''
    : count === 1 ? truncate(oneLine(first), 300)
    : truncate(items.map((i, n) => i.comment ? `${n + 1}. ${oneLine(i.comment)}` : '').filter(Boolean).join('  '), 300);
  const ogImage = share.preview ? `${url.origin}/i/${id}/p.${share.preview.ext}` : imageUrl(0);
  const tabTitle = first ? truncate(oneLine(first), 70) : shots;

  const head = `
${ogDescription ? `<meta name="description" content="${esc(ogDescription)}">` : ''}
<meta property="og:type" content="article">
<meta property="og:site_name" content="ScreenVoicer">
<meta property="og:title" content="${esc(ogTitle)}">
${ogDescription ? `<meta property="og:description" content="${esc(ogDescription)}">` : ''}
<meta property="og:url" content="${link}">
<meta property="og:image" content="${ogImage}">
<meta property="og:image:alt" content="${esc(truncate(first || shots, 200))}">
${!share.preview && items[0].width ? `<meta property="og:image:width" content="${items[0].width}"><meta property="og:image:height" content="${items[0].height}">` : ''}
<meta name="twitter:card" content="summary_large_image">
<meta name="robots" content="noindex">
<link rel="alternate" type="text/markdown" href="${link}.md" title="Markdown для AI">
<link rel="alternate" type="application/json" href="${link}.json">`;

  const figures = items.map((item, n) => `
  <article class="shot" id="${n + 1}">
    <button class="frame" type="button" data-zoom="${n}" aria-label="Відкрити знімок ${n + 1} на весь екран">
      <img src="${item.src}" ${item.width ? `width="${item.width}" height="${item.height}"` : ''} alt="${esc(item.comment ? truncate(oneLine(item.comment), 160) : `Знімок ${n + 1}`)}" loading="${n === 0 ? 'eager' : 'lazy'}" decoding="async">
    </button>
    <div class="cap${count > 1 ? ' step' : ''}">
      ${count > 1 ? `<span class="marker" aria-label="Крок ${n + 1}">${n + 1}</span>` : ''}
      ${item.comment ? `<p class="comment">${keepNumbers(esc(item.comment))}</p>` : '<p class="comment none">Без коментаря</p>'}
      <div class="acts">
        <button class="ib" type="button" data-copy="${n}" aria-label="Копіювати" title="${item.comment ? 'Копіювати знімок разом із коментарем' : 'Копіювати знімок'}">${ICON.copy}</button>
        <button class="ib" type="button" data-download="${n}" aria-label="Завантажити" title="Завантажити PNG">${ICON.download}</button>
      </div>
    </div>
  </article>`).join('');

  const data = { id, link, markdown, items: items.map(i => ({ src: i.src, ext: i.ext, comment: i.comment })) };
  const body = `
<header class="bar"><div class="bar-in">
  <a class="brand" href="${LANDING}" aria-label="ScreenVoicer: сайт програми">${LOGO}<span>ScreenVoicer</span></a>
  <span class="meta" title="Посилання діє до ${esc(expiresText)}. Автор може видалити його раніше.">${count} ${plural(count, 'знімок', 'знімки', 'знімків')} · до ${esc(expiresShort)}</span>
  <div class="tools">
    <button class="chip" id="copyAi" type="button" aria-label="Копіювати для AI" title="Текст із посиланнями на знімки й коментарями: вставте в ChatGPT, Claude чи Cursor">${ICON.spark}<span>Копіювати для AI</span></button>
    ${count > 1 ? `<button class="chip" id="zip" type="button" aria-label="Завантажити все" title="Усі знімки одним архівом, коментарі окремим файлом поруч">${ICON.download}<span>Завантажити все</span></button>` : ''}
    <button class="chip" id="copyLink" type="button" aria-label="Копіювати посилання">${ICON.link}<span>Копіювати посилання</span></button>
  </div>
</div></header>
<main>
  <h1 class="sr">${esc(shots)}</h1>
  ${figures}
</main>
<footer><a href="${LANDING}">Зроблено в ScreenVoicer</a> · знімок екрана з голосовим коментарем, для Windows і Mac</footer>
<dialog id="lb" aria-label="Знімок на весь екран">
  <div class="lb-top"><span id="lbCount"></span><button type="button" class="lb-x" data-close aria-label="Закрити">${ICON.close}</button></div>
  <div class="lb-view" id="lbView"><img id="lbImg" alt=""></div>
  <div class="lb-bottom">
    <button type="button" class="lb-nav" data-step="-1" aria-label="Попередній">${ICON.left}</button>
    <p id="lbCap"></p>
    <button type="button" class="lb-nav" data-step="1" aria-label="Наступний">${ICON.right}</button>
  </div>
</dialog>
<div class="toast" id="toast" role="status" aria-live="polite"></div>
<script>const SHARE = ${safeJson(data)};</script>
<script>${CLIENT}</script>`;
  return page(200, tabTitle, body, head);
}

function toMarkdown(items, link, expiresText) {
  const count = items.length;
  const lines = [`# ${count === 1 ? 'Знімок екрана з коментарем' : `${count} ${plural(count, 'знімок', 'знімки', 'знімків')} екрана з коментарями`}`, '',
    `Посилання: ${link} (діє до ${expiresText}).`, ''];
  items.forEach((item, n) => {
    if (count > 1) lines.push(`## ${n + 1}`, '');
    lines.push(`![Знімок ${n + 1}](${item.src})`, '');
    lines.push(item.comment ? `**Коментар:** ${item.comment}` : '_Без коментаря._', '');
  });
  return lines.join('\n');
}

function expiredBody() {
  return `<div class="empty">${LOGO}<h1>Посилання більше не діє</h1><p>Посилання ScreenVoicer живуть 30 днів. Автор міг видалити його раніше.</p><a class="primary" href="${LANDING}"><span>Що таке ScreenVoicer</span></a></div>`;
}

function notFoundBody() {
  return `<div class="empty">${LOGO}<h1>Тут нічого немає</h1><p>Перевірте, чи посилання скопійоване повністю.</p><a class="primary" href="${LANDING}"><span>На сайт ScreenVoicer</span></a></div>`;
}

// The logo «Без плитки»: solid orange viewfinder corners and three bars (branding/logo.svg).
const LOGO = `<svg class="logo" viewBox="0 0 64 64" aria-hidden="true"><g fill="none" stroke="#ff8a4c" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"><path d="M6 22v-8a8 8 0 0 1 8-8h8M42 6h8a8 8 0 0 1 8 8v8M58 42v8a8 8 0 0 1-8 8h-8M22 58h-8a8 8 0 0 1-8-8v-8"/><path d="M22 28v8M32 20v24M42 28v8"/></g></svg>`;

// The apps' 24-unit line icons (App.xaml Icon.*), same path data.
const icon = d => `<svg class="i" viewBox="0 0 24 24" aria-hidden="true"><path d="${d}"/></svg>`;
const ICON = {
  copy: icon('M10 8.5H18A1.5 1.5 0 0 1 19.5 10V18A1.5 1.5 0 0 1 18 19.5H10A1.5 1.5 0 0 1 8.5 18V10A1.5 1.5 0 0 1 10 8.5ZM15.5 8.5V6A1.5 1.5 0 0 0 14 4.5H6A1.5 1.5 0 0 0 4.5 6V14A1.5 1.5 0 0 0 6 15.5H8.5'),
  download: icon('M12 4.5V15M7.5 10.5L12 15L16.5 10.5M5 19.5H19'),
  link: icon('M10 14A4 4 0 0 0 15.66 14L18.66 11A4 4 0 0 0 13 5.34L11.5 6.84M14 10A4 4 0 0 0 8.34 10L5.34 13A4 4 0 0 0 11 18.66L12.5 17.16'),
  spark: icon('M12 4V7M12 17V20M4 12H7M17 12H20M6.3 6.3L8.4 8.4M15.6 15.6L17.7 17.7M6.3 17.7L8.4 15.6M15.6 8.4L17.7 6.3'),
  close: icon('M6.5 6.5L17.5 17.5M17.5 6.5L6.5 17.5'),
  left: icon('M14.5 6.5L9 12L14.5 17.5'),
  right: icon('M9.5 6.5L15 12L9.5 17.5')
};

// Runs in the viewer's browser. Plain concatenation only: this is a template literal, so no dollar-brace here.
const CLIENT = String.raw`
(() => {
  const $ = id => document.getElementById(id);
  const toastEl = $('toast');
  let toastTimer;
  function toast(text) {
    toastEl.textContent = text;
    toastEl.classList.add('on');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove('on'), 2600);
  }

  async function writeText(text) {
    try { await navigator.clipboard.writeText(text); return true; }
    catch {
      const area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed'; area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      let ok = false;
      try { ok = document.execCommand('copy'); } catch {}
      area.remove();
      return ok;
    }
  }

  $('copyLink').addEventListener('click', async () => {
    toast(await writeText(SHARE.link) ? 'Посилання скопійовано' : 'Не вдалося скопіювати. Скопіюйте адресу з рядка браузера');
  });
  $('copyAi').addEventListener('click', async () => {
    toast(await writeText(SHARE.markdown) ? 'Скопійовано для AI: посилання на знімки й коментарі' : 'Не вдалося скопіювати');
  });

  // ── PNG: the comment goes into the file itself (iTXt «Description» + XMP dc:description), like the apps do ──
  const CRC = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; CRC[n] = c >>> 0; }
  function crc32(parts) {
    let c = 0xFFFFFFFF;
    for (const bytes of parts) for (let i = 0; i < bytes.length; i++) c = CRC[(c ^ bytes[i]) & 255] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  }
  const utf8 = s => new TextEncoder().encode(s);
  const xmlEsc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  function chunk(type, data) {
    const out = new Uint8Array(12 + data.length);
    const view = new DataView(out.buffer);
    view.setUint32(0, data.length);
    out.set(utf8(type), 4);
    out.set(data, 8);
    view.setUint32(8 + data.length, crc32([utf8(type), data]));
    return out;
  }
  function iTXt(keyword, text) {
    const k = utf8(keyword), t = utf8(text);
    const data = new Uint8Array(k.length + 5 + t.length); // keyword, 0, flag 0, method 0, language "" 0, translated "" 0, text
    data.set(k, 0);
    data.set(t, k.length + 5);
    return chunk('iTXt', data);
  }
  function xmp(comment) {
    return '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:description><rdf:Alt><rdf:li xml:lang="x-default">' + xmlEsc(comment) + '</rdf:li></rdf:Alt></dc:description></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="r"?>';
  }
  function withComment(png, comment) {
    const sig = [137, 80, 78, 71, 13, 10, 26, 10];
    if (!comment || png.length < 33 || sig.some((b, i) => png[i] !== b)) return png;
    const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
    const parts = [png.subarray(0, 8)];
    let pos = 8;
    while (pos + 12 <= png.length) {
      const length = view.getUint32(pos);
      const end = pos + 12 + length;
      if (end > png.length) return png;
      const type = String.fromCharCode(...png.subarray(pos + 4, pos + 8));
      let keep = true;
      if (type === 'iTXt' || type === 'tEXt' || type === 'zTXt') {
        const data = png.subarray(pos + 8, pos + 8 + length);
        const zero = data.indexOf(0);
        const keyword = String.fromCharCode(...data.subarray(0, zero < 0 ? Math.min(data.length, 80) : zero));
        keep = keyword !== 'Description' && keyword !== 'XML:com.adobe.xmp';
      }
      if (keep) parts.push(png.subarray(pos, end));
      if (type === 'IHDR') parts.push(iTXt('Description', comment), iTXt('XML:com.adobe.xmp', xmp(comment)));
      pos = end;
    }
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let at = 0;
    for (const p of parts) { out.set(p, at); at += p.length; }
    return out;
  }

  async function fileBytes(n) {
    const item = SHARE.items[n];
    const bytes = new Uint8Array(await (await fetch(item.src)).arrayBuffer());
    return item.ext === 'png' ? withComment(bytes, item.comment) : bytes;
  }
  const fileName = n => 'ScreenVoicer-' + SHARE.id + (SHARE.items.length > 1 ? '-' + (n + 1) : '') + '.' + SHARE.items[n].ext;
  function save(blob, name) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = name;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 4000);
  }

  async function download(n) {
    try {
      save(new Blob([await fileBytes(n)], { type: SHARE.items[n].ext === 'png' ? 'image/png' : 'image/jpeg' }), fileName(n));
      toast('Завантажено');
    } catch { toast('Не вдалося завантажити. Перевірте інтернет'); }
  }

  async function toPng(blob) {
    const bitmap = await createImageBitmap(blob);
    const canvas = document.createElement('canvas');
    canvas.width = bitmap.width; canvas.height = bitmap.height;
    canvas.getContext('2d').drawImage(bitmap, 0, 0);
    return new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
  }

  // The image and the comment in one go: editors (Docs, Gmail, Notion, Jira) take both, chats take the image.
  async function copyShot(n) {
    const item = SHARE.items[n];
    try {
      if (!window.ClipboardItem || !navigator.clipboard || !navigator.clipboard.write) throw new Error('no clipboard');
      const image = fetch(item.src).then(r => r.blob()).then(b => b.type === 'image/png' ? b : toPng(b));
      const data = { 'image/png': image };
      if (item.comment) {
        const html = '<img src="' + item.src + '" alt=""><p>' + xmlEsc(item.comment).replace(/\n/g, '<br>') + '</p>';
        data['text/plain'] = new Blob([item.comment], { type: 'text/plain' });
        data['text/html'] = new Blob([html], { type: 'text/html' });
      }
      await navigator.clipboard.write([new ClipboardItem(data)]);
      toast(item.comment ? 'Скопійовано знімок і коментар' : 'Знімок скопійовано');
    } catch {
      if (item.comment && await writeText(item.comment)) toast('Браузер не дав скопіювати картинку, тож скопійовано коментар');
      else toast('Браузер не дав скопіювати картинку. Натисніть «Завантажити»');
    }
  }

  // ── ZIP of all screenshots (stored: PNG is compressed already) + comments.md ──
  function zip(files) {
    const now = new Date();
    const time = (now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1);
    const date = ((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate();
    const chunks = [], central = [];
    let offset = 0;
    for (const f of files) {
      const name = utf8(f.name), crc = crc32([f.data]), size = f.data.length;
      const local = new DataView(new ArrayBuffer(30));
      local.setUint32(0, 0x04034b50, true); local.setUint16(4, 20, true); local.setUint16(6, 0x0800, true);
      local.setUint16(10, time, true); local.setUint16(12, date, true); local.setUint32(14, crc, true);
      local.setUint32(18, size, true); local.setUint32(22, size, true); local.setUint16(26, name.length, true);
      chunks.push(new Uint8Array(local.buffer), name, f.data);
      const entry = new DataView(new ArrayBuffer(46));
      entry.setUint32(0, 0x02014b50, true); entry.setUint16(4, 20, true); entry.setUint16(6, 20, true); entry.setUint16(8, 0x0800, true);
      entry.setUint16(12, time, true); entry.setUint16(14, date, true); entry.setUint32(16, crc, true);
      entry.setUint32(20, size, true); entry.setUint32(24, size, true); entry.setUint16(28, name.length, true);
      entry.setUint32(42, offset, true);
      central.push(new Uint8Array(entry.buffer), name);
      offset += 30 + name.length + size;
    }
    const centralSize = central.reduce((n, c) => n + c.length, 0);
    const end = new DataView(new ArrayBuffer(22));
    end.setUint32(0, 0x06054b50, true); end.setUint16(8, files.length, true); end.setUint16(10, files.length, true);
    end.setUint32(12, centralSize, true); end.setUint32(16, offset, true);
    return new Blob([...chunks, ...central, new Uint8Array(end.buffer)], { type: 'application/zip' });
  }

  const zipButton = $('zip');
  if (zipButton) zipButton.addEventListener('click', async () => {
    zipButton.disabled = true;
    toast('Збираю архів…');
    try {
      const files = [];
      for (let n = 0; n < SHARE.items.length; n++) files.push({ name: fileName(n), data: await fileBytes(n) });
      files.push({ name: 'comments.md', data: utf8(SHARE.markdown) });
      save(zip(files), 'ScreenVoicer-' + SHARE.id + '.zip');
      toast('Архів завантажено');
    } catch { toast('Не вдалося зібрати архів. Перевірте інтернет'); }
    zipButton.disabled = false;
  });

  document.addEventListener('click', e => {
    const copy = e.target.closest('[data-copy]');
    if (copy) return copyShot(Number(copy.dataset.copy));
    const dl = e.target.closest('[data-download]');
    if (dl) return download(Number(dl.dataset.download));
    const zoom = e.target.closest('[data-zoom]');
    if (zoom) return openLightbox(Number(zoom.dataset.zoom));
  });

  // ── Full screen view: fit to the screen, a click shows real pixels, arrows go between screenshots ──
  const lb = $('lb'), lbImg = $('lbImg'), lbView = $('lbView');
  let current = 0;
  function show(n) {
    current = (n + SHARE.items.length) % SHARE.items.length;
    const item = SHARE.items[current];
    lbView.classList.remove('actual');
    lbImg.src = item.src;
    lbImg.alt = item.comment || 'Знімок ' + (current + 1);
    $('lbCap').textContent = item.comment;
    $('lbCount').textContent = SHARE.items.length > 1 ? (current + 1) + ' з ' + SHARE.items.length : '';
  }
  function openLightbox(n) {
    lb.classList.toggle('single', SHARE.items.length === 1);
    show(n);
    lb.showModal();
  }
  lbImg.addEventListener('click', e => { e.stopPropagation(); lbView.classList.toggle('actual'); });
  lbView.addEventListener('click', () => lb.close());
  lb.addEventListener('click', e => {
    if (e.target.closest('[data-close]')) lb.close();
    const step = e.target.closest('[data-step]');
    if (step) show(current + Number(step.dataset.step));
  });
  lb.addEventListener('keydown', e => {
    if (e.key === 'ArrowRight') show(current + 1);
    if (e.key === 'ArrowLeft') show(current - 1);
  });
})();
`;

function page(status, title, body, head = '') {
  const html = `<!doctype html>
<html lang="uk">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0F0F13">
<title>${esc(title)} · ScreenVoicer</title>
${head}
<link rel="icon" href="data:image/svg+xml,${encodeURIComponent(LOGO.replace('class="logo" ', 'xmlns="http://www.w3.org/2000/svg" '))}">
<style>
:root {
  --bg: #0F0F13; --surface: #17171D; --glass: rgba(255,255,255,.06); --glass-hover: rgba(255,255,255,.11);
  --edge: rgba(255,255,255,.18); --line: rgba(255,255,255,.08); --text: #F4F4F7; --soft: #CFCFD6; --muted: #AAAAB6;
  --accent: #FF8A4C; --ink: #1D1D22; --primary: rgba(255,255,255,.92);
  color-scheme: dark;
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body { margin: 0; background: var(--bg); color: var(--text); min-height: 100vh;
  font: 16px/1.55 "Segoe UI Variable Text", "Segoe UI", -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased; }
a { color: inherit; }
button { font: inherit; color: inherit; }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.i { width: 17px; height: 17px; flex: none; fill: none; stroke: currentColor; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }

.sr { position: absolute; width: 1px; height: 1px; margin: -1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }

/* One thin bar holds everything about the link; the page below is the screenshots. */
.bar { position: sticky; top: 0; z-index: 5;
  padding: max(9px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) 9px max(16px, env(safe-area-inset-left));
  background: rgba(15,15,19,.8); -webkit-backdrop-filter: blur(18px); backdrop-filter: blur(18px); }
.bar-in { max-width: 1280px; margin: 0 auto; display: flex; align-items: center; gap: 14px; }
.brand { display: flex; align-items: center; gap: 9px; flex: none; text-decoration: none; font-weight: 600; font-size: 15px; letter-spacing: -.01em; }
.logo { width: 26px; height: 26px; flex: none; }
.meta { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); font-size: 14px;
  padding-left: 4px; }
.tools { display: flex; gap: 8px; flex: none; }
.primary { display: inline-flex; align-items: center; justify-content: center; gap: 8px; height: 34px; padding: 0 14px; border: 0; border-radius: 10px; cursor: pointer;
  background: var(--primary); color: var(--ink); font-weight: 600; font-size: 14px; text-decoration: none; white-space: nowrap; }
.primary .i { color: var(--accent); stroke-width: 2.2; }
.primary:hover { background: #fff; }
.chip { display: inline-flex; align-items: center; justify-content: center; gap: 6px; height: 30px; padding: 0 10px; border: 0; border-radius: 9px; cursor: pointer;
  background: var(--glass); color: var(--soft); font-weight: 600; font-size: 13px; white-space: nowrap; }
.chip .i { width: 15px; height: 15px; }
.chip:hover { background: var(--glass-hover); color: var(--text); }
.chip:disabled { opacity: .55; cursor: progress; }

main { max-width: 1312px; margin: 0 auto; padding: 0 16px; }
.shot { width: fit-content; min-width: min(100%, 560px); max-width: 100%; margin: 40px 0 0; scroll-margin-top: 64px; }
.shot:first-of-type { margin-top: 20px; }
.frame { display: block; width: fit-content; max-width: 100%; padding: 0; border: 0; border-radius: 12px; overflow: hidden; background: var(--surface); cursor: zoom-in; }
.frame img { display: block; max-width: 100%; height: auto; }
.cap { display: flex; align-items: flex-start; gap: 14px; margin: 14px 0 0; }
.marker { display: grid; place-items: center; width: 30px; height: 30px; flex: none; border-radius: 50%; background: var(--accent); color: #fff;
  font-weight: 700; font-size: 15px; box-shadow: 0 0 0 2px #fff, 0 2px 8px rgba(0,0,0,.4); margin: 2px 2px 0; }
.comment { flex: 1; min-width: 0; margin: 0; font-size: clamp(17px, 2vw, 20px); line-height: 1.5; font-weight: 500; letter-spacing: -.005em; white-space: pre-wrap; overflow-wrap: anywhere; max-width: 64ch; }
.cap:not(.step) .comment { padding-left: 14px; border-left: 3px solid var(--accent); }
.cap.step .comment { padding-top: 2px; }
.comment.none { color: var(--muted); font-weight: 400; font-size: 15px; border-left-color: rgba(255,255,255,.14) !important; }
.acts { display: flex; gap: 6px; flex: none; margin-left: auto; }
.ib { display: grid; place-items: center; width: 36px; height: 36px; padding: 0; border-radius: 10px; cursor: pointer;
  background: var(--glass); border: 0; color: var(--soft); }
.ib:hover { background: var(--glass-hover); color: var(--text); }

footer { max-width: 1312px; margin: 48px auto 0; padding: 18px 16px max(28px, env(safe-area-inset-bottom)); color: var(--muted); font-size: 13.5px; }
footer a { color: var(--soft); }

.toast { position: fixed; left: 50%; bottom: max(22px, env(safe-area-inset-bottom)); transform: translate(-50%, 16px); opacity: 0; pointer-events: none; z-index: 20;
  width: max-content; max-width: calc(100vw - 32px); padding: 11px 16px; border-radius: 12px; background: rgba(28,28,35,.96); border: 0;
  color: var(--text); font-size: 14.5px; font-weight: 500; box-shadow: 0 12px 40px rgba(0,0,0,.5); transition: opacity .18s, transform .18s; }
.toast.on { opacity: 1; transform: translate(-50%, 0); }

dialog { width: 100vw; height: 100vh; height: 100dvh; max-width: none; max-height: none; margin: 0; padding: 0; border: 0; background: #08080A; color: var(--text); }
dialog[open] { display: grid; grid-template-rows: auto minmax(0, 1fr) auto; }
dialog::backdrop { background: transparent; }
html:has(dialog[open]) { overflow: hidden; }
.lb-top, .lb-bottom { display: flex; align-items: center; gap: 12px; padding: 10px 14px; }
.lb-top { justify-content: space-between; padding-top: max(10px, env(safe-area-inset-top)); color: var(--muted); font-size: 14px; }
.lb-bottom { padding-bottom: max(12px, env(safe-area-inset-bottom)); }
.lb-bottom p { flex: 1; margin: 0; text-align: center; font-size: 16px; line-height: 1.45; max-height: 4.4em; overflow: auto; white-space: pre-wrap; }
.lb-x, .lb-nav { display: grid; place-items: center; width: 40px; height: 40px; flex: none; border-radius: 12px; border: 0; background: var(--glass); cursor: pointer; }
.lb-x:hover, .lb-nav:hover { background: var(--glass-hover); }
dialog.single .lb-nav { visibility: hidden; }
.lb-view { position: relative; min-height: 0; overflow: auto; cursor: zoom-out; }
.lb-view img { position: absolute; inset: 0; margin: auto; max-width: calc(100% - 24px); max-height: 100%; cursor: zoom-in; border-radius: 6px; }
.lb-view.actual img { position: static; max-width: none; max-height: none; margin: 0 12px; border-radius: 0; cursor: zoom-out; }

.empty { min-height: 88vh; display: grid; place-content: center; justify-items: center; text-align: center; gap: 12px; padding: 24px 16px; }
.empty .logo { width: 64px; height: 64px; margin-bottom: 8px; }
.empty h1 { margin: 0; font-size: 28px; line-height: 1.15; font-weight: 650; letter-spacing: -.025em; }
.empty p { color: var(--muted); max-width: 42ch; margin: 0 0 10px; }

@media (max-width: 920px) {
  .bar .chip span { display: none; }
  .bar .chip { width: 30px; padding: 0; }
}
@media (max-width: 600px) {
  .bar-in { gap: 10px; }
  .brand span { display: none; }
  .meta { padding-left: 10px; font-size: 13px; }
  .tools { gap: 6px; }
  main { padding: 0 10px; }
  .shot { margin-top: 32px; }
  .shot:first-of-type { margin-top: 10px; }
  .frame { border-radius: 9px; }
  .cap { gap: 10px; margin-top: 12px; }
  .comment { font-size: 17px; }
  .cap:not(.step) .comment { padding-left: 11px; }
  .ib { width: 34px; height: 34px; }
  .lb-nav { width: 36px; height: 36px; }
}
@media (prefers-reduced-motion: reduce) { .toast { transition: none; } }
</style>
</head>
<body>${body}</body>
</html>`;
  return new Response(html, {
    status,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': status === 200 ? 'public, max-age=300' : 'no-store',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      'content-security-policy': "default-src 'none'; img-src 'self' data: blob:; connect-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
    }
  });
}

// ───────────────────────────── helpers ─────────────────────────────

function sniff(bytes) {
  if (bytes.length > 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return { ext: 'png', type: 'image/png' };
  if (bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return { ext: 'jpg', type: 'image/jpeg' };
  return null;
}

function randomString(length) {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  let s = '';
  for (const b of bytes) s += ALPHABET[b % ALPHABET.length];
  return s;
}

async function sha256(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
}

function clampInt(value, min, max) {
  const n = Math.round(Number(value));
  return Number.isFinite(n) && n >= min && n <= max ? n : null;
}

function plural(n, one, few, many) {
  const d = n % 10, h = n % 100;
  if (d === 1 && h !== 11) return one;
  if (d >= 2 && d <= 4 && (h < 12 || h > 14)) return few;
  return many;
}

/** «2 750 ₴» stays on one line. */
function keepNumbers(html) {
  return html.replace(/(\d) (?=\d{3}\b|₴|\$|€|грн|%)/g, '$1&nbsp;');
}

function oneLine(text) {
  return String(text).replace(/\s+/g, ' ').trim();
}

/** Cuts at a word boundary when one is close enough. */
function truncate(text, max) {
  if (text.length <= max) return text;
  const cut = text.slice(0, max - 1);
  const space = cut.lastIndexOf(' ');
  return (space > max * 0.6 ? cut.slice(0, space) : cut).replace(/[\s,.;:–—-]+$/, '') + '…';
}

function esc(text) {
  return String(text).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/** JSON that is safe inside a <script> element. */
function safeJson(data) {
  const backslash = String.fromCharCode(92);
  return JSON.stringify(data).replace(/</g, backslash + 'u003c').replace(LINE_SEPARATORS, c => backslash + 'u' + c.charCodeAt(0).toString(16));
}
const LINE_SEPARATORS = new RegExp('[' + String.fromCharCode(0x2028, 0x2029) + ']', 'g'); // old browsers end a string at these

function json(data, status = 200, open = false) {
  return new Response(JSON.stringify(data, null, open ? 2 : 0), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      ...(open ? { 'access-control-allow-origin': '*' } : {})
    }
  });
}
