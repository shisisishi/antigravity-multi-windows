import argparse
import os
import shutil
import sqlite3
import sys


def backup_sqlite(src_path: str, dst_path: str) -> None:
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    tmp_path = dst_path + ".tmp"
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


def export_main(main_agy: str, seed_dir: str) -> None:
    os.makedirs(seed_dir, exist_ok=True)
    seed_convs = os.path.join(seed_dir, "conversations")
    os.makedirs(seed_convs, exist_ok=True)

    src_sum = os.path.join(main_agy, "conversation_summaries.db")
    if os.path.isfile(src_sum):
        backup_sqlite(src_sum, os.path.join(seed_dir, "conversation_summaries.db"))

    src_conv_dir = os.path.join(main_agy, "conversations")
    backed_up = 0
    failed = 0
    if os.path.isdir(src_conv_dir):
        for name in os.listdir(src_conv_dir):
            if not name.endswith(".db"):
                continue
            sp = os.path.join(src_conv_dir, name)
            dp = os.path.join(seed_convs, name)
            try:
                backup_sqlite(sp, dp)
                backed_up += 1
            except Exception as exc:
                failed += 1
                print(f"WARN: failed backup {name}: {exc}", file=sys.stderr)

    proto = os.path.join(main_agy, "agyhub_summaries_proto.pb")
    if os.path.isfile(proto):
        shutil.copy2(proto, os.path.join(seed_dir, "agyhub_summaries_proto.pb"))

    ann_src = os.path.join(main_agy, "annotations")
    ann_dst = os.path.join(seed_dir, "annotations")
    if os.path.isdir(ann_src):
        if os.path.exists(ann_dst):
            shutil.rmtree(ann_dst)
        shutil.copytree(ann_src, ann_dst)

    print(f"EXPORT_OK|convs={backed_up}|failed={failed}")


def merge_sub(seed_dir: str, sub_agy: str) -> None:
    os.makedirs(sub_agy, exist_ok=True)
    sub_convs = os.path.join(sub_agy, "conversations")
    os.makedirs(sub_convs, exist_ok=True)

    seed_sum = os.path.join(seed_dir, "conversation_summaries.db")
    sub_sum = os.path.join(sub_agy, "conversation_summaries.db")

    seed_times = {}
    if os.path.isfile(seed_sum):
        sc = sqlite3.connect(seed_sum)
        try:
            for cid, lmt in sc.execute("SELECT conversation_id, last_modified_time FROM conversation_summaries"):
                seed_times[cid] = lmt or ""
        finally:
            sc.close()

    sub_times = {}
    sub_has_rows = False
    if os.path.isfile(sub_sum):
        dc = sqlite3.connect(sub_sum)
        try:
            for cid, lmt in dc.execute("SELECT conversation_id, last_modified_time FROM conversation_summaries"):
                sub_times[cid] = lmt or ""
                sub_has_rows = True
        except Exception:
            sub_has_rows = False
        finally:
            dc.close()

    seed_convs = os.path.join(seed_dir, "conversations")
    copied = 0
    skipped = 0
    if os.path.isdir(seed_convs):
        for name in os.listdir(seed_convs):
            if not name.endswith(".db"):
                continue
            cid = name[:-3]
            sp = os.path.join(seed_convs, name)
            dp = os.path.join(sub_convs, name)
            need_copy = False
            if not os.path.isfile(dp):
                need_copy = True
            elif cid in seed_times and seed_times[cid] > sub_times.get(cid, ""):
                need_copy = True
            if need_copy:
                for suf in ("-wal", "-shm"):
                    if os.path.exists(dp + suf):
                        try:
                            os.remove(dp + suf)
                        except OSError:
                            pass
                shutil.copy2(sp, dp)
                copied += 1
            else:
                skipped += 1

    merged_rows = 0
    if os.path.isfile(seed_sum):
        if not sub_has_rows:
            for suf in ("-wal", "-shm"):
                if os.path.exists(sub_sum + suf):
                    try:
                        os.remove(sub_sum + suf)
                    except OSError:
                        pass
            shutil.copy2(seed_sum, sub_sum)
            merged_rows = len(seed_times)
        else:
            con = sqlite3.connect(sub_sum, timeout=15.0)
            try:
                con.execute("ATTACH DATABASE ? AS seeddb", (seed_sum,))
                to_upsert = [
                    cid for cid, lmt in seed_times.items()
                    if cid not in sub_times or lmt > sub_times.get(cid, "")
                ]
                for cid in to_upsert:
                    con.execute("DELETE FROM main.conversation_summaries WHERE conversation_id = ?", (cid,))
                    con.execute("INSERT INTO main.conversation_summaries SELECT * FROM seeddb.conversation_summaries WHERE conversation_id = ?", (cid,))
                    con.execute("DELETE FROM main.conversation_parents WHERE conversation_id = ?", (cid,))
                    con.execute("INSERT INTO main.conversation_parents SELECT * FROM seeddb.conversation_parents WHERE conversation_id = ?", (cid,))
                    try:
                        con.execute("DELETE FROM main.conversations_fts WHERE conversation_id = ?", (cid,))
                        con.execute("INSERT INTO main.conversations_fts SELECT * FROM seeddb.conversations_fts WHERE conversation_id = ?", (cid,))
                    except Exception:
                        pass
                    merged_rows += 1
                con.commit()
                con.execute("DETACH DATABASE seeddb")
            finally:
                con.close()

    seed_proto = os.path.join(seed_dir, "agyhub_summaries_proto.pb")
    sub_proto = os.path.join(sub_agy, "agyhub_summaries_proto.pb")
    if os.path.isfile(seed_proto) and not os.path.isfile(sub_proto):
        shutil.copy2(seed_proto, sub_proto)

    ann_src = os.path.join(seed_dir, "annotations")
    ann_dst = os.path.join(sub_agy, "annotations")
    if os.path.isdir(ann_src):
        os.makedirs(ann_dst, exist_ok=True)
        for name in os.listdir(ann_src):
            sp = os.path.join(ann_src, name)
            dp = os.path.join(ann_dst, name)
            if os.path.isfile(sp) and not os.path.isfile(dp):
                shutil.copy2(sp, dp)

    print(f"MERGE_OK|convsCopied={copied}|convsSkipped={skipped}|summariesMerged={merged_rows}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Hot-backup and incrementally merge Google Antigravity SQLite conversation history."
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("export-main")
    p1.add_argument("--main-antigravity", required=True)
    p1.add_argument("--seed-dir", required=True)

    p2 = sub.add_parser("merge-sub")
    p2.add_argument("--seed-dir", required=True)
    p2.add_argument("--sub-antigravity", required=True)

    args = parser.parse_args()
    if args.cmd == "export-main":
        export_main(args.main_antigravity, args.seed_dir)
    elif args.cmd == "merge-sub":
        merge_sub(args.seed_dir, args.sub_antigravity)
    return 0


if __name__ == "__main__":
    sys.exit(main())
