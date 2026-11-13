# SplitPro local deployment status

Last updated: 2026-11-13 (~07:00 local / 12:00 UTC)
Status: **CORE APP RUNNING AND TESTED; SOME PLATFORM FEATURES BLOCKED BY THE SANDBOX.**
This is not a claim of full production verification. See the blockers and exact next actions
at the end.

## Identity and location

- Owner fork: <https://github.com/RizwinSulaiman/split-pro>
- Upstream: <https://github.com/oss-apps/split-pro> (MIT license; remote preserved)
- Install path: `C:\Users\User\Documents\ChatGPT\SplitPro`
- Base upstream commit: `5341ebb feat: add expense comments with participant notifications (#796)`
- Deployment files are committed on `main`; current deployment HEAD is `git log -1`.
- Local URL: **http://127.0.0.1:3000** (listener confirmed on loopback only)
- Host: Windows 11 `DESKTOP-HSDPRE9`, user `desktop-hsdpre9\user`

## Runtime and data

- PostgreSQL **17.7** Windows x64, project-local at `.local/pgsql`
- Live database: `127.0.0.1:55433`, role `splitpro`, database `splitpro`
- `pg_cron` source **1.6.8**, compiled with MSVC using upstream's Windows `Makefile.win`;
  extension schema version **1.6**, loaded through `shared_preload_libraries`
- `cron.use_background_workers=on`; `cron.timezone=UTC`; `cron.database_name=splitpro`
- Applied all **29** Prisma SQL migrations transactionally with `psql`, recorded in
  `_prisma_migrations` with SHA-256 checksums, because Prisma CLI's schema-engine child
  process fails with `spawn EPERM` in this sandbox.
- Receipts: `uploads/` (Git-ignored). Database/receipt data is test-only; no real financial
  records were imported.
- Local mail capture: Mailpit **1.33.1**; SMTP `127.0.0.1:1125`, UI/API `127.0.0.1:8025`.
  Port 1025 was occupied by an unrelated process and was left untouched.
- Backups: `L:\SplitPro-Backups\` (outside the repository)

Live processes observed at final check:

| Process                 |   PID | Listener                           | Notes                     |
| ----------------------- | ----: | ---------------------------------- | ------------------------- |
| PostgreSQL 17.7         |  2524 | `127.0.0.1:55433`                  | live database             |
| SplitPro / Node 22.16.0 | 31844 | `127.0.0.1:3000`                   | Next.js production server |
| Mailpit 1.33.1          | 26124 | `127.0.0.1:1125`, `127.0.0.1:8025` | local-only email testing  |

The live Postgres, app, and Mailpit are currently held by agent-managed background jobs
(`pwsh-dc1c545342f24a83`, `pwsh-75bf3f18f1f54b05`, `pwsh-9c7508f795e54f8b`). They are not
installed as Windows services; see **Autostart** below.

## What was verified

### HTTP health and private hosting

```text
GET /api/healthz  200 {"status":"ok"}
GET /api/readyz   200 {"status":"ok"}
```

`netstat` observed only `127.0.0.1:3000`, `127.0.0.1:55433`, `127.0.0.1:1125`, and
`127.0.0.1:8025`. There is no `0.0.0.0` listener for SplitPro or Mailpit. Unauthenticated
tRPC access returned **401** and unauthenticated receipt upload returned **401**.

### Real authentication

Authentication used the actual NextAuth email provider and a real generated magic link,
not a bypass or a mocked session:

1. Fetched `/api/auth/csrf`.
2. Submitted `/api/auth/signin/email` with the CSRF token and a `.test` email.
3. Read the generated email from local Mailpit.
4. Followed `/api/auth/callback/email...`; NextAuth set a session cookie.
5. Queried `/api/auth/session` and confirmed the returned user.

Three independent sessions succeeded:

```text
owner@splitpro.test  id=1
alice@splitpro.test  id=2
bob@splitpro.test    id=3
```

The app is currently usable by opening `http://127.0.0.1:3000`, entering an email, then
opening the captured magic link at `http://127.0.0.1:8025`. This is **local-only email
testing**: no externally deliverable mailbox, Google OAuth, or OIDC provider is configured.
The test accounts and group `Local E2E dummy 2026-11-13` are dummy data, not the owner's
records. `DISABLE_EMAIL_SIGNUP=false` for account creation; it can be set true after the
owner creates a real account.

A real browser UI test was attempted, but this sandbox blocks Chrome's process/IPC
primitives:

- Playwright launch: `spawn EPERM`.
- Manually launched Chrome: `mojo/public/cpp/platform/platform_channel.cc:112 Check failed:
Access is denied (0x5)`.
- Playwright/Chromium, system Chrome, and agent-browser all hit the same boundary.

