#!/usr/bin/env python3
# vi: ft=python
"""Scope and enumerate the files for a "everything not gitignored + every
.git/" backup of a target directory.

Two output modes:
  - default        — human-readable size report.
  - --print0       — file list, NUL-separated, paths relative to <target>.
                     Suitable for `rsync --files-from=- --from0 ...`.

Discovery: walks <target>. Every directory containing a `.git` entry
is a git worktree. The `.git` ENTRY type tells us how to size/list it:
  - `.git` is a directory → on-disk gitdir; include every file in it.
  - `.git` is a file      → submodule pointer; the resolved gitdir
                             lives at <parent>/.git/modules/<name>/,
                             which is already covered by the parent's
                             .git/. Skip the pointer itself for sizing
                             (the working tree files come via ls-files).

Per worktree, files-to-back-up are `git ls-files --cached --stage`
with submodule entries (mode 160000) filtered out, plus
`git ls-files --others --exclude-standard`. We rely on git's own
output rather than parsing .gitmodules.

--exclude <relpath> (repeatable): skip any worktree whose path
relative to <target> equals <relpath> or starts with <relpath>/.
Skipping a worktree skips both its files and its on-disk .git/.

Examples:
  # Size report
  ssh amun 'python3 - /home/pippijn/code/kubes/vps/toktok/workspace' < backup_preview.py

  # File list for rsync --files-from
  ssh amun 'python3 - --print0 --exclude tools/toktok-fuzzer \\
              /home/pippijn/code/kubes/vps/toktok/workspace' < backup_preview.py \\
    | rsync -av --from0 --files-from=- amun:.../workspace/ /local/staging/
"""

import argparse
import os
import subprocess
import sys
from typing import TypedDict


class WorktreeInfo(TypedDict):
    abs: str
    rel: str
    is_local_dir: bool
    wt_files: list[tuple[str, int]]
    gd_files: list[tuple[str, int]]


SUBMODULE_MODE = "160000"  # git's gitlink mode


def human(n: float) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def safe_size(path: str) -> int:
    try:
        return os.lstat(path).st_size
    except OSError:
        return 0


def git_run(repo: str, *args: str) -> bytes:
    try:
        out = subprocess.run(
            ["git", "-C", repo, *args],
            capture_output=True, check=True,
        )
        return out.stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return b""


def list_files(repo: str) -> list[str]:
    """Files to back up for this worktree: tracked-non-submodule +
    untracked-not-ignored. Submodule paths are filtered out by mode
    160000 in ls-files --stage; their contents are accounted for when
    discovery recurses into them as their own worktree."""
    files: list[str] = []

    cached = git_run(repo, "ls-files", "--cached", "--stage", "-z")
    for entry in cached.decode("utf-8", errors="replace").split("\0"):
        if not entry:
            continue
        # Format: "<mode> <oid> <stage>\t<path>"
        meta, _, path = entry.partition("\t")
        mode = meta.split(" ", 1)[0]
        if mode != SUBMODULE_MODE:
            files.append(path)

    others = git_run(repo, "ls-files", "--others", "--exclude-standard", "-z")
    files.extend(n for n in others.decode("utf-8", errors="replace").split("\0") if n)
    return files


def walk_files(path: str) -> list[str]:
    """All file paths under <path>, absolute."""
    result: list[str] = []
    for root, _dirs, files in os.walk(path, followlinks=False):
        for f in files:
            result.append(os.path.join(root, f))
    return result


def discover_worktrees(target: str) -> list[tuple[str, bool]]:
    """Walk target's tree, return [(worktree_path, gitdir_is_local_dir), ...]."""
    results: list[tuple[str, bool]] = []
    for root, dirs, files in os.walk(target, followlinks=False):
        if ".git" in dirs:
            results.append((root, True))
            dirs.remove(".git")  # don't descend into the gitdir
        elif ".git" in files:
            results.append((root, False))
    return results


def relpath_under(target: str, path: str) -> str:
    """Path relative to target; '' if path == target."""
    abs_path = os.path.abspath(path)
    abs_target = os.path.abspath(target)
    if abs_path == abs_target:
        return ""
    return os.path.relpath(abs_path, abs_target)


def is_excluded(rel_path: str, exclude_paths: list[str]) -> bool:
    for ex in exclude_paths:
        if rel_path == ex or rel_path.startswith(ex + os.sep):
            return True
    return False


