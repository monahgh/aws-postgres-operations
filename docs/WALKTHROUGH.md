# Walkthrough: what each step does and why

A learning companion to the README. Each section: what you run, what happens under the hood,
what to look for in the output, and the key takeaway.

---

## Step 1: setup_workload.sh (the one-time bootstrap)

You ran:
```bash
sudo aws s3 sync --region eu-central-1 s3://pgops-lab-files-<account> /opt/dblab
sudo bash /opt/dblab/scripts/setup_workload.sh
```

### Part 1: get the files
`aws s3 sync` copies the lab bucket into `/opt/dblab` on the instance:
```
/opt/dblab/
├── dblab.env       # settings written by Terraform: region, bucket, DB identifiers, secret name, db name
├── scripts/        # setup, load, replication check, failover test, backup validation
└── sql/            # the four SQL labs
```
It authenticates with the instance's IAM role (no keys on the box). Terraform uploads the files,
so the repo on your PC is the single source of truth.

### Part 2: what setup_workload.sh does

| # | Action | Why |
|---|---|---|
| 1 | Checks it runs as root and that `dblab.env` exists | Fail fast with a clear message instead of half-configuring the box |
| 2 | Installs `postgresql15-contrib` (pgbench) and `jq` | `psql` was already installed by user data; pgbench generates load, jq parses JSON from the AWS CLI |
| 3 | Writes `/etc/profile.d/dblab.sh` with `use_primary`, `use_replica`, `labsync` | Every login shell (`bash -l`) gets these commands |
| 4 | Seeds data: `pgbench -i -s 10 --foreign-keys` (skipped if tables exist) | 1,000,000 accounts, 100 tellers, 10 branches: realistic data to query, back up and replicate |
| 5 | Creates and starts `pgbench-load.service` (systemd) | Constant background traffic: 4 clients, 20 TPS |

### How `use_primary` / `use_replica` work
```
use_primary
  ├─ aws secretsmanager get-secret-value  -> username + password (JSON, parsed by jq)
  ├─ aws rds describe-db-instances        -> endpoint address of pgops-lab-postgres-primary
  └─ export PGHOST PGUSER PGPASSWORD PGDATABASE=appdb PGSSLMODE=require PGPORT=5432
```
`psql`, `pgbench` and `pg_dump` all read these `PG*` environment variables, so afterwards plain
`psql` connects with no arguments. Nothing is hardcoded and the password is never written to disk.
`PGSSLMODE=require` forces TLS to RDS.

### What pgbench is
PostgreSQL's built-in benchmarking tool.
- `pgbench -i` (initialize) creates 4 tables and bulk-loads them. Scale `-s 10` = 10 x (1 branch,
  10 tellers, 100,000 accounts).
- `pgbench` (run mode) repeats a TPC-B style bank transaction:
  ```sql
  BEGIN;
  UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
  SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
  UPDATE pgbench_tellers  SET tbalance = tbalance + :delta WHERE tid = :tid;
  UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
  INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (...);
  END;
  ```
  So accounts/tellers/branches only get UPDATEs (row counts never change) and history gets INSERTs
  (grows forever). Backup validation relies on this.

### Why a background load service
The labs need real traffic: pg_stat_statements has queries to rank, updates create dead tuples
for vacuum, WAL keeps flowing so replication lag is meaningful, and the failover test has live
writes to interrupt.
- `pgbench_load.sh` loops: `use_primary` -> 5 minutes of pgbench -> repeat. Re-reading the endpoint
  and secret each round is what lets it recover by itself after a failover.
- `-R 20` rate-limits to 20 transactions/s so a db.t4g.micro is busy but not saturated.
- systemd `Restart=always` restarts it on crash and starts it on boot.
- Logs: `sudo journalctl -u pgbench-load -f` (sudo because `ssm-user` cannot read the system journal).

**Takeaway:** "I bootstrapped the client host from S3 with an instance role, pulled
credentials from Secrets Manager at runtime, and ran a rate-limited synthetic workload as a
systemd service so every exercise ran against live traffic."

