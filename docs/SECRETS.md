# Where the secrets live

The repo holds none. That is the whole design: `vps-plus` can be public, and
losing it costs you nothing but a bit of ops trivia.

## The four places a credential can be

| Location | Holds | Mode | In git |
|---|---|---|---|
| `vps.conf` | domains, paths, toggles — **no secrets** | 644 | no (gitignored, since it is machine-specific) |
| `stack/stack.env` | the Postgres password, generated on first run | 600 | no |
| `stack/apps/<app>.env` | each app's API keys and service-role keys | 600 | no |
| `~/.hermes`, `~/.claude`, `~/.gemini`, `~/.codex` | agent logins and API keys | 600 on the credential files | no |

Everything gitignored is listed explicitly in `.gitignore`, with
`!stack/apps/*.env.example` re-including the templates.

## The bundle

`export/export-from-windows.ps1` produces one archive holding *all* of the
above. Once decrypted it is plaintext OAuth tokens and API keys.

Handling rules, in order of how much they matter:

1. **Encrypt it.** `winget install FiloSottile.age`, and the script does the
   rest with a passphrase you choose. Without `age` it warns and writes
   plaintext.
2. **Move it with `scp`.** Encrypted in transit either way. Never put it in a
   cloud drive, a chat message, or a git repo.
3. **Let stage 40 shred it.** It does this automatically on the VPS.
4. **Delete the Windows copy.** The script prints the command; nothing deletes
   it for you.

## Private repositories

`50-repos.sh` clones over HTTPS. For a private repo, either:

```bash
# a token, used for this run only — never written to .git/config
sudo GH_TOKEN=ghp_xxx ./bootstrap.sh 50
```

or put a deploy key at `~/.ssh/id_ed25519` and switch the `REPO_*` values in
`vps.conf` to `git@github.com:` URLs.

Of the four, `plusthesite-` is the one under an organisation
(`github.com/plusthesite`), so it is the likeliest to need this.

## Rotating the Postgres password

`60-postgres.sh` generates the password once and then reuses it, because
rotating it silently would leave every app pointing at a database it can no
longer open. To rotate deliberately:

```bash
ops/psql.sh postgres -c "ALTER USER vpsplus WITH PASSWORD 'new-one';"
sed -i 's|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=new-one|' stack/stack.env
# then update every DATABASE_URL / HACK_DB_PASSWORD in stack/apps/*.env
ops/deploy.sh all
```

## What to do if the bundle leaks

Assume every key in it is compromised and rotate, roughly in order of blast
radius:

1. Supabase **service-role** keys — these bypass row-level security entirely.
2. `GEMINI_API_KEY`, `DEEPSEEK_API_KEY`, `GLM_API_KEY`, `OPENAI_API_KEY`.
3. `BLOB_READ_WRITE_TOKEN` and `ADMIN_TOKEN` (Trilux).
4. Claude / Gemini / Codex OAuth tokens — revoke the session and re-login.
5. The Postgres password, per above.

Supabase anon keys and `NEXT_PUBLIC_*` values do not need rotating: they are
already public by design, shipped inside the browser bundle. Row-level security
is what protects that data, and it is worth confirming RLS is actually on
rather than assuming it.