def collect(target: str, exclude_paths: list[str]) -> list[WorktreeInfo]:
    """Per-worktree info, filtered by exclude rules. Each entry:
      { 'abs': str, 'rel': str, 'is_local_dir': bool,
        'wt_files': [(abs, size)], 'gd_files': [(abs, size)] }"""
    target = os.path.abspath(target)
    out: list[WorktreeInfo] = []
    for wt_abs, is_local_dir in discover_worktrees(target):
        wt_rel = relpath_under(target, wt_abs) or os.path.basename(target)
        # Exclusion key: '' (the target itself) is never excluded;
        # use relative path against target.
        check_rel = relpath_under(target, wt_abs)
        if check_rel and is_excluded(check_rel, exclude_paths):
            continue

        wt_files = []
        for f in list_files(wt_abs):
            full = os.path.join(wt_abs, f)
            wt_files.append((full, safe_size(full)))

        gd_files: list[tuple[str, int]] = []
        if is_local_dir:
            gitdir = os.path.join(wt_abs, ".git")
            for full in walk_files(gitdir):
                gd_files.append((full, safe_size(full)))

        out.append({
            "abs": wt_abs,
            "rel": wt_rel,
            "is_local_dir": is_local_dir,
            "wt_files": wt_files,
            "gd_files": gd_files,
        })
    return out


def render_report(target: str, data: list[WorktreeInfo]) -> None:
    print(f"Backup preview for {target}\n")

    repo_rows = []
    gd_rows = []
    for d in data:
        wt_count = len(d["wt_files"])
        wt_size = sum(s for _, s in d["wt_files"])
        repo_rows.append((d["rel"], wt_count, wt_size))
        if d["is_local_dir"]:
            gd_count = len(d["gd_files"])
            gd_size = sum(s for _, s in d["gd_files"])
            gd_rows.append((os.path.join(d["rel"], ".git") if d["rel"] != os.path.basename(target) else ".git", gd_count, gd_size))

    repo_rows.sort(key=lambda x: x[2], reverse=True)
    gd_rows.sort(key=lambda x: x[2], reverse=True)

    print("Working trees (tracked-non-submodule + untracked-not-ignored, per repo):")
    print(f"  {'label':<42} {'files':>8} {'size':>12}")
    for label, cnt, sz in repo_rows:
        print(f"  {label:<42} {cnt:>8} {human(sz):>12}")
    print()

    print("Gitdirs (on-disk .git/ dirs — submodule gitdirs are included via parent's .git/):")
    print(f"  {'label':<42} {'files':>8} {'size':>12}")
    for label, cnt, sz in gd_rows:
        print(f"  {label:<42} {cnt:>8} {human(sz):>12}")
    print()

    wt_files = sum(c for _, c, _ in repo_rows)
    wt_size = sum(s for _, _, s in repo_rows)
    gd_files = sum(c for _, c, _ in gd_rows)
    gd_size = sum(s for _, _, s in gd_rows)
    print(f"Working trees: {wt_files:>7} files, {human(wt_size):>10}")
    print(f"Gitdirs:       {gd_files:>7} files, {human(gd_size):>10}")
    print(f"TOTAL:         {wt_files + gd_files:>7} files, {human(wt_size + gd_size):>10}")


def render_print0(target: str, data: list[WorktreeInfo]) -> None:
    target = os.path.abspath(target)
    out = sys.stdout.buffer
    for d in data:
        for full, _ in d["wt_files"]:
            rel = os.path.relpath(full, target)
            out.write(rel.encode("utf-8") + b"\0")
        for full, _ in d["gd_files"]:
            rel = os.path.relpath(full, target)
            out.write(rel.encode("utf-8") + b"\0")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", help="Directory to scope")
    ap.add_argument("--print0", action="store_true",
                    help="Emit file paths (NUL-separated, relative to target) instead of a size report")
    ap.add_argument("--exclude", action="append", default=[], metavar="RELPATH",
                    help="Skip a worktree whose path relative to target equals or is under RELPATH (repeatable)")
    args = ap.parse_args()

    target = os.path.abspath(args.target)
    if not os.path.isdir(target):
        sys.exit(f"Not a directory: {target}")

    data = collect(target, args.exclude)
    if not data:
        sys.exit("No worktrees found under target.")

    if args.print0:
        render_print0(target, data)
    else:
        render_report(target, data)


if __name__ == "__main__":
    main()
