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
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true }));

// --- api ---------------------------------------------------------------------
// Loaded dynamically so a syntax error in one handler does not take the static
// site down with it.
const API_DIR = path.join(SITE, 'api');
const mounted = [];

if (fs.existsSync(API_DIR)) {
    for (const file of fs.readdirSync(API_DIR).filter((f) => f.endsWith('.js'))) {
        const route = `/api/${path.basename(file, '.js')}`;
        try {
            const mod = await import(pathToFileURL(path.join(API_DIR, file)).href);
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

// The admin page must never be indexed; vercel.json enforced this with a header
// rule, and losing it in the move is exactly the kind of silent regression a
// migration produces.
app.get(/^\/admin(\/|$)/, (_req, res, next) => {
    res.setHeader('X-Robots-Tag', 'noindex, nofollow');
    next();
});

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
