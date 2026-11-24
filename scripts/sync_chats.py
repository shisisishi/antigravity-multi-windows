import argparse
import os
import shutil
import sqlite3
import sys
import time
from contextlib import contextmanager


@contextmanager
def pool_lock(pool_dir: str, timeout_sec: float = 20.0):
    os.makedirs(pool_dir, exist_ok=True)
    lock_path = os.path.join(pool_dir, ".sync.lock")
    deadline = time.time() + timeout_sec
    fd = None
    while True:
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_RDWR)
            os.write(fd, f"{os.getpid()}|{time.time()}".encode("utf-8"))
            break
        except FileExistsError:
            # Break stale locks older than 5 minutes
            try:
                if time.time() - os.path.getmtime(lock_path) > 300:
                    os.remove(lock_path)
                    continue
            except OSError:
                pass
            if time.time() >= deadline:
                raise TimeoutError(f"Timed out waiting for sync pool lock: {lock_path}")
            time.sleep(0.2)
    try:
        yield
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.remove(lock_path)
        except OSError:
            pass


def backup_sqlite(src_path: str, dst_path: str) -> None:
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    tmp_path = dst_path + f".{os.getpid()}.tmp"
    if os.path.exists(tmp_path):
        os.remove(tmp_path)
    src_uri = "file:" + src_path.replace("\\", "/") + "?mode=ro&immutable=0"
    try:
        src_con = sqlite3.connect(src_uri, uri=True, timeout=10.0)
    except Exception:
        src_con = sqlite3.connect(src_path, timeout=10.0)
    dst_con = sqlite3.connect(tmp_path)
    try:
        src_con.backup(dst_con)
        dst_con.commit()
    finally:
        dst_con.close()
        src_con.close()
    if os.path.exists(dst_path):
        os.remove(dst_path)
    os.replace(tmp_path, dst_path)


def read_summary_times(db_path: str) -> dict:
    if not os.path.isfile(db_path):
        return {}
    uri = "file:" + db_path.replace("\\", "/") + "?mode=ro&immutable=0"
    try:
        con = sqlite3.connect(uri, uri=True, timeout=10.0)
    except Exception:
        con = sqlite3.connect(db_path, timeout=10.0)
    result = {}
    try:
        for cid, lmt in con.execute("SELECT conversation_id, last_modified_time FROM conversation_summaries"):
            result[cid] = lmt or ""
    except Exception:
        result = {}
    finally:
        con.close()
    return result


def sync_brain_dirs(src_brain: str, dst_brain: str, cids: list) -> int:
    if not os.path.isdir(src_brain):
        return 0
    copied_files = 0
    for cid in cids:
        sdir = os.path.join(src_brain, cid)
        if not os.path.isdir(sdir):
            continue
        ddir = os.path.join(dst_brain, cid)
        for root, dirs, files in os.walk(sdir):
            dirs[:] = [d for d in dirs if d != "browser_sandbox"]
            rel = os.path.relpath(root, sdir)
            troot = ddir if rel == "." else os.path.join(ddir, rel)
            os.makedirs(troot, exist_ok=True)
            for fn in files:
                sp = os.path.join(root, fn)
                dp = os.path.join(troot, fn)
                try:
                    sst = os.stat(sp)
                    if os.path.isfile(dp):
                        dst_st = os.stat(dp)
                        if dst_st.st_size == sst.st_size and dst_st.st_mtime >= sst.st_mtime - 1.0:
                            continue
                    shutil.copy2(sp, dp)
                    copied_files += 1
                except OSError:
                    pass
    return copied_files


def sync_annotations(src_ann: str, dst_ann: str) -> int:
    if not os.path.isdir(src_ann):
        return 0
    os.makedirs(dst_ann, exist_ok=True)
    copied = 0
    for name in os.listdir(src_ann):
        sp = os.path.join(src_ann, name)
        dp = os.path.join(dst_ann, name)
        if not os.path.isfile(sp):
            continue
        try:
            if not os.path.isfile(dp) or os.path.getmtime(sp) > os.path.getmtime(dp) + 1.0:
                shutil.copy2(sp, dp)
                copied += 1
        except OSError:
            pass
    return copied


def atomic_copy_file(src_path: str, dst_path: str) -> None:
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    tmp_path = dst_path + f".{os.getpid()}.tmp"
    try:
        shutil.copy2(src_path, tmp_path)
        os.replace(tmp_path, dst_path)
    except Exception:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass
        raise


