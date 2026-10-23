#!/usr/bin/env python3
"""Fit the hosted project's data dump (supabase db dump --data-only --use-copy) to the server's schema.

    filter-data.py DATA_SQL TARGET_JSON OUT_SQL REPORT_JSON

TARGET_JSON: {"tables": {"schema.table": ["col", ...]}, "sequences": ["schema.seq", ...]} read from the server after
its schema was restored. For every COPY block of the dump:
  - tables the copy handles itself are dropped: vault.secrets (re-created from the decrypted values, so they decrypt
    with the server's key), cron.* (jobs re-created paused, with the function URL changed), the services' own
    migration bookkeeping (auth.schema_migrations, storage.migrations, ...), pg_net's queues, realtime;
  - a table the server does not have is dropped and reported;
  - columns the server's table does not have (a newer hosted Auth or Storage) are dropped from every row and
    reported; columns only the server has keep their defaults.
setval() lines for sequences the server does not have, or of a dropped schema, are dropped. Everything else passes
through unchanged. Rows are never printed; the report has table names, column names and row counts only.
"""
import json
import re
import sys

SKIP_SCHEMAS = {"cron", "net", "realtime", "_realtime", "supabase_functions", "pgsodium", "pgsodium_masks", "graphql",
                "graphql_public", "_analytics", "_supavisor", "pgbouncer", "extensions"}
SKIP_TABLES = {"vault.secrets", "auth.schema_migrations", "storage.migrations", "storage.buckets_vectors",
               "storage.vector_indexes", "supabase_functions.migrations"}

COPY_RE = re.compile(r'^COPY\s+((?:"[^"]+"|[A-Za-z0-9_]+)\.(?:"[^"]+"|[A-Za-z0-9_]+))\s*\((.*)\)\s+FROM\s+stdin;\s*$')
SETVAL_RE = re.compile(r"setval\('((?:\"[^\"]+\"|[A-Za-z0-9_]+)\.(?:\"[^\"]+\"|[A-Za-z0-9_]+))'")


def unq(name):
    return ".".join(p[1:-1].replace('""', '"') if p.startswith('"') else p for p in re.findall(r'"(?:[^"]|"")*"|[^.]+', name))


def cols(spec):
    return [unq(c.strip()) for c in re.findall(r'"(?:[^"]|"")*"|[^,\s][^,]*', spec)]


def main():
    data_sql, target_json, out_sql, report_json = sys.argv[1:5]
    target = json.load(open(target_json))
    tables = {k: v for k, v in target.get("tables", {}).items()}
    sequences = set(target.get("sequences", []))
    report = {"tables_copied": 0, "rows_copied": 0, "rows": {}, "skipped_by_rule": {}, "missing_on_server": {},
              "columns_dropped": {}, "setval_dropped": []}
    with open(data_sql, encoding="utf-8", newline="") as f, open(out_sql, "w", encoding="utf-8", newline="") as out:
        mode, keep_idx, table, n = None, None, None, 0
        for line in f:
            if mode is not None:
                if line.rstrip("\r\n") == "\\.":
                    if mode == "copy":
                        out.write(line)
                        report["rows_copied"] += n
                        report["rows"][table] = report["rows"].get(table, 0) + n
                    elif mode == "skip-rule":
                        report["skipped_by_rule"][table] = n
                    else:
                        report["missing_on_server"][table] = n
                    mode, keep_idx, table, n = None, None, None, 0
                    continue
                n += 1
                if mode == "copy":
                    if keep_idx is None:
                        out.write(line)
                    else:
                        fields = line.rstrip("\n").split("\t")
                        out.write("\t".join(fields[i] for i in keep_idx) + "\n")
                continue
            m = COPY_RE.match(line)
            if m:
                table = unq(m.group(1))
                src_cols = cols(m.group(2))
                schema = table.split(".", 1)[0]
                if table in SKIP_TABLES or schema in SKIP_SCHEMAS:
                    mode = "skip-rule"
                    continue
                if table not in tables:
                    mode = "skip-missing"
                    continue
                have = set(tables[table])
                keep = [i for i, c in enumerate(src_cols) if c in have]
                if len(keep) != len(src_cols):
                    report["columns_dropped"][table] = [c for c in src_cols if c not in have]
                    keep_idx = keep
                    new_cols = ", ".join('"' + src_cols[i].replace('"', '""') + '"' for i in keep)
                    qt = ".".join('"' + p.replace('"', '""') + '"' for p in table.split(".", 1))
                    out.write(f"COPY {qt} ({new_cols}) FROM stdin;\n")
                else:
                    out.write(line)
                mode, n = "copy", 0
                report["tables_copied"] += 1
                continue
            s = SETVAL_RE.search(line)
            if s:
                seq = unq(s.group(1))
                if seq.split(".", 1)[0] in SKIP_SCHEMAS or seq not in sequences:
                    report["setval_dropped"].append(seq)
                    continue
            out.write(line)
        if mode is not None:
            sys.exit("filter-data: the dump ends inside a COPY block (truncated?)")
    json.dump(report, open(report_json, "w"), indent=1, sort_keys=True)
    print(json.dumps({k: (v if isinstance(v, int) else len(v)) for k, v in report.items()}))


if __name__ == "__main__":
    main()