---

## Step 2: backup_validate.sh (running in window 2)

### The idea
Automated backups exist, but **a backup is only proven once you have restored it and checked the
data**. This script does that end to end, the way a scheduled job would in production.

### What it does, in order

| Phase | What happens | Approx. time |
|---|---|---|
| 1. Canary + counts | Creates table `backup_canary`, inserts one row with a unique run ID (the timestamp). Records exact `count(*)` of `pgbench_accounts`, `pgbench_branches`, `pgbench_tellers` | seconds |
| 2. Snapshot | `aws rds create-db-snapshot` of the primary as `pgops-lab-validate-snap-<run>`, then waits until `available` | 3-10 min |
| 3. Restore | `aws rds restore-db-instance-from-db-snapshot` to a NEW instance `pgops-lab-validate-db-<run>` in the same subnet group and security group as the primary; waits until `available` | 10-20 min |
| 4. Verify | Connects to the restored instance: is the canary row there? Do the three counts match exactly? | seconds |
| 5. Report | Prints PASS/FAIL per check and the snapshot, restore and total times; publishes CloudWatch metrics `DBLab/BackupValidation`: `RestoreSeconds` and `ValidationSuccess` (1/0) | seconds |
| 6. Cleanup (always) | Deletes the temp instance (waits until gone), then the snapshot | 5-10 min |

### Design choices worth explaining

- **Canary row**: proves the snapshot contains data written *just before* it was taken. Row counts
  alone could match an older backup; a unique ID cannot.
- **Why only accounts/branches/tellers are counted**: pgbench only UPDATEs them, so their counts are
  stable under live load. `pgbench_history` keeps growing, so its count would never match.
- **Same subnet group and security group** as the primary: the restored instance is private and
  the workload server is already allowed to reach it on 5432.
- **Restored as single-AZ db.t4g.micro**: validation does not need HA, so it costs the minimum.
- **`trap cleanup EXIT`**: cleanup runs on success, failure or Ctrl+C. A forgotten restored
  instance is the classic surprise on the bill.
- **Least privilege**: the IAM role can create snapshots and restore, but can delete only
  instances and snapshots named `pgops-lab-validate-*`. A bug in this script cannot delete the primary.
- **Multi-AZ bonus**: on a Multi-AZ instance RDS takes the snapshot from the standby, so the primary
  sees no I/O freeze.
- **Password**: the restored instance keeps the snapshot's master password (same secret). With
  `manage_master_user_password`, you would set a temporary password on the copy.

### What to look for
```
PASS canary row <run id> found
PASS pgbench_accounts: 1000000 rows
PASS pgbench_branches: 10 rows
PASS pgbench_tellers: 100 rows
Total validation time: ...s (snapshot ...s, restore ...s)
RESULT: backup is restorable and consistent
Cleanup done.
```
While it runs, watch RDS -> Databases (the `validate-db` instance appears as `creating`) and
RDS -> Snapshots -> Manual.
Afterwards: CloudWatch -> Metrics -> All metrics -> `DBLab/BackupValidation`.

### Vocabulary
- **RPO** (recovery point objective): how much data you can lose. Automated backups plus
  transaction logs allow point-in-time restore to within about 5 minutes.
- **RTO** (recovery time objective): how long recovery takes. The `restore ...s` number is your
  measured RTO evidence for a snapshot restore.
- Snapshots are incremental after the first one and stored in S3 by RDS.

**Takeaway:** "Backups are worthless until restored. I automated a restore test: canary
row, exact row counts, measured restore time published to CloudWatch so you can alarm on it,
and guaranteed cleanup. In production I would run it on a schedule (EventBridge + an ECS task or
Lambda-triggered Step Functions) and alarm when ValidationSuccess is 0 or RestoreSeconds grows."

---

## Step 3: Lab 01, query tuning (`sql/01_query_tuning.sql`)