def is_db_recently_active(db_path: str, cooldown_sec: int = 90) -> bool:
    if not os.path.isfile(db_path):
        return False
    now = time.time()
    wal = db_path + "-wal"
    shm = db_path + "-shm"
    try:
        if os.path.isfile(wal) and os.path.getsize(wal) > 0:
            return True
    except OSError:
        return True
    latest = 0.0
    for p in (db_path, wal, shm):
        try:
            if os.path.isfile(p):
                mt = os.path.getmtime(p)
                if mt > latest:
                    latest = mt
        except OSError:
            pass
    return (now - latest) < cooldown_sec


def merge_summaries_db(src_sum_snapshot: str, dst_sum: str, target_cids: list, live_safe: bool = False) -> int:
    if not os.path.isfile(src_sum_snapshot):
        return 0
    dst_existing = read_summary_times(dst_sum)
    if not dst_existing:
        if live_safe and os.path.isfile(dst_sum):
            return 0
        for suf in ("-wal", "-shm"):
            if os.path.exists(dst_sum + suf):
                try:
                    os.remove(dst_sum + suf)
                except OSError:
                    pass
        os.makedirs(os.path.dirname(dst_sum), exist_ok=True)
        atomic_copy_file(src_sum_snapshot, dst_sum)
        return len(read_summary_times(dst_sum))

    if not target_cids:
        return 0

    con = sqlite3.connect(dst_sum, timeout=15.0, isolation_level=None)
    merged = 0
    try:
        con.execute("PRAGMA busy_timeout = 15000")
        con.execute("ATTACH DATABASE ? AS srcdb", (src_sum_snapshot,))
        backoffs = (0.3, 0.7, 1.5, 2.5) if live_safe else (0.5,)
        last_err = None
        for attempt in range(len(backoffs) + 1):
            merged = 0
            try:
                con.execute("BEGIN IMMEDIATE")
                for cid in target_cids:
                    con.execute("DELETE FROM main.conversation_summaries WHERE conversation_id = ?", (cid,))
                    con.execute("INSERT INTO main.conversation_summaries SELECT * FROM srcdb.conversation_summaries WHERE conversation_id = ?", (cid,))
                    con.execute("DELETE FROM main.conversation_parents WHERE conversation_id = ?", (cid,))
                    con.execute("INSERT INTO main.conversation_parents SELECT * FROM srcdb.conversation_parents WHERE conversation_id = ?", (cid,))
                    try:
                        con.execute("DELETE FROM main.conversations_fts WHERE conversation_id = ?", (cid,))
                        con.execute("INSERT INTO main.conversations_fts SELECT * FROM srcdb.conversations_fts WHERE conversation_id = ?", (cid,))
                    except Exception:
                        pass
                    merged += 1
                con.execute("COMMIT")
                last_err = None
                break
            except sqlite3.OperationalError as exc:
                last_err = exc
                try:
                    con.execute("ROLLBACK")
                except Exception:
                    pass
                if attempt < len(backoffs) and ("locked" in str(exc).lower() or "busy" in str(exc).lower()):
                    time.sleep(backoffs[attempt])
                    continue
                raise
        if last_err is not None:
            raise last_err
        if live_safe:
            try:
                con.execute("PRAGMA wal_checkpoint(PASSIVE)")
            except Exception:
                pass
        con.execute("DETACH DATABASE srcdb")
    finally:
        con.close()
    return merged