The verified authentication is therefore real HTTP/session authentication, not a rendered
browser interaction. `/en/groups/1` returned `200 text/html`, but its data is client-rendered
and could not be visually confirmed.

### Functional test data

Created with authenticated tRPC calls through the running app and then queried from
PostgreSQL. The group has exactly 3 members.

- Equal expense: $120.00, paid by owner, split $40/$40/$40.
- Unequal exact expense: $90.00, paid by Alice, shares owner $10 / Alice $20 / Bob $60.
- Settlement 1: Bob → owner $70.00 (`SETTLEMENT`).
- Settlement 2: Bob → Alice $30.00 (`SETTLEMENT`).
- Two final settlements brought the pre-recurrence USD group balance to **zero**.
- Currency: €45.00 expense, paid by owner, split €30/€15/€15; EUR balances remained
  owner +€30.00, Alice -€15.00, Bob -€15.00.
- Receipt: valid PNG uploaded through the real multipart `/api/upload` endpoint; Sharp
  converted it to WebP. Files exist:
  `uploads/1/a229ec92-db20-48b0-9b53-c0053a3b70a2.webp` and a thumbnail. The authenticated
  file endpoint returned `200 image/webp`.
- Recurring template: `Dummy monthly internet`, `0 0 1 * *`; a second past-dated template
  was created to exercise recurrence generation. Both exist in `ExpenseRecurrence` with
  real `cron.job` rows.
- Persisted rows at check: 10 expenses, 26 expense-participant rows, 2 recurrences,
  3 cron jobs (2 expenses + cache cleanup), 3 users, 1 group.

Before adding the past recurrence, the USD balances were verified exactly zero and EUR was
+3000/-1500/-1500. After creating the past template and manually invoking its recurrence
function, current balances are:

```text
USD  owner +1600, Alice -800, Bob -800
EUR  owner +3000, Alice -1500, Bob -1500
```

This is expected test data, not a balance defect.

### Recurring-expense behavior and blocker

The app created real pg_cron jobs:

```text
jobid 3  Dummy monthly internet (recurring template)  schedule 0 0 1 * *  active=true
jobid 4  Dummy past recurrence template                schedule 0 0 1 * *  active=true
jobid 2  cleanup_cached_bank_data                      schedule 0 2 * * 0  active=true
```

The generated `ExpenseRecurrence` rows and foreign key are present. Manually invoking
`duplicate_expense_with_participants('c54b...')` created a derived expense
`ae2cb311-7916-48a9-9a74-743317bc8d00`, proving SplitPro's recurrence SQL and app-generated
pg_cron job record work.

**pg_cron itself does not execute jobs inside this sandbox.** A 3-second test job reached
`cron.job_run_details.status = starting` and then stalled. Both libpq mode and background
worker mode were tested; the latter stalls at `BgworkerStartup`. This is consistent with the
sandbox denying process/IPC operations. It is not yet verified that a due recurring expense
is generated by the scheduler.

### Application restart and persistence

The SplitPro Node process was stopped and restarted. After restart:

- schema version was `2.0.0` (data migration already applied);
- `/api/healthz` and `/api/readyz` remained 200;
- the owner session remained valid (`owner@splitpro.test`, id 1);
- the group page returned 200 and all test data remained.

The PostgreSQL server was **not** restarted; process signalling is blocked (see below), so
full database restart persistence is not verified. The database data survived the app
restart, and all migrations/data are on disk.

### Backup and verified restore

`scripts/local/backup-splitpro.ps1` was executed successfully on 2026-11-13. It produced:

```text
L:\SplitPro-Backups\splitpro-20261113-065317.dump
L:\SplitPro-Backups\splitpro-uploads-20261113-065317.tar.gz
L:\SplitPro-Backups\manifest-20261113-065317.json
```

Dump size 55,417 bytes; SHA-256 in the manifest. `pg_restore -l` read the archive, and the
receipt tar listed both WebP files.

A full restore was performed in an isolated PostgreSQL 17.7 cluster on port 55435 with
`cron.database_name=splitpro` and pg_cron upgraded 1.0→1.6 before restore. `pg_restore
--exit-on-error` returned **0**, and the restored cluster matched:

```text
User 3, Group 1, Expense 10, ExpenseParticipant 26,
ExpenseRecurrence 2, PrismaMigrations 29, cron.job 3,
ExpenseRecurrence_jobId_fkey present
```

The restore-test cluster was stopped after verification. Recovery steps are in
`README-LOCAL.md`.

## Blockers (with exact next actions)

