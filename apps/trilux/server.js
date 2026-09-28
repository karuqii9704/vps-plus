// Trilux on a VPS instead of Vercel.
//
// The repo is a static site plus three Vercel serverless handlers in api/.
// Those handlers are plain `export default async (req, res)` functions using
// req.query / req.body / res.status().json() — which is Express's own shape,
// because Vercel's Node runtime is Express-compatible on purpose. So rather
// than rewriting them, this mounts them.
//
// The site itself is bind-mounted read-only at SITE_ROOT, so redeploying
// content is `git pull && docker restart vpsplus-trilux` with no image build.
//
// Still Vercel-dependent: api/lead.js and api/track.js write to Vercel Blob.
// That keeps working from any host as long as BLOB_READ_WRITE_TOKEN is set —
// see docs/MIGRATION-NOTES.md for the Postgres alternative.

import express from 'express';
import compression from 'compression';
import path from 'node:path';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const SITE = process.env.SITE_ROOT || '/site';
const PORT = Number(process.env.PORT || 8080);

const app = express();
app.disable('x-powered-by');
// Nginx is the only hop in front of this, so the first X-Forwarded-For entry
// is the real client. Any other value here makes the handlers' IP logging lie.
app.set('trust proxy', 1);

app.use(compression());
// Body parsing, route-aware: the Vercel-era handlers DISAGREE on how they
// read the body — lead.js/admin.js use the parsed req.body object, while
// track.js consumes the RAW request stream itself (and errors out on an
// already-consumed one). Parsing all of /api/* starves track; parsing none
// starves lead/admin. JSON-parse every api route except /api/track, and
// keep urlencoded for the static pages only.
app.use((req, _res, next) => {
    if (req.path === "/api/track") return next();
    if (req.path.startsWith("/api/")) return express.json({ limit: "10mb" })(req, _res, next);
    return express.urlencoded({ extended: true })(req, _res, next);
});

// --- api ---------------------------------------------------------------------
// The Vercel-style handlers live in the bind-mounted site (/site/api) but
// import @vercel/blob, which only exists in this image's /app/node_modules.
// ESM resolution walks up from the importing file, so the handlers (and the
// data/ seed files) are copied into /app at boot — a restart picks up
// handler changes, exactly like a server.js change.
// Loaded dynamically so a syntax error in one handler does not take the static
// site down with it.
const APP_API = path.join(process.cwd(), "api");
const APP_DATA = path.join(process.cwd(), "data");
// Copy the api/ handlers and data/ seeds into /app at boot — the handlers
// import @vercel/blob from /app/node_modules and ESM resolution walks up
// from the importing file, so they cannot run from the read-only /site
// mount. Per-file copy (no rmdir): /app is root-owned, only /app/api and
// /app/data are writable by this user. A restart picks up handler changes.
const mounted = [];

for (const [src, dst] of [
    [path.join(SITE, "api"), APP_API],
    [path.join(SITE, "data"), APP_DATA],
]) {
    if (!fs.existsSync(src)) continue;
    try {
        fs.mkdirSync(dst, { recursive: true });
        for (const entry of fs.readdirSync(src)) {
            fs.copyFileSync(path.join(src, entry), path.join(dst, entry));
        }
    } catch (err) {
        console.error(`[trilux] failed to sync ${src} -> ${dst}:`, err.message);
    }
}

if (fs.existsSync(APP_API)) {
    for (const file of fs.readdirSync(APP_API).filter((f) => f.endsWith('.js'))) {
        const route = `/api/${path.basename(file, '.js')}`;
        try {
            const mod = await import(pathToFileURL(path.join(APP_API, file)).href);
            const handler = mod.default;
            if (typeof handler !== 'function') {
                console.warn(`[trilux] ${file} has no default export — skipped`);
                continue;
            }
            app.all(route, (req, res) => {
                Promise.resolve(handler(req, res)).catch((err) => {
                    console.error(`[trilux] ${route}:`, err);
                    if (!res.headersSent) res.status(500).json({ error: 'handler failed' });
                });
            });
            mounted.push(route);
        } catch (err) {
            console.error(`[trilux] failed to load ${file}:`, err.message);
        }
    }
}

app.get('/api/health', (_req, res) =>
    res.json({ ok: true, api: mounted, uptimeSec: Math.round(process.uptime()) }),
);

// --- static ------------------------------------------------------------------
// vercel.json set cleanUrls + long cache on fonts and images; those two rules
// are the only ones that actually change behaviour, so they are reproduced here.
// The admin page must never be indexed; vercel.json enforced this with a header
// rule, and losing it in the move is exactly the kind of silent regression a
// migration produces. Registered BEFORE express.static — a middleware after it
// never runs for files that static serves directly.
app.get(/^\/admin(\/|$)/, (_req, res, next) => {
    res.setHeader('X-Robots-Tag', 'noindex, nofollow');
    next();
});
// Vercel's cleanUrls also serves directory pages at their bare path (/admin
// → /admin/index.html); express static with redirect:false does NOT — so
// rewrite the two CMS pages explicitly before static kicks in.
// Exact-match regex, NOT app.get('/admin'): Express is non-strict by default
// and '/admin' would also match '/admin/', redirecting to itself in a loop.
for (const page of ['/admin', '/project']) {
    app.get(new RegExp(`^${page}$`), (_req, res) => res.redirect(301, page + '/'));
}
app.use(
    express.static(SITE, {
        extensions: ['html'],          // cleanUrls: /admin -> /admin/index.html
        redirect: false,               // trailingSlash: false
        setHeaders(res, filePath) {
            if (/[\\/]assets[\\/]fonts[\\/]/.test(filePath)) {
                res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
            } else if (/[\\/]assets[\\/]img[\\/]/.test(filePath)) {
                res.setHeader('Cache-Control', 'public, max-age=604800');
            }
        },
    }),
);
app.use((_req, res) => {
    const notFound = path.join(SITE, '404.html');
    if (fs.existsSync(notFound)) return res.status(404).sendFile(notFound);
    res.status(404).type('text/plain').send('not found');
});

const server = app.listen(PORT, '0.0.0.0', () => {
    console.log(`[trilux] serving ${SITE} on :${PORT}`);
    console.log(`[trilux] api: ${mounted.join(', ') || 'none'}`);
    if (!fs.existsSync(path.join(SITE, 'index.html'))) {
        console.warn('[trilux] no index.html at SITE_ROOT — is the bind mount right?');
    }
});

// Docker sends SIGTERM on `restart`; draining means an in-flight lead POST is
// not dropped mid-write.
for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => server.close(() => process.exit(0)));
}