def pull_to_pool(account_agy: str, pool_dir: str, sync_brain: bool = True) -> None:
    """Safe read-only online hot-backup from an account (even while running!) into shared sync_pool."""
    src_sum = os.path.join(account_agy, "conversation_summaries.db")
    src_convs = os.path.join(account_agy, "conversations")
    if not os.path.isfile(src_sum) and not os.path.isdir(src_convs):
        print("PULL_OK|updatedConvs=0|mergedSummaries=0|brainFiles=0")
        return

    with pool_lock(pool_dir):
        pool_convs = os.path.join(pool_dir, "conversations")
        os.makedirs(pool_convs, exist_ok=True)
        pool_sum = os.path.join(pool_dir, "conversation_summaries.db")

        src_times = read_summary_times(src_sum)
        pool_times = read_summary_times(pool_sum)

        # Find summary rows strictly newer in account or missing in pool
        newer_summary_cids = [
            cid for cid, lmt in src_times.items()
            if cid not in pool_times or lmt > pool_times.get(cid, "")
        ]

        # Also catch any standalone .db in conversations/ missing from pool or newer mtime
        cids_to_backup = set(newer_summary_cids)
        if os.path.isdir(src_convs):
            for name in os.listdir(src_convs):
                if not name.endswith(".db"):
                    continue
                cid = name[:-3]
                sp = os.path.join(src_convs, name)
                dp = os.path.join(pool_convs, name)
                if not os.path.isfile(dp):
                    cids_to_backup.add(cid)
                elif cid in newer_summary_cids:
                    cids_to_backup.add(cid)
                else:
                    # Check if WAL file was updated more recently than pool copy
                    wal = sp + "-wal"
                    src_mtime = max(os.path.getmtime(sp), os.path.getmtime(wal) if os.path.isfile(wal) else 0)
                    if src_mtime > os.path.getmtime(dp) + 2.0 and cid not in pool_times:
                        cids_to_backup.add(cid)

        updated_convs = 0
        for cid in sorted(cids_to_backup):
            sp = os.path.join(src_convs, cid + ".db")
            dp = os.path.join(pool_convs, cid + ".db")
            if os.path.isfile(sp):
                try:
                    backup_sqlite(sp, dp)
                    updated_convs += 1
                except Exception as exc:
                    print(f"WARN: pull backup {cid} failed: {exc}", file=sys.stderr)

        merged_summaries = 0
        if os.path.isfile(src_sum) and (newer_summary_cids or not os.path.isfile(pool_sum)):
            snap = os.path.join(pool_dir, f".pull_sum_{os.getpid()}.db")
            try:
                backup_sqlite(src_sum, snap)
                merged_summaries = merge_summaries_db(snap, pool_sum, newer_summary_cids)
            finally:
                if os.path.exists(snap):
                    try:
                        os.remove(snap)
                    except OSError:
                        pass

        proto_src = os.path.join(account_agy, "agyhub_summaries_proto.pb")
        proto_dst = os.path.join(pool_dir, "agyhub_summaries_proto.pb")
        if os.path.isfile(proto_src) and not os.path.isfile(proto_dst):
            shutil.copy2(proto_src, proto_dst)

        sync_annotations(os.path.join(account_agy, "annotations"), os.path.join(pool_dir, "annotations"))

        brain_files = 0
        if sync_brain:
            src_brain = os.path.join(account_agy, "brain")
            pool_brain = os.path.join(pool_dir, "brain")
            # Sync brain dirs for updated cids + any missing cid dirs
            brain_cids = set(cids_to_backup)
            if os.path.isdir(src_brain):
                for d in os.listdir(src_brain):
                    if os.path.isdir(os.path.join(src_brain, d)) and not os.path.isdir(os.path.join(pool_brain, d)):
                        brain_cids.add(d)
            if brain_cids:
                brain_files = sync_brain_dirs(src_brain, pool_brain, sorted(brain_cids))

        print(f"PULL_OK|updatedConvs={updated_convs}|mergedSummaries={merged_summaries}|brainFiles={brain_files}")


