#!/usr/bin/env python3
"""
Seed VimText with N synthetic notes for scale/perf testing — no UI automation.

VimText stores each note as a `<name>.json` (NoteMetadata) + a `<name>.txt`
sidecar in its notes directory. The app loads every json/txt pair it finds and
reads the title/dates/etc. from the json's metadata, so filenames don't matter
beyond uniqueness. This writes those pairs directly.

The notes directory is:
  - <customNotesDirectoryPath>/notes   if the `customNotesDirectoryPath`
    UserDefault is set for com.vimtext.app, else
  - ~/Library/Application Support/VimText/notes

All seeded files are prefixed `scale-` so `--clean` can remove only them and
leave your real notes untouched.

Usage:
  python3 scripts/seed-notes.py --count 2000      # create 2000 notes
  python3 scripts/seed-notes.py --count 2000 --clean-first
  python3 scripts/seed-notes.py --clean           # delete only scale-* notes
  python3 scripts/seed-notes.py --dir /path/to/notes --count 500
"""
import argparse, json, os, random, subprocess, sys, uuid
from datetime import datetime, timedelta, timezone

PREFIX = "scale-"
WORDS = ("vim motion buffer register macro yank delete normal insert visual "
         "command line cursor search replace fold mark jump undo redo paste "
         "indent textobject paragraph sentence word column block escape colon "
         "swift appkit textkit nstextview storage perf latency render layout").split()


def resolve_notes_dir():
    custom = None
    try:
        out = subprocess.run(
            ["defaults", "read", "com.vimtext.app", "customNotesDirectoryPath"],
            capture_output=True, text=True)
        if out.returncode == 0:
            custom = out.stdout.strip()
    except Exception:
        pass
    if custom:
        return os.path.join(custom, "notes")
    return os.path.expanduser(
        "~/Library/Application Support/VimText/notes")


def paragraph(n_words):
    ws = [random.choice(WORDS) for _ in range(n_words)]
    ws[0] = ws[0].capitalize()
    text, line, width = [], [], 0
    for w in ws:
        line.append(w)
        width += len(w) + 1
        if width > 70:
            text.append(" ".join(line) + ".")
            line, width = [], 0
    if line:
        text.append(" ".join(line) + ".")
    return "\n".join(text)


def make_body(i):
    # Vary size: most small/medium, ~5% large, ~1% huge — to stress line
    # numbers, navigation, search and rendering across realistic spread.
    r = random.random()
    if r < 0.01:
        paras = random.randint(400, 1200)   # huge: thousands of lines
    elif r < 0.06:
        paras = random.randint(40, 120)
    else:
        paras = random.randint(2, 12)
    title = f"Scale note {i:05d}"
    blocks = [f"# {title}", ""]
    for _ in range(paras):
        blocks.append(paragraph(random.randint(15, 60)))
        blocks.append("")
    return title, "\n".join(blocks)


def seed(notes_dir, count):
    os.makedirs(notes_dir, exist_ok=True)
    base = datetime.now(timezone.utc) - timedelta(days=count)
    for i in range(count):
        nid = str(uuid.uuid4()).upper()
        created = base + timedelta(minutes=i)
        iso = created.strftime("%Y-%m-%dT%H:%M:%SZ")
        title, body = make_body(i)
        meta = {
            "id": nid, "title": title,
            "createdAt": iso, "modifiedAt": iso,
            "isPinned": False, "isLocked": False, "rtfInSync": False,
        }
        stem = os.path.join(notes_dir, f"{PREFIX}{i:05d}")
        with open(stem + ".json", "w") as f:
            json.dump(meta, f, indent=2, sort_keys=True)
        with open(stem + ".txt", "w") as f:
            f.write(body)
        if (i + 1) % 200 == 0:
            print(f"  ...{i + 1}/{count}")
    print(f"Seeded {count} notes into {notes_dir}")


def clean(notes_dir):
    if not os.path.isdir(notes_dir):
        print(f"No such dir: {notes_dir}")
        return
    removed = 0
    for name in os.listdir(notes_dir):
        if name.startswith(PREFIX):
            os.remove(os.path.join(notes_dir, name))
            removed += 1
    print(f"Removed {removed} scale-* files from {notes_dir}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=2000)
    ap.add_argument("--dir", default=None, help="notes dir (auto-detected if omitted)")
    ap.add_argument("--clean", action="store_true", help="delete scale-* notes and exit")
    ap.add_argument("--clean-first", action="store_true", help="delete scale-* notes before seeding")
    args = ap.parse_args()

    notes_dir = args.dir or resolve_notes_dir()
    print(f"Notes dir: {notes_dir}")

    if args.clean:
        clean(notes_dir)
        return
    if args.clean_first:
        clean(notes_dir)
    seed(notes_dir, args.count)


if __name__ == "__main__":
    main()
