// Post-deploy smoke test: open every configured site in a real browser and
// check it actually works.
//
// ops/status.sh already tells you a container is up and returns HTTP 200. That
// is not the same as the site working — a Next.js app whose client bundle
// throws returns a perfectly good 200 with a blank page, and a missing
// NEXT_PUBLIC_* value fails exactly that way. This catches it.
//
// Run it through ops/smoke.sh, which reads the domains out of vps.conf.
//
//   SMOKE_TARGETS='[{"key":"plus","url":"https://www.plusthe.site"}]' node ops/smoke.mjs

import { chromium } from 'playwright';

const targets = JSON.parse(process.env.SMOKE_TARGETS || '[]');
const TIMEOUT = Number(process.env.SMOKE_TIMEOUT_MS || 30000);

if (targets.length === 0) {
    console.error('no targets — set a DOMAIN_* in vps.conf');
    process.exit(2);
}

// Third-party noise that says nothing about whether your site is broken.
const IGNORED_CONSOLE = [
    /favicon/i,
    /Download the React DevTools/i,
    /\[Fast Refresh\]/i,
    /Content Security Policy/i, // report-only CSP chatter
];

const c = {
    reset: '\x1b[0m', dim: '\x1b[2m', bold: '\x1b[1m',
    red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m',
};

async function check(browser, target) {
    const problems = [];
    const notes = [];

    const context = await browser.newContext({
        // Deliberately NOT ignoring HTTPS errors: an invalid certificate is
        // one of the things this is here to catch.
        userAgent: 'vps-plus-smoke/1.0',
    });
    const page = await context.newPage();

    const consoleErrors = [];
    const failedRequests = [];

    page.on('console', (msg) => {
        if (msg.type() !== 'error') return;
        const text = msg.text();
        if (IGNORED_CONSOLE.some((re) => re.test(text))) return;
        consoleErrors.push(text.slice(0, 160));
    });

    page.on('requestfailed', (req) => {
        // Only same-origin failures matter; an analytics domain being blocked
        // is not a deploy problem.
        try {
            if (new URL(req.url()).origin === new URL(target.url).origin) {
                failedRequests.push(`${req.method()} ${new URL(req.url()).pathname}`);
            }
        } catch { /* malformed URL, ignore */ }
    });

    let response;
    try {
        response = await page.goto(target.url, { waitUntil: 'networkidle', timeout: TIMEOUT });
    } catch (err) {
        problems.push(`navigation failed: ${err.message.split('\n')[0]}`);
        await context.close();
        return { target, problems, notes };
    }

    const status = response?.status() ?? 0;
    if (status >= 400) problems.push(`HTTP ${status}`);
    else notes.push(`HTTP ${status}`);

    // TLS: playwright would have thrown above on an invalid chain, so reaching
    // here over https means the certificate verified.
    if (target.url.startsWith('https://')) notes.push('TLS ok');

    const title = (await page.title()).trim();
    if (!title) problems.push('empty <title>');
    else notes.push(`title "${title.slice(0, 40)}"`);

    // The blank-page case: 200, valid HTML shell, nothing rendered into it.
    const bodyText = (await page.locator('body').innerText().catch(() => '')).trim();
    if (bodyText.length < 50) {
        problems.push(`body has ${bodyText.length} chars of text — page likely did not render`);
    } else {
        notes.push(`${bodyText.length} chars rendered`);
    }

    if (consoleErrors.length) problems.push(`console: ${consoleErrors[0]}${consoleErrors.length > 1 ? ` (+${consoleErrors.length - 1})` : ''}`);
    if (failedRequests.length) problems.push(`failed request: ${failedRequests[0]}${failedRequests.length > 1 ? ` (+${failedRequests.length - 1})` : ''}`);

    // Two apps expose a health endpoint that reports whether their server-side
    // key actually reached the process — worth asserting, since a missing
    // GEMINI_API_KEY does not otherwise show up in the UI until someone uses it.
    if (target.health) {
        try {
            const res = await page.request.get(target.url + target.health, { timeout: 10000 });
            const body = await res.json();
            if (!res.ok()) problems.push(`${target.health} -> HTTP ${res.status()}`);
            else if (body.ai === false) problems.push(`${target.health} reports ai:false — GEMINI_API_KEY never reached the process`);
            else notes.push(`${target.health} ok`);
        } catch (err) {
            problems.push(`${target.health} unreachable: ${err.message.split('\n')[0]}`);
        }
    }

    await context.close();
    return { target, problems, notes };
}

const browser = await chromium.launch();
let failed = 0;

console.log(`${c.bold}smoke test${c.reset} — ${targets.length} site(s)\n`);

for (const target of targets) {
    const { problems, notes } = await check(browser, target);
    const label = target.key.padEnd(8);

    if (problems.length === 0) {
        console.log(`${c.green} ok ${c.reset} ${label} ${target.url}`);
        console.log(`     ${c.dim}${notes.join('  ·  ')}${c.reset}`);
    } else {
        failed++;
        console.log(`${c.red}FAIL${c.reset} ${label} ${target.url}`);
        for (const p of problems) console.log(`     ${c.red}${p}${c.reset}`);
        if (notes.length) console.log(`     ${c.dim}${notes.join('  ·  ')}${c.reset}`);
    }
    console.log();
}

await browser.close();

if (failed > 0) {
    console.log(`${c.red}${failed} of ${targets.length} site(s) failed${c.reset}`);
    console.log(`${c.dim}logs: ops/logs.sh <app> 200${c.reset}`);
    process.exit(1);
}
console.log(`${c.green}all ${targets.length} site(s) healthy${c.reset}`);