def push_from_pool(
    pool_dir: str,
    account_agy: str,
    sync_brain: bool = True,
    live_safe: bool = False,
    active_cooldown: int = 90,
) -> None:
    """Incrementally push newer conversations from shared sync_pool into an idle or live-running account."""
    pool_sum = os.path.join(pool_dir, "conversation_summaries.db")
    pool_convs = os.path.join(pool_dir, "conversations")
    if not os.path.isfile(pool_sum) and not os.path.isdir(pool_convs):
        if live_safe:
            print("PUSH_LIVE_OK|convsCopied=0|skippedActive=0|summariesMerged=0|brainFiles=0")
        else:
            print("PUSH_OK|convsCopied=0|summariesMerged=0|brainFiles=0")
        return

    with pool_lock(pool_dir):
        os.makedirs(account_agy, exist_ok=True)
        dst_convs = os.path.join(account_agy, "conversations")
        os.makedirs(dst_convs, exist_ok=True)
        dst_sum = os.path.join(account_agy, "conversation_summaries.db")

        pool_times = read_summary_times(pool_sum)
        dst_times = read_summary_times(dst_sum)

        newer_cids = [
            cid for cid, lmt in pool_times.items()
            if cid not in dst_times or lmt > dst_times.get(cid, "")
        ]

        cids_to_copy = set(newer_cids)
        if os.path.isdir(pool_convs):
            for name in os.listdir(pool_convs):
                if not name.endswith(".db"):
                    continue
                cid = name[:-3]
                if not os.path.isfile(os.path.join(dst_convs, name)):
                    cids_to_copy.add(cid)

        convs_copied = 0
        skipped_active = 0
        skipped_cids = set()
        for cid in sorted(cids_to_copy):
            sp = os.path.join(pool_convs, cid + ".db")
            dp = os.path.join(dst_convs, cid + ".db")
            if not os.path.isfile(sp):
                continue
            if live_safe:
                if os.path.isfile(dp) and is_db_recently_active(dp, active_cooldown):
                    skipped_active += 1
                    skipped_cids.add(cid)
                    continue
                try:
                    atomic_copy_file(sp, dp)
                    convs_copied += 1
                except OSError:
                    skipped_active += 1
                    skipped_cids.add(cid)
                    continue
            else:
                for suf in ("-wal", "-shm"):
                    if os.path.exists(dp + suf):
                        try:
                            os.remove(dp + suf)
                        except OSError:
                            pass
                atomic_copy_file(sp, dp)
                convs_copied += 1

        summaries_to_merge = [
            cid for cid in newer_cids
            if cid not in skipped_cids and (
                os.path.isfile(os.path.join(dst_convs, cid + ".db"))
                or not os.path.isfile(os.path.join(pool_convs, cid + ".db"))
            )
        ]

        summaries_merged = 0
        if os.path.isfile(pool_sum) and (summaries_to_merge or (not live_safe and not os.path.isfile(dst_sum))):
            try:
                summaries_merged = merge_summaries_db(pool_sum, dst_sum, summaries_to_merge, live_safe=live_safe)
            except sqlite3.OperationalError as exc:
                if live_safe:
                    print(f"WARN: live summary merge busy: {exc}", file=sys.stderr)
                else:
                    raise

        proto_src = os.path.join(pool_dir, "agyhub_summaries_proto.pb")
        proto_dst = os.path.join(account_agy, "agyhub_summaries_proto.pb")
        if os.path.isfile(proto_src) and not os.path.isfile(proto_dst):
            try:
                atomic_copy_file(proto_src, proto_dst)
            except OSError:
                pass

        sync_annotations(os.path.join(pool_dir, "annotations"), os.path.join(account_agy, "annotations"))

        brain_files = 0
        if sync_brain:
            pool_brain = os.path.join(pool_dir, "brain")
            dst_brain = os.path.join(account_agy, "brain")
            brain_cids = set(cid for cid in cids_to_copy if cid not in skipped_cids)
            if os.path.isdir(pool_brain):
                for d in os.listdir(pool_brain):
                    if d not in skipped_cids and os.path.isdir(os.path.join(pool_brain, d)) and not os.path.isdir(os.path.join(dst_brain, d)):
                        brain_cids.add(d)
            if brain_cids:
                brain_files = sync_brain_dirs(pool_brain, dst_brain, sorted(brain_cids))

        if live_safe:
            print(
                f"PUSH_LIVE_OK|convsCopied={convs_copied}|skippedActive={skipped_active}"
                f"|summariesMerged={summaries_merged}|brainFiles={brain_files}"
            )
        else:
            print(f"PUSH_OK|convsCopied={convs_copied}|summariesMerged={summaries_merged}|brainFiles={brain_files}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Incremental SQLite hot-backup and bidirectional merge for Google Antigravity."
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_pull = sub.add_parser("pull")
    p_pull.add_argument("--account-antigravity", required=True)
    p_pull.add_argument("--pool-dir", required=True)
    p_pull.add_argument("--no-brain", action="store_true")

    p_push = sub.add_parser("push")
    p_push.add_argument("--pool-dir", required=True)
    p_push.add_argument("--account-antigravity", required=True)
    p_push.add_argument("--no-brain", action="store_true")
    p_push.add_argument("--live-safe", action="store_true", help="Safe incremental push while Antigravity is running (skips active/locked conv DBs, WAL-safe summary merge)")
    p_push.add_argument("--active-cooldown", type=int, default=90, help="Skip existing conv DBs modified within N seconds in --live-safe mode")

    # Legacy aliases for backwards compatibility
    p_exp = sub.add_parser("export-main")
    p_exp.add_argument("--main-antigravity", required=True)
    p_exp.add_argument("--seed-dir", required=True)

    p_mrg = sub.add_parser("merge-sub")
    p_mrg.add_argument("--seed-dir", required=True)
    p_mrg.add_argument("--sub-antigravity", required=True)

    args = parser.parse_args()
    if args.cmd == "pull":
        pull_to_pool(args.account_antigravity, args.pool_dir, sync_brain=not args.no_brain)
    elif args.cmd == "push":
        push_from_pool(
            args.pool_dir,
            args.account_antigravity,
            sync_brain=not args.no_brain,
            live_safe=args.live_safe,
            active_cooldown=args.active_cooldown,
        )
    elif args.cmd == "export-main":
        pull_to_pool(args.main_antigravity, args.seed_dir, sync_brain=False)
    elif args.cmd == "merge-sub":
        push_from_pool(args.seed_dir, args.sub_antigravity, sync_brain=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
