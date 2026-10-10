var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/index.js
var TTL_DAYS = 30;
var MAX_IMAGES = 10;
var MAX_IMAGE_BYTES = 8 * 1024 * 1024;
var MAX_COMMENT = 4e3;
var ID_LENGTH = 10;
var ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
var LANDING = "https://arthurmospan.github.io/ScreenVoicer/";
var src_default = {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
      let m;
      if (request.method === "POST" && path === "/api/shares") return await createShare(request, env, url);
      if (request.method === "DELETE" && (m = path.match(/^\/api\/shares\/([A-Za-z0-9]{10})$/))) return await deleteShare(request, env, m[1]);
      if (request.method === "GET" && (m = path.match(/^\/i\/([A-Za-z0-9]{10})\/(\d{1,2})\.(png|jpg)$/))) return await getImage(env, m[1], Number(m[2]));
      if (request.method === "GET" && (m = path.match(/^\/s\/([A-Za-z0-9]{10})$/))) return await sharePage(env, url, m[1]);
      if (request.method === "GET" && path === "/api/health") return json({ ok: true, ttlDays: TTL_DAYS, maxImages: MAX_IMAGES });
      if (request.method === "GET" && path === "/") return Response.redirect(LANDING, 302);
      return page(404, "\u0421\u0442\u043E\u0440\u0456\u043D\u043A\u0443 \u043D\u0435 \u0437\u043D\u0430\u0439\u0434\u0435\u043D\u043E", notFoundBody());
    } catch (error) {
      console.error(error);
      return json({ error: "server_error" }, 500);
    }
  }
};
async function createShare(request, env, url) {
  const type = request.headers.get("content-type") || "";
  if (!type.startsWith("multipart/form-data")) return json({ error: "expected_multipart" }, 415);
  const form = await request.formData();
  let meta;
  try {
    meta = JSON.parse(form.get("meta") || "{}");
  } catch {
    return json({ error: "bad_meta" }, 400);
  }
  const files = form.getAll("image");
  if (files.length < 1 || files.length > MAX_IMAGES) return json({ error: "image_count", max: MAX_IMAGES }, 400);
  const items = [];
  const images = [];
  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    if (typeof file === "string" || file.size > MAX_IMAGE_BYTES) return json({ error: "image_too_large", maxBytes: MAX_IMAGE_BYTES }, 413);
    const bytes = new Uint8Array(await file.arrayBuffer());
    const kind = sniff(bytes);
    if (!kind) return json({ error: "not_an_image" }, 415);
    const info = meta.items && meta.items[i] || {};
    items.push({
      ext: kind.ext,
      type: kind.type,
      comment: String(info.comment || "").slice(0, MAX_COMMENT),
      width: clampInt(info.width, 1, 2e4),
      height: clampInt(info.height, 1, 2e4),
      createdAt: typeof info.createdAt === "string" ? info.createdAt.slice(0, 40) : null
    });
    images.push({ bytes, type: kind.type });
  }
  const id = randomString(ID_LENGTH);
  const deleteToken = randomString(28);
  const ttl = TTL_DAYS * 86400;
  const expiresAt = new Date(Date.now() + ttl * 1e3).toISOString();
  await Promise.all(images.map((image, n) => env.SHARES.put(`img:${id}:${n}`, image.bytes, { expirationTtl: ttl, metadata: { type: image.type } })));
  await env.SHARES.put(`share:${id}`, JSON.stringify({
    id,
    createdAt: (/* @__PURE__ */ new Date()).toISOString(),
    expiresAt,
    deleteHash: await sha256(deleteToken),
    title: String(meta.title || "").slice(0, 200),
    app: String(meta.app || "").slice(0, 40),
    items
  }), { expirationTtl: ttl });
  return json({ id, url: `${url.origin}/s/${id}`, deleteToken, expiresAt }, 201);
}
__name(createShare, "createShare");
async function deleteShare(request, env, id) {
  const share = await env.SHARES.get(`share:${id}`, { type: "json" });
  if (!share) return json({ ok: true, alreadyGone: true });
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token || await sha256(token) !== share.deleteHash) return json({ error: "forbidden" }, 403);
  await Promise.all([
    env.SHARES.delete(`share:${id}`),
    ...share.items.map((_, n) => env.SHARES.delete(`img:${id}:${n}`))
  ]);
  return json({ ok: true });
}
__name(deleteShare, "deleteShare");
async function getImage(env, id, n) {
  const { value, metadata } = await env.SHARES.getWithMetadata(`img:${id}:${n}`, { type: "arrayBuffer", cacheTtl: 3600 });
  if (!value) return new Response("Not found", { status: 404 });
  return new Response(value, {
    headers: {
      "content-type": metadata && metadata.type || "image/png",
      "cache-control": "public, max-age=86400, immutable",
      "x-content-type-options": "nosniff"
    }
  });
}
__name(getImage, "getImage");
async function sharePage(env, url, id) {
  const share = await env.SHARES.get(`share:${id}`, { type: "json", cacheTtl: 300 });
  if (!share) return page(404, "\u041F\u043E\u0441\u0438\u043B\u0430\u043D\u043D\u044F \u0431\u0456\u043B\u044C\u0448\u0435 \u043D\u0435 \u0434\u0456\u0454", expiredBody());
  const count = share.items.length;
  const first = share.items[0];
  const firstComment = share.items.map((i) => i.comment).find((c) => c) || "";
  const title = share.title || (count > 1 ? `${count} \u0441\u043A\u0440\u0438\u043D\u0448\u043E\u0442\u0438 \u0437 \u043A\u043E\u043C\u0435\u043D\u0442\u0430\u0440\u044F\u043C\u0438` : "\u0421\u043A\u0440\u0438\u043D\u0448\u043E\u0442 \u0456\u0437 \u043A\u043E\u043C\u0435\u043D\u0442\u0430\u0440\u0435\u043C");
  const imageUrl = /* @__PURE__ */ __name((n) => `${url.origin}/i/${id}/${n}.${share.items[n].ext}`, "imageUrl");
  const og = `
<meta property="og:type" content="article">
<meta property="og:site_name" content="ScreenVoicer">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(truncate(firstComment || "\u0412\u0456\u0434\u043A\u0440\u0438\u0439\u0442\u0435, \u0449\u043E\u0431 \u043F\u043E\u0434\u0438\u0432\u0438\u0442\u0438\u0441\u044F", 200))}">
<meta property="og:image" content="${imageUrl(0)}">
${first.width ? `<meta property="og:image:width" content="${first.width}"><meta property="og:image:height" content="${first.height}">` : ""}
<meta name="twitter:card" content="summary_large_image">
<meta name="robots" content="noindex">`;
  const items = share.items.map((item, n) => `
  <figure class="shot">
    ${count > 1 ? `<div class="num">${n + 1}<span>/${count}</span></div>` : ""}
    <a class="img" href="${imageUrl(n)}" target="_blank" rel="noopener">
      <img src="${imageUrl(n)}" ${item.width ? `width="${item.width}" height="${item.height}"` : ""} alt="\u0421\u043A\u0440\u0438\u043D\u0448\u043E\u0442 ${n + 1}" loading="${n === 0 ? "eager" : "lazy"}">
    </a>
    ${item.comment ? `<figcaption><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3.5a3 3 0 0 1 3 3V12a3 3 0 0 1-6 0V6.5a3 3 0 0 1 3-3zM5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v2.5"/></svg><p>${esc(item.comment)}</p></figcaption>` : ""}
  </figure>`).join("");
  const expires = new Date(share.expiresAt).toLocaleDateString("uk-UA", { day: "numeric", month: "long", year: "numeric" });
  const body = `
<header class="top">
  <a class="brand" href="${LANDING}">${LOGO}<span>Screen<b>Voicer</b></span></a>
  <button class="copy" id="copy" type="button">\u041A\u043E\u043F\u0456\u044E\u0432\u0430\u0442\u0438 \u043F\u043E\u0441\u0438\u043B\u0430\u043D\u043D\u044F</button>
</header>
<main>
  <h1>${esc(title)}</h1>
  ${items}
</main>
<footer>\u041F\u043E\u0441\u0438\u043B\u0430\u043D\u043D\u044F \u0434\u0456\u0454 \u0434\u043E ${esc(expires)} \xB7 <a href="${LANDING}">\u0417\u0440\u043E\u0431\u043B\u0435\u043D\u043E \u0432 ScreenVoicer</a> \u2014 \u0441\u043A\u0440\u0438\u043D\u0448\u043E\u0442 \u0456\u0437 \u0433\u043E\u043B\u043E\u0441\u043E\u0432\u0438\u043C \u043A\u043E\u043C\u0435\u043D\u0442\u0430\u0440\u0435\u043C \u0437\u0430 10 \u0441\u0435\u043A\u0443\u043D\u0434</footer>
<script>
  document.getElementById('copy').addEventListener('click', async e => {
    try { await navigator.clipboard.writeText(location.href); e.target.textContent = '\u0421\u043A\u043E\u043F\u0456\u0439\u043E\u0432\u0430\u043D\u043E'; }
    catch { prompt('\u0421\u043A\u043E\u043F\u0456\u044E\u0439\u0442\u0435 \u043F\u043E\u0441\u0438\u043B\u0430\u043D\u043D\u044F:', location.href); }
  });
<\/script>`;
  return page(200, title, body, og);
}
__name(sharePage, "sharePage");
function expiredBody() {
  return `<div class="empty">${LOGO}<h1>\u041F\u043E\u0441\u0438\u043B\u0430\u043D\u043D\u044F \u0431\u0456\u043B\u044C\u0448\u0435 \u043D\u0435 \u0434\u0456\u0454</h1><p>\u041F\u043E\u0441\u0438\u043B\u0430\u043D\u043D\u044F ScreenVoicer \u0436\u0438\u0432\u0443\u0442\u044C 30 \u0434\u043D\u0456\u0432 \u0430\u0431\u043E \u0434\u043E\u043A\u0438 \u0430\u0432\u0442\u043E\u0440 \u0457\u0445 \u043D\u0435 \u0432\u0438\u0434\u0430\u043B\u0438\u0442\u044C.</p><a class="btn" href="${LANDING}">\u0429\u043E \u0442\u0430\u043A\u0435 ScreenVoicer</a></div>`;
}
__name(expiredBody, "expiredBody");
function notFoundBody() {
  return `<div class="empty">${LOGO}<h1>\u0422\u0443\u0442 \u043D\u0456\u0447\u043E\u0433\u043E \u043D\u0435\u043C\u0430\u0454</h1><a class="btn" href="${LANDING}">\u041D\u0430 \u0441\u0430\u0439\u0442 ScreenVoicer</a></div>`;
}
__name(notFoundBody, "notFoundBody");
var LOGO = `<svg class="logo" viewBox="0 0 64 64" aria-hidden="true"><defs><linearGradient id="t" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffa468"/><stop offset="1" stop-color="#f06a2c"/></linearGradient></defs><rect x="2" y="2" width="60" height="60" rx="16" fill="url(#t)"/><path d="M13 25v-6a6 6 0 0 1 6-6h6M39 13h6a6 6 0 0 1 6 6v6M51 39v6a6 6 0 0 1-6 6h-6M25 51h-6a6 6 0 0 1-6-6v-6" fill="none" stroke="#2a1608" stroke-width="5.5" stroke-linecap="round"/><rect x="24" y="19" width="16" height="26" rx="8" fill="#fff8f2"/></svg>`;
function page(status, title, body, head = "") {
  const html = `<!doctype html>
<html lang="uk">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} \xB7 ScreenVoicer</title>
${head}
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Onest:wght@400;500;600&display=swap">
<style>
:root { --ink:#0e0d10; --fg:#f4f2f0; --muted:#a39f9b; --line:rgba(255,255,255,.09); --accent:#ff8a4c; --accent2:#ffc68a; color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--ink) radial-gradient(60% 40% at 80% 0%, rgba(255,138,76,.14), transparent 70%) no-repeat; color: var(--fg);
  font: 16px/1.6 "Onest", "Segoe UI", -apple-system, system-ui, sans-serif; padding: 0 18px 40px; min-height: 100vh; }
a { color: inherit; }
.top { max-width: 1100px; margin: 0 auto; display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 18px 0; }
.brand { display: flex; align-items: center; gap: 10px; text-decoration: none; font-weight: 600; font-size: 17px; letter-spacing: -.01em; }
.brand b { color: var(--accent); font-weight: 600; }
.logo { width: 34px; height: 34px; flex: none; }
.copy, .btn { font-family: inherit; font-weight: 600; font-size: 14px; line-height: 1; color: var(--fg); border: 0; cursor: pointer; padding: 11px 16px; border-radius: 12px; text-decoration: none;
  background: linear-gradient(180deg, rgba(255,255,255,.13), rgba(255,255,255,.04)); box-shadow: inset 0 1px 0 rgba(255,255,255,.28), inset 0 0 0 1px rgba(255,255,255,.1); }
.copy:hover, .btn:hover { background: linear-gradient(180deg, rgba(255,255,255,.18), rgba(255,255,255,.06)); }
main { max-width: 1100px; margin: 0 auto; display: grid; gap: 28px; }
h1 { font-size: clamp(22px, 3vw, 30px); line-height: 1.2; font-weight: 600; letter-spacing: -.02em; margin: 14px 0 0; text-wrap: balance; }
.shot { margin: 0; display: grid; gap: 14px; position: relative; }
.img { display: block; border-radius: 16px; overflow: hidden; border: 1px solid var(--line); background: #17161b; box-shadow: 0 30px 80px rgba(0,0,0,.45); }
.img img { display: block; width: 100%; height: auto; }
.num { position: absolute; top: 12px; left: 12px; z-index: 1; font-weight: 600; font-size: 15px; padding: 5px 11px; border-radius: 10px; color: #fff;
  background: linear-gradient(180deg, #ffa066, rgba(232,100,42,.85)); box-shadow: inset 0 1px 0 rgba(255,255,255,.5), 0 0 18px rgba(255,138,76,.4); }
.num span { opacity: .75; font-weight: 500; }
figcaption { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 12px; align-items: start; padding: 16px 18px; border-radius: 16px;
  background: linear-gradient(180deg, rgba(255,255,255,.06), rgba(255,255,255,.02)); box-shadow: inset 0 1px 0 rgba(255,255,255,.12), inset 0 0 0 1px var(--line); }
figcaption svg { width: 20px; height: 20px; margin-top: 3px; fill: none; stroke: var(--accent2); stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }
figcaption p { margin: 0; font-size: 17px; white-space: pre-wrap; overflow-wrap: anywhere; }
footer { max-width: 1100px; margin: 36px auto 0; color: var(--muted); font-size: 13.5px; border-top: 1px solid var(--line); padding-top: 18px; }
.empty { min-height: 80vh; display: grid; place-content: center; justify-items: center; text-align: center; gap: 14px; }
.empty .logo { width: 72px; height: 72px; }
.empty p { color: var(--muted); max-width: 46ch; margin: 0; }
</style>
</head>
<body>${body}</body>
</html>`;
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": status === 200 ? "public, max-age=300" : "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      "content-security-policy": "default-src 'none'; img-src 'self'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
    }
  });
}
__name(page, "page");
function sniff(bytes) {
  if (bytes.length > 8 && bytes[0] === 137 && bytes[1] === 80 && bytes[2] === 78 && bytes[3] === 71) return { ext: "png", type: "image/png" };
  if (bytes.length > 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return { ext: "jpg", type: "image/jpeg" };
  return null;
}
__name(sniff, "sniff");
function randomString(length) {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  let s = "";
  for (const b of bytes) s += ALPHABET[b % ALPHABET.length];
  return s;
}
__name(randomString, "randomString");
async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
__name(sha256, "sha256");
function clampInt(value, min, max) {
  const n = Math.round(Number(value));
  return Number.isFinite(n) && n >= min && n <= max ? n : null;
}
__name(clampInt, "clampInt");
function truncate(text, max) {
  return text.length > max ? text.slice(0, max - 1) + "\u2026" : text;
}
__name(truncate, "truncate");
function esc(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
__name(esc, "esc");
function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
  });
}
__name(json, "json");