```bash
use_primary
psql -f /opt/dblab/sql/01_query_tuning.sql | tee ~/lab01.txt
```
Better for learning: open `psql` and paste one section at a time (`less /opt/dblab/sql/01_query_tuning.sql`).

### How to read EXPLAIN (ANALYZE, BUFFERS)
```
Index Scan using idx_orders_customer on orders  (cost=0.43..45.10 rows=10 width=40) (actual time=0.02..0.05 rows=9 loops=1)
  Index Cond: (customer_id = 4242)
  Buffers: shared hit=12
Execution Time: 0.08 ms
```
- **Node type**: how rows are fetched (Seq Scan, Index Scan, Bitmap Heap Scan, Index Only Scan, Sort...). Read the tree bottom-up / innermost first.
- **cost=startup..total**: planner estimate in abstract units. Only for comparing plans.
- **rows (estimate) vs actual rows**: a big gap means bad statistics -> run ANALYZE.
- **actual time** in ms, per loop. **Execution Time** at the bottom is the real total.
- **Buffers: shared hit** = 8 KB pages found in memory; **read** = fetched from disk. Fewer is better.
- **Filter / Rows Removed by Filter**: rows read then thrown away = wasted work.

### Setup
Creates `customers` (200k) and `orders` (2M, ~1% `refunded`) with `generate_series`, then `ANALYZE`
so the planner has statistics. `orders.customer_id` has a foreign key but **no index**.

### Section 1: foreign key without an index
- Before: `Parallel Seq Scan on orders` to find one customer's orders: all 2M rows read.
- The DELETE on customers shows `Trigger for constraint orders_customer_id_fkey: time=...`: Postgres
  checks the child table for rows referencing the parent, and without an index that is a full scan
  on every parent delete/update.
- Fix: `CREATE INDEX CONCURRENTLY` builds without blocking writes (it scans twice and waits for
  running transactions; cannot run inside BEGIN). A failed build leaves an INVALID index: the
  `indisvalid` query checks for it.
- After: `Index Scan` / `Bitmap Index Scan`, time drops from ~100s of ms to <1 ms; the FK trigger too.
- **Talking point**: Postgres indexes the referenced side (PK) automatically, never the referencing
  side. Unindexed FKs are a classic cause of slow deletes and lock contention.

### Section 2: composite index column order
Query: `WHERE customer_id = ? AND created_at >= now() - 90 days ORDER BY created_at DESC`.
- `(created_at, customer_id)`: wrong order. The index is sorted by date first, so one customer's
  rows are scattered; the planner ignores it.
- `(customer_id, created_at)`: right order. Jump to the customer, rows are already sorted by date:
  `Index Scan Backward`, **no Sort node**, no Filter.
- **Rule**: equality columns first, then range/sort columns. An index on (a, b) also serves queries on
  `a` alone, never on `b` alone.

### Section 3: covering index + visibility map
Query sums `amount` for a range of customers.
- Before: index finds rows, then each row is fetched from the table (heap) to read `amount`.
- `CREATE INDEX ... (customer_id) INCLUDE (amount)`: `amount` stored in the index leaf pages.
- `VACUUM` sets the visibility map (which pages are all-visible), so Postgres can trust the index
  without checking the heap.
- After: `Index Only Scan ... Heap Fetches: 0`.
- **Talking point**: index-only scans depend on vacuum. On a busy table with stale visibility map
  you see Heap Fetches > 0 and lose the benefit.

### Section 4: partial index
Query: latest 20 `refunded` orders (~1% of rows).
- Before: scan everything, keep 1%, top-N sort.
- `CREATE INDEX ... (created_at) WHERE status = 'refunded'`: only indexes the 1%.
- After: `Index Scan Backward` on a tiny index; the size query shows it is a fraction of the others.
- **Use for**: skewed data such as "pending jobs", "unprocessed events", soft-delete `WHERE deleted_at IS NULL`.

