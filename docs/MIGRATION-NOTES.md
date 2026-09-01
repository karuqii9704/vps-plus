# What the move actually changes

Honest notes on the gap between "it worked on Vercel/Netlify" and "it works on
the VPS". Nothing here blocks the migration; all of it will bite eventually if
it stays undocumented.

## Trilux still depends on Vercel

`api/lead.js` and `api/track.js` import `@vercel/blob` and write lead
submissions and pageview events there. That keeps working from any host as long
as `BLOB_READ_WRITE_TOKEN` is set, so the site functions on the VPS — but the
data still lives in Vercel's storage and still costs Vercel money.

Two ways out, whenever it becomes worth doing:

- **Postgres.** A `leads` and an `events` table in the `trilux` database. The
  handlers already normalise their payloads, so this is a `put()` → `INSERT`
  swap in two files plus a schema. `ops/psql.sh trilux` is where it would live.
- **Local disk.** A bind-mounted `$DATA_DIR/trilux` and `fs.appendFile` to
  JSONL. Simpler, but you lose querying and gain a backup problem.

Until then: the site is off Vercel's *compute*, not off Vercel.

`api/admin.js` also reads from the filesystem (`fs.readFileSync` on the CMS
JSON). On Vercel that read hit the deployment bundle; here it hits the
bind-mounted checkout, which is read-only. If the admin panel needs to *write*
content, that mount has to become read-write in `docker-compose.yml`, and the
change survives only until the next `git pull` overwrites it.

## NALAR has no standalone build

`plusthesite-` sets `output: "standalone"` in `next.config.ts`, so its image
carries a traced server and nothing else. NALAR does not, so
`apps/nalar/Dockerfile` ships the full `node_modules` instead — a noticeably
larger image and a slower deploy.

Adding three lines to NALAR's `next.config.ts` would fix it:

```ts
const nextConfig: NextConfig = {
  output: "standalone",
  // ...
};
```

That is a change to the NALAR repo, which is why it is not done here.

## Netlify-specific config is now dead weight

`netlify.toml` in both `plusthesite-` and `new-nalar` still declares
`@netlify/plugin-nextjs` and a `SECRETS_SCAN_OMIT_KEYS` list. Harmless on the
VPS — nothing reads them — but they will confuse whoever looks next. Same for
`vercel.json` in Trilux and studio.

The two rules in Trilux's `vercel.json` that actually changed behaviour
(`cleanUrls`, and the `X-Robots-Tag: noindex` on `/admin`) are reproduced in
`apps/trilux/server.js`. The cache headers are too. Nothing else in that file
mattered.

## Rate limiting is per process

`studio-plusthesite` keeps its AI rate-limit counters in memory
(`server/ai.js`). One container, one set of counters — correct today. If you
ever scale it to two replicas the effective limit doubles silently. Moving the
counters to Redis is the fix; running a single instance is the reason not to
bother yet.

## Supabase is still Supabase

Three of the four apps read from Supabase. Postgres on the VPS does not replace
that — it is there for the NALAR committee data (`HACK_DB_*`) and for anything
you want to move off Supabase later. If the goal is eventually to drop Supabase
too, that is a per-app data migration, not a hosting change, and it is not in
scope here.

## Hermes session history does not come along

`state.db` is 370 MB and is being written to whenever Hermes runs. The export
skips it by default, so the VPS starts with a fresh session store but keeps
`memories/`, which is the part that carries actual context.

To bring it anyway: close Hermes on Windows, then
`export-from-windows.ps1 -IncludeHermesState`.

## Paths inside your config were rewritten

Stage 40 edits `CLAUDE.md`, `AGENTS.md`, `GEMINI.md` and friends in place:

| Windows | VPS |
|---|---|
| `F:\Claude Work\PROJECTS\AI-Agent-Skills-Vault` | `/srv/skills-vault` |
| `C:\Users\karuqii9704\.claude` | `~/.claude` |
| `E:\PLUSSSSS` | `$REPOS_DIR` |
| `F:\Trilux Design` | `$REPOS_DIR/trilux-design-page` |
| `F:\NEW NALAR` | `$REPOS_DIR/new-nalar` |
| `F:\CLAUDE` | `/srv/claude-work` |

The originals are kept alongside as `*.windows-<timestamp>`.

`~/.claude.json` is **not** rewritten. It contains MCP server definitions, and
several of yours launch local Windows binaries — `node ~/.claude/mcp-on.js`
paths, the `codex-claude-bridge` npm link, the `filesystem` server scoped to
`C:\`, `E:\`, `F:\`. Guessing at Linux equivalents would produce servers that
fail at startup for reasons that look like Claude Code bugs. Stage 40 warns and
leaves it to you.

Worth reviewing after the first boot:

```bash
grep -o '[A-Z]:[^"]*' ~/.claude.json | sort -u
```

## The MCP servers that will not work

From your `CLAUDE.md`, the always-on HTTP servers (exa, github, motion) are
fine — they are remote. These are the ones that need attention:

- `filesystem` — scoped to `C:\Users\karuqii9704`, `E:\`, `F:\`. Re-scope to
  `/srv` and `$HOME`.
- `codex-bridge` — an npm link to `F:\Claude Work\PROJECTS\codex-claude-bridge`,
  which is not in the bundle. Clone it or drop the entry.
- `playwright` — needs `npx playwright install-deps` on a headless box before
  it can launch a browser.
- Account-level connectors (Figma, Supabase, Vercel, HeyGen) reauthenticate
  interactively and cannot be restored from a file.

## RTK

Your `CLAUDE.md` assumes the `rtk` binary is on PATH. It is not installed by
any stage here, because it is a token-efficiency tool rather than a dependency.
If you want it:

```bash
curl -fsSL https://raw.githubusercontent.com/.../install.sh | sh   # or: cargo install rtk
rtk init claude
```

`rtk gain` should work afterwards. If it errors, you have the wrong `rtk` —
see the note about the name collision in your `RTK.md`.