// C:/Users/Arthu/AppData/Local/npm-cache/_npx/32026684e21afda6/node_modules/wrangler/templates/middleware/middleware-ensure-req-body-drained.ts
var drainBody = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } finally {
    try {
      if (request.body !== null && !request.bodyUsed) {
        const reader = request.body.getReader();
        while (!(await reader.read()).done) {
        }
      }
    } catch (e) {
      console.error("Failed to drain the unused request body.", e);
    }
  }
}, "drainBody");
var middleware_ensure_req_body_drained_default = drainBody;

// C:/Users/Arthu/AppData/Local/npm-cache/_npx/32026684e21afda6/node_modules/wrangler/templates/middleware/middleware-miniflare3-json-error.ts
function reduceError(e) {
  return {
    name: e?.name,
    message: e?.message ?? String(e),
    stack: e?.stack,
    cause: e?.cause === void 0 ? void 0 : reduceError(e.cause)
  };
}
__name(reduceError, "reduceError");
var jsonError = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } catch (e) {
    const error = reduceError(e);
    const body = JSON.stringify(error);
    const headers = {
      "Content-Type": "application/json",
      "MF-Experimental-Error-Stack": "true"
    };
    const encoded = encodeURIComponent(body);
    if (encoded.length <= 8192) {
      headers["MF-Experimental-Error-Stack-Payload"] = encoded;
    }
    return new Response(body, { status: 500, headers });
  }
}, "jsonError");
var middleware_miniflare3_json_error_default = jsonError;