1. **pg_cron scheduler blocked in sandbox**
   - Evidence: job run remains `starting`; launcher log shows the job starting but not
     completing; background worker mode stalls at `BgworkerStartup`.
   - Next action: run PostgreSQL and SplitPro in a normal Windows user session or approved
     process context, then restart PostgreSQL (`pg_ctl stop` / `start`) so the already-enabled
     background-worker scheduler can spawn jobs. Verify with a 3-second `SELECT now()` job
     and require `status = succeeded`.
   - Do not claim recurring generation until that test passes.

2. **Database process control blocked**
   - `pg_ctl stop` and `taskkill` both returned `Operation not permitted` from this session.
   - Next action: from a normal/unsandboxed PowerShell, use
     `.\.local\pgsql\bin\pg_ctl.exe -D .\.local\pgdata-live stop -m fast` and restart.
     This is also required for the full database restart-persistence test.

3. **Real browser automation blocked**
   - Playwright/Chrome/agent-browser fail at `spawn EPERM` or Chrome Mojo
     `Access is denied`. Authentication was verified through the actual HTTP flow instead.
   - Next action: run the browser test in an unsandboxed session, or grant a browser-capable
     approval channel. No GUI screenshot or DOM interaction is claimed.

4. **Autostart/restart policy unavailable**
   - `schtasks` failed with `The system cannot find the path specified`; the HKCU Run key
     returned `Requested registry access is not allowed`.
   - Current services are agent-managed background jobs and may stop when the agent session
     ends. `scripts/local/start-splitpro.cmd` is idempotent and is the manual restart path.
   - Next action (normal user session): put a shortcut to `start-splitpro.cmd` in
     `shell:startup`, or run:
     `schtasks /Create /SC ONLOGON /TN SplitPro-Local /TR "C:\Users\User\Documents\ChatGPT\SplitPro\scripts\local\start-splitpro.cmd" /F`.

5. **Prisma CLI child process**
   - `prisma migrate deploy` fails with `spawn EPERM`; migrations were applied with `psql`
     and recorded. This is acceptable for the current database but should be replaced by a
     normal Prisma migration run in an unsandboxed session.

6. **Build-only PWA workaround**
   - `tsc --noEmit` passed. Production build passed with one worker and in-build type check
     skipped; the Serwist route was temporarily stubbed because its esbuild process is
     blocked, then the source was restored.
   - The local built app has no working service worker/PWA route. Core app works. Build
     normally in an unsandboxed session to restore PWA output.

7. **Splitwise historical expenses**
   - Upstream only imports friends with balances and group/member records (README line 55;
     `src/utils/splitwiseImport.ts` ignores the export's `expenses` array). It creates
     synthetic “Splitwise Balance Import” rows and groups.
   - No Splitwise export file was found by filename in Downloads, Documents, or Desktop.
     No migration is claimed and no original data was modified.
   - Lossless-import proposal: map group/member emails and Splitwise IDs idempotently;
     preserve each expense date, currency, description, category, payer, and participant
     shares; store `splitwise:<id>` in `Expense.transactionId`; import settlements/comments/
     receipts with a dry-run and dedupe step. Requires a new importer and the owner's export.

8. **External auth**
   - Only a local captured mailbox is configured. Real external email or Google/OIDC needs
     owner-provided credentials/consent and, if exposed beyond loopback, HTTPS.

## Security and repository hygiene

- `.env`, `.local/`, and `uploads/` are Git-ignored and were verified with
  `git check-ignore`.
- No secret, magic link, session token, database dump, or receipt is tracked.
- `.gitignore` now includes `/.local/` and `/.pnpm-store/`.
- Passwords and `NEXTAUTH_SECRET` are random, unique, and live only in Git-ignored files.
- The live DB is loopback-only with SCRAM password authentication; the application role is
  least-privilege plus `pg_read_all_settings`/`INHERIT` needed by the recurrence function.
- An unused pre-recovery PostgreSQL cluster remains on 55432 with a trust rule for its test
  role; it contains no owner data and is not used by SplitPro. Stopped restore-test data
  directories also remain under `.local/`.
- Backups contain financial data and sessions; protect `L:\SplitPro-Backups\` and use
  encryption for real data.

## Repository changes

- `README-LOCAL.md` — local operation, auth, backup/restore, limitations.
- `DEPLOYMENT_STATUS.md` — this evidence file.
- `scripts/local/start-splitpro.ps1`, `.cmd` — idempotent local startup.
- `scripts/local/health-splitpro.ps1` — health/ready check.
- `scripts/local/backup-splitpro.ps1` — tested database + receipt backup.
- `.gitignore` — local deployment artifacts.

The existing upstream license and `origin`/`upstream` remotes are unchanged. No force-push
is used.