### Section 5: expression index
Query: `WHERE lower(email) = '...'`. A plain index on `email` cannot be used because the query
applies a function. `CREATE INDEX ... (lower(email))` indexes the computed value; the query must use
the exact same expression. `ANALYZE` gathers statistics for it.

### Section 6: work_mem and sorts spilling to disk
- `work_mem = 1MB`: `Sort Method: external merge  Disk: ~40000kB`: the sort did not fit in memory
  and used temp files.
- `work_mem = 256MB`: `Sort Method: quicksort  Memory: ...`: faster.
- **Careful**: work_mem is per sort/hash operation per connection. 100 connections x 3 sorts x
  256MB can exhaust RAM. Raise it per session or per role for reporting jobs, not globally.
  `log_temp_files = 0` logs every spill so you can find them.

### Section 7: pg_stat_statements
Normalized query statistics (parameters replaced by `$1`). Columns: `calls`, `total_ms`
(sort by this to find what costs the most overall), `mean_ms`, `cache_hit_pct`,
`temp_blks_written` (spills). You will see the pgbench transaction statements from the background
load next to the lab queries.
- **Talking point**: optimise by total time, not just by the slowest single query. A 2 ms query
  called 1M times costs more than one 10 s report.

### Section 8: unused and redundant indexes
- Unused: `idx_scan = 0` (the deliberately useless `idx_customers_country` shows up). Every index
  slows INSERT/UPDATE, adds WAL (and so replication traffic), vacuum work and storage.
- Redundant: `idx_orders_customer (customer_id)` is a prefix of `idx_orders_customer_created`.
- Before dropping: stats are per instance, so check the replica too, and check since when stats
  were collected (after a restart or reset, "0 scans" means little).

---

## Step 4: Lab 02, partitioning (`sql/02_partitioning.sql`)

```bash
use_primary
psql -f /opt/dblab/sql/02_partitioning.sql | tee ~/lab02.txt
```

### The idea
One logical table `events` is split into physical tables, one per month. Queries still use
`events`; Postgres routes inserts to the right month and skips months a query cannot need.

### Setup
- `CREATE TABLE events (...) PARTITION BY RANGE (created_at)`: the parent holds no data.
- A `DO` block (PL/pgSQL loop) creates `events_YYYY_MM` for the last 12 months plus next month.
- `events_default` catches rows outside every range, instead of the INSERT failing.
- The primary key is `(id, created_at)`: a unique key must include the partition key, because each
  partition enforces uniqueness only locally.
- 1M rows over ~11 months, one index created on the parent: Postgres creates it on every partition
  (and on future ones).
- The first query lists each partition with its size and approximate rows.

### Section 1: pruning at planning time
Query for one month using **constant** dates: the plan shows **only one partition**. Postgres
compared the WHERE clause with the partition bounds and removed the other 13 before running.

### Section 2: pruning at execution time
`WHERE created_at >= now() - interval '7 days'`: `now()` is not a constant at planning, so
pruning happens when execution starts: look for **`Subplans Removed: N`**. Same with prepared
statement parameters.

### Section 3: no pruning
- `SET enable_partition_pruning = off`: the plan lists every partition. This is what pruning saves.
- `WHERE kind = 'purchase'` (not the partition key): every partition is scanned even with pruning on.
- **Lesson**: choose the partition key from the most common filter (usually time). Queries that do not
  filter on it get slower than on a single table.

### Section 4: retention
- `ALTER TABLE events DETACH PARTITION events_<oldest>` then `DROP TABLE`: removes a whole month
  instantly.
- Compare with `DELETE FROM events WHERE created_at < ...`: millions of dead tuples, heavy WAL (and so
  replication traffic), long vacuum, bloat.
- `DETACH PARTITION ... CONCURRENTLY` avoids blocking queries but is **not allowed when a DEFAULT
  partition exists** (as here). Plain DETACH takes a brief ACCESS EXCLUSIVE lock.
