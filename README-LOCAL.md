# SplitPro — local deployment (Windows)

This is the owner-specific deployment guide for the SplitPro fork on this PC. It is separate
from upstream's generic Docker documentation. Detailed evidence and blockers are in
[`DEPLOYMENT_STATUS.md`](DEPLOYMENT_STATUS.md).

## Current state

- App URL: **http://127.0.0.1:3000** (loopback only)
- Repository: <https://github.com/RizwinSulaiman/split-pro>
- Upstream: <https://github.com/oss-apps/split-pro> (MIT; remote preserved)
- Install path: `C:\Users\User\Documents\ChatGPT\SplitPro`
- Starting upstream commit: `5341ebb`
- Deployment commit: `a873562`
- Runtime: pinned Node `v22.16.0` under `.local/runtime/`
- Database: PostgreSQL `17.7` on `127.0.0.1:55433`, database `splitpro`
- `pg_cron`: source `1.6.8`, compiled with MSVC for Windows, extension schema `1.6`
- Local mail testing: Mailpit SMTP `127.0.0.1:1125`, UI/API `127.0.0.1:8025`
- Receipts: `uploads/` (Git-ignored)
- Database/receipt backups: `L:\SplitPro-Backups\`

At the time of writing these processes were running as agent-managed background jobs:
PostgreSQL (port 55433), SplitPro (port 3000), and Mailpit (ports 1125/8025). They are
loopback-only. See **Autostart and restart** for the current limitation and the exact
next action.

## Sign in

1. Open <http://127.0.0.1:3000>.
2. Enter any email address. With the current configuration the magic link is captured by
   Mailpit, not sent to the public Internet.
3. Open <http://127.0.0.1:8025>, open the newest message, and click the
   `http://127.0.0.1:3000/api/auth/callback/email...` link. It is a single-use link.
4. The session is stored in the SplitPro database and survives an application restart.

This is real NextAuth email verification, not a bypass. However, it is **local-only email
testing**: there is no externally deliverable mailbox configured. To use a real mailbox,
replace the `EMAIL_SERVER_*` / `FROM_EMAIL` values in `.env` with the owner's SMTP
credentials, set `NEXTAUTH_URL` to the URL the owner will use, and restart SplitPro. If the
instance is ever exposed beyond loopback, use HTTPS and a trusted OAuth/OIDC provider or a
real SMTP relay.

Dummy accounts created for verification: `owner@splitpro.test`, `alice@splitpro.test`,
`bob@splitpro.test` (all `.test`, not real addresses). The test group is
`Local E2E dummy 2026-11-13`. Do not use it for real financial records.

`DISABLE_EMAIL_SIGNUP=false` currently allows new magic-link accounts. After creating the
owner's real account, set it to `true` in `.env` and restart the app to close signups.
`ENABLE_SENDING_INVITES=false` and `ENABLE_USER_DISCOVERY=false`.

## Start, stop, and health

From a normal PowerShell window (not inside the restricted agent sandbox):

```powershell
# Idempotent start: PostgreSQL, Mailpit, then SplitPro
.\scripts\local\start-splitpro.cmd

# Health
.\scripts\local\health-splitpro.ps1
```

Manual equivalents:

```powershell
# Start PostgreSQL (if not running)
.\.local\pgsql\bin\pg_ctl.exe -D .\.local\pgdata-live -l .\.local\logs\postgres-start.log start -w

# Start SplitPro
$env:NODE_ENV='production'
.\.local\runtime\node-v22.16.0-win-x64\node.exe node_modules\next\dist\bin\next start -H 127.0.0.1 -p 3000
```

`pg_ctl stop` / `pg_ctl restart` require a normal Windows process context. Inside the
current DSH sandbox both `pg_ctl stop` and `taskkill` fail with `Operation not permitted`;
this is an environment limitation, not an application error.

## Backups and restore

Create a backup outside the repository:

```powershell
.\scripts\local\backup-splitpro.ps1
```

The script writes a custom-format `pg_dump`, a receipt archive, and a SHA-256 manifest to
`L:\SplitPro-Backups\`. It uses the local PostgreSQL superuser only for the dump because
the application role is subject to `pg_cron` row-level security. Keep this directory
private; it contains sessions and financial test data.

### Verified restore procedure

1. On a replacement PostgreSQL cluster, set `cron.database_name = 'splitpro'` and
   `shared_preload_libraries = 'pg_cron'`. The database name must be `splitpro`.
2. Start the cluster on a free loopback port.
3. Create the `splitpro` login role and an empty `splitpro` database owned by it.
4. Install the complete pg_cron schema before restoring. The local source build ships a
   generated `pg_cron--1.6.sql`; if using the unmodified control default, run:

   ```sql
   CREATE EXTENSION pg_cron VERSION '1.0';
   ALTER EXTENSION pg_cron UPDATE TO '1.6';
   ```

   Verify `cron.job` has `jobname` and `cron.job_run_details` exists.

5. Restore with the superuser:

   ```powershell
   .\.local\pgsql\bin\pg_restore.exe -h 127.0.0.1 -p <port> -U postgres `
     -d splitpro --exit-on-error -Fc L:\SplitPro-Backups\splitpro-<stamp>.dump
   ```