// .wrangler/tmp/bundle-G25OcS/middleware-insertion-facade.js
var __INTERNAL_WRANGLER_MIDDLEWARE__ = [
  middleware_ensure_req_body_drained_default,
  middleware_miniflare3_json_error_default
];
var middleware_insertion_facade_default = src_default;

// C:/Users/Arthu/AppData/Local/npm-cache/_npx/32026684e21afda6/node_modules/wrangler/templates/middleware/common.ts
var __facade_middleware__ = [];
function __facade_register__(...args) {
  __facade_middleware__.push(...args.flat());
}
__name(__facade_register__, "__facade_register__");
function __facade_invokeChain__(request, env, ctx, dispatch, middlewareChain) {
  const [head, ...tail] = middlewareChain;
  const middlewareCtx = {
    dispatch,
    next(newRequest, newEnv) {
      return __facade_invokeChain__(newRequest, newEnv, ctx, dispatch, tail);
    }
  };
  return head(request, env, ctx, middlewareCtx);
}
__name(__facade_invokeChain__, "__facade_invokeChain__");
function __facade_invoke__(request, env, ctx, dispatch, finalMiddleware) {
  return __facade_invokeChain__(request, env, ctx, dispatch, [
    ...__facade_middleware__,
    finalMiddleware
  ]);
}
__name(__facade_invoke__, "__facade_invoke__");