- A detached partition is an ordinary table: archive it (pg_dump, export to S3) before dropping.
- Production: `pg_partman` (on RDS) creates future partitions and applies retention, scheduled by `pg_cron`.

### When to partition
- Yes: large time-series / append-mostly tables (tens of GB+), queries filter by time, you need
  cheap retention, or vacuum on one huge table is too slow.
- No: small tables, or queries that do not filter on the partition key. Partitioning adds planning
  overhead and constraints (unique keys must include the partition key).

---

## Step 5: Lab 03, vacuum and bloat (`sql/03_vacuum_bloat.sql`)

```bash
use_primary
psql -f /opt/dblab/sql/03_vacuum_bloat.sql | tee ~/lab03.txt
```

### The idea: MVCC
Postgres never overwrites a row. An UPDATE writes a new row version and marks the old one dead; a
DELETE only marks it dead. Readers see a consistent snapshot without locks, but dead rows pile up
until VACUUM removes them. Too many dead rows = **bloat** (bigger table, slower scans).

| # | What it shows | Look for |
|---|---|---|
| 1 | Update all 200k rows of `bloat_demo` (autovacuum off for the demo) | `n_dead_tup` ~200k, table size ~doubles |
| 2 | `VACUUM` vs `VACUUM FULL` | VACUUM: dead rows gone, **size unchanged** (space reused internally). A second update barely grows it. VACUUM FULL: size shrinks, but locks the table completely while it rewrites |
| 3 | HOT updates with fillfactor 100 vs 70 | fillfactor 70 -> ~100% HOT, fillfactor 100 -> ~0% HOT |
| 4 | Per-table autovacuum settings | global defaults, then `reloptions` on bloat_demo; the "most dead rows" list |
| 5 | Long transaction holding the xmin horizon (two windows) | "dead but not yet removable" until the other window commits |
| 6 | XID wraparound | `age(datfrozenxid)` and % to wraparound per database and per table |
| 7 | Vacuum progress | `pg_stat_progress_vacuum` phases and % scanned |

### Key concepts
- **VACUUM FULL / pg_repack**: FULL takes an ACCESS EXCLUSIVE lock for the whole rewrite (no reads or
  writes). pg_repack (on RDS) does the rewrite online with only brief locks.
- **HOT (heap-only tuple)**: when no indexed column changes and the new version fits on the same
  page, no index entries are written. `fillfactor` leaves free space on each page for this.
  Trade-off: bigger table, far fewer index writes on update-heavy tables.
- **Autovacuum defaults**: vacuum when dead rows > 50 + 20% of the table. On a 100M-row table that
  is 20M dead rows before anything happens, so lower the scale factor per table for big hot tables.
- **xmin horizon**: VACUUM cannot remove row versions that an open transaction might still see. One
  forgotten `BEGIN` (or idle-in-transaction app connection) stops cleanup database-wide. Also held
  by replication slots, prepared transactions, and replica queries with `hot_standby_feedback = on`.
  Guard rail: `idle_in_transaction_session_timeout`.
- **XID wraparound**: transaction IDs are 32-bit (~2 billion usable). Vacuum must freeze old rows
  before that, or Postgres stops accepting writes to protect data. Monitor `age(datfrozenxid)` and on
  RDS the CloudWatch metric `MaximumUsedTransactionIDs`.

### Section 5, two windows
- Window 2: `bash -l; use_primary; psql`, then
  `BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM bloat_demo;` (leave it open)
- Window 1 in psql: `UPDATE bloat_demo SET counter = counter + 1; VACUUM (VERBOSE) bloat_demo;`
  -> "... are dead but not yet removable, oldest xmin: ..."
- Window 2: `COMMIT;`
- Window 1: `VACUUM (VERBOSE) bloat_demo;` -> dead rows removed.

**Takeaway:** "MVCC gives lock-free reads at the cost of dead tuples. I tune autovacuum per
table for large hot tables, use fillfactor for HOT updates, hunt long transactions that pin the
xmin horizon, and alarm on transaction ID age."