6. Extract the receipt archive into the project root:

   ```powershell
   tar.exe -xzf L:\SplitPro-Backups\splitpro-uploads-<stamp>.tar.gz -C .
   ```

7. Point `.env` at the restored database, ensure `NEXTAUTH_SECRET` is the same (otherwise
   sessions are invalid), and start SplitPro.

A restore was verified in an isolated cluster on port 55435: application table counts
matched exactly, the cron extension loaded, `cron.job` contained 3 jobs, and the
`ExpenseRecurrence_jobId_fkey` constraint was present.

## Recurring expenses — current limitation

Recurring templates and real pg_cron jobs are created and persisted. For example the test
data has:

- a template `Dummy monthly internet (recurring template)` with schedule `0 0 1 * *`;
- a template `Dummy past recurrence template` with a past date;
- a derived expense created by manually executing the same
  `duplicate_expense_with_participants(uuid)` function that pg_cron would call.

The **pg_cron scheduler does not execute jobs inside this agent sandbox**. Its launcher
starts, but jobs remain in `starting`/`connecting` states. Both libpq mode and
background-worker mode were tested. This is a sandbox process/IPC restriction, not a
SplitPro configuration error.

Exact next action: run PostgreSQL in a normal Windows service/task context (or grant a
capable approval channel), then stop and start the live cluster normally so the scheduler
can spawn workers. Test with:

```sql
SELECT cron.schedule('smoke', '3 seconds', $$SELECT now()$$);
SELECT * FROM cron.job_run_details ORDER BY runid DESC LIMIT 5;
SELECT cron.unschedule('smoke');
```

Do not treat recurrence as production-verified until a run appears as `succeeded`.

## Autostart and restart

An automatic startup task could **not** be installed from this sandbox: `schtasks` and
writes to the HKCU Run key were denied. The application and database remain running as
agent-managed background jobs, but they are not guaranteed to survive the agent session.

To install autostart in a normal user session, point a `shell:startup` shortcut at
`scripts\local\start-splitpro.cmd`, or register a per-user logon task:

```powershell
schtasks /Create /SC ONLOGON /TN SplitPro-Local `
  /TR "C:\Users\User\Documents\ChatGPT\SplitPro\scripts\local\start-splitpro.cmd" /F
```

There is no watchdog installed. The start script is idempotent but does not restart a
crashed application by itself.

## Splitwise import status

Upstream currently supports a **partial** import: it reads `friends` with a non-zero
balance and `groups`/members from a Splitwise JSON export. It creates synthetic
`Splitwise Balance Import` expenses and groups. It does **not** import historical
`expenses`, comments, categories, or receipts.

No Splitwise export file was found by filename in the owner's Downloads, Documents, or
Desktop directories. No migration is claimed.

A lossless import would need a new importer (not implemented) that:

- maps group and member emails, preserving Splitwise group IDs for idempotency;
- maps each expense `paid_by` and `users` shares/paid-share data into SplitPro's
  `Expense` + `ExpenseParticipant` net-amount model, preserving original date, currency,
  description, category, and deleted state;
- stores the Splitwise expense ID in `Expense.transactionId` (for example
  `splitwise:<id>`) to prevent duplicates;
- imports comments into `ExpenseNote` and downloads/inspects receipt URLs through a
  user-provided, privacy-preserving step;
- imports settlements as `SETTLEMENT` and currency conversions with the correct split type;
- runs in dry-run mode first and never modifies the original export file.

Do not send or commit the owner's raw Splitwise export; it contains personal financial data.

## Security notes

- SplitPro, PostgreSQL, and Mailpit bind only to `127.0.0.1`. Do not port-forward or expose
  them without HTTPS, real SMTP/OIDC, and deliberate review.
- `.env` and `.local/` are Git-ignored. `uploads/` is Git-ignored. `NEXTAUTH_SECRET` and the
  database passwords are unique and were generated locally.
- Mailpit captures login links in plain text. Clear messages after use and keep the UI
  private.
- Backups contain financial data and sessions. The current destination is a local `L:`
  partition; use BitLocker or an encrypted, access-controlled backup target for real data.
- Rotate the database password and `NEXTAUTH_SECRET` if either is exposed. Rotating the
  NextAuth secret invalidates sessions.
- Only the live PostgreSQL cluster on 55433 is running. Stopped pre-recovery and
  restore-test data directories remain under `.local/`; they contain no owner data and are
  not used by SplitPro.

## Build notes

The production build passed. Because the DSH Windows sandbox blocks child processes used
by Next's type checker, its Serwist/esbuild service-worker step, and Prisma's schema engine,
the build used temporary local workarounds:

- `tsc --noEmit` was run separately and passed;
- the build used one worker and disabled in-build type checking;
- the Serwist route was stubbed for the build, then the original source was restored;
- Prisma migrations were applied with `psql` and recorded in `_prisma_migrations` with
  SHA-256 checksums because `prisma migrate deploy` fails with `spawn EPERM`.

The resulting local build does not include a working service worker/PWA route. Core web
application features work. For an unmodified PWA build, build in an unsandboxed session.