// .wrangler/tmp/bundle-G25OcS/middleware-loader.entry.ts
var __Facade_ScheduledController__ = class ___Facade_ScheduledController__ {
  constructor(scheduledTime, cron, noRetry) {
    this.scheduledTime = scheduledTime;
    this.cron = cron;
    this.#noRetry = noRetry;
  }
  scheduledTime;
  cron;
  static {
    __name(this, "__Facade_ScheduledController__");
  }
  #noRetry;
  noRetry() {
    if (!(this instanceof ___Facade_ScheduledController__)) {
      throw new TypeError("Illegal invocation");
    }
    this.#noRetry();
  }
};
function wrapExportedHandler(worker) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return worker;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  const fetchDispatcher = /* @__PURE__ */ __name(function(request, env, ctx) {
    if (worker.fetch === void 0) {
      throw new Error("Handler does not export a fetch() function.");
    }
    return worker.fetch(request, env, ctx);
  }, "fetchDispatcher");
  return {
    ...worker,
    fetch(request, env, ctx) {
      const dispatcher = /* @__PURE__ */ __name(function(type, init) {
        if (type === "scheduled" && worker.scheduled !== void 0) {
          const controller = new __Facade_ScheduledController__(
            Date.now(),
            init.cron ?? "",
            () => {
            }
          );
          return worker.scheduled(controller, env, ctx);
        }
      }, "dispatcher");
      return __facade_invoke__(request, env, ctx, dispatcher, fetchDispatcher);
    }
  };
}
__name(wrapExportedHandler, "wrapExportedHandler");
function wrapWorkerEntrypoint(klass) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return klass;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  return class extends klass {
    #fetchDispatcher = /* @__PURE__ */ __name((request, env, ctx) => {
      this.env = env;
      this.ctx = ctx;
      if (super.fetch === void 0) {
        throw new Error("Entrypoint class does not define a fetch() function.");
      }
      return super.fetch(request);
    }, "#fetchDispatcher");
    #dispatcher = /* @__PURE__ */ __name((type, init) => {
      if (type === "scheduled" && super.scheduled !== void 0) {
        const controller = new __Facade_ScheduledController__(
          Date.now(),
          init.cron ?? "",
          () => {
          }
        );
        return super.scheduled(controller);
      }
    }, "#dispatcher");
    fetch(request) {
      return __facade_invoke__(
        request,
        this.env,
        this.ctx,
        this.#dispatcher,
        this.#fetchDispatcher
      );
    }
  };
}
__name(wrapWorkerEntrypoint, "wrapWorkerEntrypoint");
var WRAPPED_ENTRY;
if (typeof middleware_insertion_facade_default === "object") {
  WRAPPED_ENTRY = wrapExportedHandler(middleware_insertion_facade_default);
} else if (typeof middleware_insertion_facade_default === "function") {
  WRAPPED_ENTRY = wrapWorkerEntrypoint(middleware_insertion_facade_default);
}
var middleware_loader_entry_default = WRAPPED_ENTRY;
export {
  __INTERNAL_WRANGLER_MIDDLEWARE__,
  middleware_loader_entry_default as default
};
//# sourceMappingURL=index.js.map
