"""Track the newest kernel and re-fit it to this PC.

Run from the repository root:  nix run .#update -- [options]

Each run:
  1. checks this PC (CPU model and thread count, loaded modules, and, with
     --nixos-flake, the modules NixOS's initrd needs) and adds new modules
     to the keep list; modules are never dropped from it;
  2. finds the newest stable CachyOS kernel release and checks kernel.org for
     a newer stable version that CachyOS has not released yet;
  3. pins the newest BORE patch and CachyOS config, and (unless --no-nixpkgs)
     moves nixpkgs forward for a newer Clang and NVIDIA driver;
  4. with --build, builds the kernel, the NVIDIA module and, with
     --nixos-flake, the whole NixOS system; on failure it puts every file
     back as it was;
  5. with --commit / --push, records the change in git.

The last line printed is a JSON summary.
"""
import argparse
import datetime as dt
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.request

TRACKED = [
    "kernel/sources.json",
    "hardware/profile.json",
    "hardware/loaded-modules.txt",
    "hardware/initrd-modules.txt",
    "hardware/keep-modules.txt",
    "flake.lock",
]
CO_AUTHOR = "Co-authored-by: OpenBot <335604065+openbotgit[bot]@users.noreply.github.com>"


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def http_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "optimized-kernel-updater"})
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def run(cmd, **kw):
    log("+", " ".join(cmd))
    return subprocess.run(cmd, check=True, text=True, **kw)


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def mm(v):
    return ".".join(v.split(".")[:2])


def norm(name):
    return name.strip().replace("-", "_")


def read_list(path):
    if not path.exists():
        return set()
    return {norm(l) for l in path.read_text().split() if l.strip() and not l.startswith("#")}


def write_list(path, names):
    path.write_text("".join(f"{n}\n" for n in sorted(names)))


def prefetch(url):
    out = run(["nix", "store", "prefetch-file", "--json", "--hash-type", "sha256", url],
              capture_output=True).stdout
    return json.loads(out)["hash"]


def latest_commit(repo, path):
    c = http_json(f"https://api.github.com/repos/{repo}/commits?path={path}&per_page=1")
    return c[0]["sha"] if c else None


# ---------------------------------------------------------------- hardware
def refresh_hardware(root, args, notes):
    hw = root / "hardware"
    cpu_model = ""
    for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines():
        if line.startswith("model name"):
            cpu_model = line.split(":", 1)[1].strip()
            break
    nr = os.cpu_count() or 1
    prof_path = hw / "profile.json"
    prof = json.loads(prof_path.read_text()) if prof_path.exists() else {}
    if prof.get("cpuModel") and prof["cpuModel"] != cpu_model and not args.accept_new_cpu:
        raise SystemExit(
            f"CPU changed: profile is for '{prof['cpuModel']}', this PC has '{cpu_model}'. "
            "The kernel is compiled with -march=native for the CPU that builds it. "
            "Run with --accept-new-cpu to re-fit it to this CPU.")
    prof.update({"cpuModel": cpu_model, "nrCpus": nr})
    prof_path.write_text(json.dumps(prof, indent=2) + "\n")

    loaded_path = hw / "loaded-modules.txt"
    loaded = read_list(loaded_path)
    now = {norm(l.split()[0]) for l in pathlib.Path("/proc/modules").read_text().splitlines() if l}
    new = now - loaded
    if new:
        notes.append(f"{len(new)} newly seen modules kept: {', '.join(sorted(new)[:15])}")
    write_list(loaded_path, loaded | now)

    initrd_path = hw / "initrd-modules.txt"
    initrd = read_list(initrd_path)
    if args.nixos_flake:
        base = f"{args.nixos_flake}#nixosConfigurations.{args.host}.config.boot"
        names = set()
        for attr in ["initrd.availableKernelModules", "initrd.kernelModules", "kernelModules"]:
            out = run(["nix", "eval", "--json", f"{base}.{attr}"], capture_output=True).stdout
            names |= {norm(n) for n in json.loads(out)}
        initrd |= names
    write_list(initrd_path, initrd)
    write_list(hw / "keep-modules.txt", read_list(loaded_path) | initrd)
    return prof


# ---------------------------------------------------------------- upstream
def pick_release(notes):
    rels = http_json("https://api.github.com/repos/CachyOS/linux/releases?per_page=40")
    cands = []
    for r in rels:
        m = re.fullmatch(r"cachyos-(\d+\.\d+(?:\.\d+)?)-(\d+)", r["tag_name"])
        if not m or r.get("prerelease") or r.get("draft"):
            continue
        asset = next((a for a in r["assets"] if a["name"] == f"{r['tag_name']}.tar.gz"), None)
        if asset:
            cands.append((vtuple(m.group(1)), int(m.group(2)), m.group(1), r["tag_name"],
                          asset["browser_download_url"]))
    if not cands:
        raise SystemExit("No stable CachyOS release found")
    cands.sort(reverse=True)
    for _, _, version, tag, url in cands:
        bore_path = f"{mm(version)}/sched/0001-bore-cachy.patch"
        sha = latest_commit("CachyOS/kernel-patches", bore_path)
        if sha:
            return version, tag, url, bore_path, sha
        notes.append(f"{tag}: no BORE patch for {mm(version)} yet, trying an older release")
    raise SystemExit("No CachyOS release with a matching BORE patch")


def update_sources(root, notes):
    path = root / "kernel" / "sources.json"
    old = json.loads(path.read_text()) if path.exists() else {}
    version, tag, url, bore_path, bore_sha = pick_release(notes)

    try:
        ko = http_json("https://www.kernel.org/releases.json")["latest_stable"]["version"]
    except Exception as e:  # kernel.org down is not fatal
        ko = None
        notes.append(f"kernel.org check failed: {e}")
    if ko and vtuple(ko) > vtuple(version):
        notes.append(f"kernel.org has {ko}; CachyOS has not released it yet, staying on {version}")

    cfg_path = "linux-cachyos-bore/config"
    cfg_sha = latest_commit("CachyOS/linux-cachyos", cfg_path)
    bore_url = f"https://raw.githubusercontent.com/CachyOS/kernel-patches/{bore_sha}/{bore_path}"
    cfg_url = f"https://raw.githubusercontent.com/CachyOS/linux-cachyos/{cfg_sha}/{cfg_path}"

    def keep_or_fetch(key, u):
        o = old.get(key, {})
        return o["hash"] if o.get("url") == u and o.get("hash") else prefetch(u)

    new = {
        "version": version,
        "source": {"tag": tag, "url": url, "hash": keep_or_fetch("source", url)},
        "bore": {"commit": bore_sha, "url": bore_url, "hash": keep_or_fetch("bore", bore_url)},
        "config": {"commit": cfg_sha, "url": cfg_url, "hash": keep_or_fetch("config", cfg_url)},
        "kernelOrgLatestStable": ko,
    }
    path.write_text(json.dumps(new, indent=2) + "\n")
    return old, new


# ---------------------------------------------------------------- build
def build(root, args, log_dir):
    log_dir.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    logf = log_dir / f"build-{stamp}.log"
    cmds = [["nix", "build", "-L", "--no-link", "--print-out-paths",
             f"{root}#kernel", f"{root}#nvidia-open"]]
    if args.nixos_flake:
        cmds.append(["nix", "build", "-L", "--no-link", "--print-out-paths",
                     f"{args.nixos_flake}#nixosConfigurations.{args.host}.config.system.build.toplevel",
                     "--override-input", "optimized-kernel", f"path:{root}"])
    outs = []
    with logf.open("w") as f:
        for c in cmds:
            log("+", " ".join(c), f"(log: {logf})")
            p = subprocess.run(c, stdout=subprocess.PIPE, stderr=f, text=True)
            if p.returncode != 0:
                return False, str(logf), outs
            outs += p.stdout.split()
    return True, str(logf), outs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".", help="repository root (default: current folder)")
    ap.add_argument("--nixos-flake", help="NixOS config flake that uses this kernel (adds its initrd modules, builds it)")
    ap.add_argument("--host", default="nixos-btw", help="nixosConfigurations name (default: nixos-btw)")
    ap.add_argument("--no-nixpkgs", action="store_true", help="keep the current nixpkgs pin")
    ap.add_argument("--build", action="store_true", help="build and check; undo everything on failure")
    ap.add_argument("--commit", action="store_true", help="git commit the update (only after a passing --build)")
    ap.add_argument("--push", action="store_true", help="git push after committing")
    ap.add_argument("--force", action="store_true", help="build even when nothing changed")
    ap.add_argument("--accept-new-cpu", action="store_true", help="re-fit to a different CPU")
    args = ap.parse_args()

    root = pathlib.Path(args.repo).resolve()
    if args.nixos_flake:
        args.nixos_flake = str(pathlib.Path(args.nixos_flake).resolve())
    if not (root / "flake.nix").exists():
        raise SystemExit(f"{root} is not the optimized-kernel repository")
    log_dir = pathlib.Path(os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache")) / "optimized-kernel"

    backup = log_dir / "backup"
    shutil.rmtree(backup, ignore_errors=True)
    for rel in TRACKED:
        src = root / rel
        if src.exists():
            (backup / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, backup / rel)

    def restore():
        for rel in TRACKED:
            b = backup / rel
            if b.exists():
                shutil.copy2(b, root / rel)

    notes = []
    summary = {"status": "error"}
    try:
        prof = refresh_hardware(root, args, notes)
        old, new = update_sources(root, notes)
        if not args.no_nixpkgs:
            run(["nix", "flake", "update", "nixpkgs", "--flake", str(root)], capture_output=True)
        changed = [rel for rel in TRACKED
                   if not (backup / rel).exists()
                   or (backup / rel).read_bytes() != (root / rel).read_bytes()]
        summary = {
            "status": "changed" if changed else "up-to-date",
            "version": new["version"],
            "previousVersion": old.get("version"),
            "cachyosRelease": new["source"]["tag"],
            "kernelOrgLatestStable": new["kernelOrgLatestStable"],
            "cpu": prof["cpuModel"],
            "keptModules": len(read_list(root / "hardware" / "keep-modules.txt")),
            "changedFiles": changed,
            "notes": notes,
        }
        if not changed and not args.force:
            print(json.dumps(summary))
            return 0
        if args.build:
            ok, logf, outs = build(root, args, log_dir)
            summary["buildLog"] = logf
            if not ok:
                restore()
                summary["status"] = "build-failed"
                summary["notes"].append("every file was put back as it was")
                print(json.dumps(summary))
                return 1
            summary["status"] = "built"
            summary["outputs"] = outs
        if args.commit and changed:
            if not args.build:
                raise SystemExit("--commit needs --build, so only tested updates are committed")
            run(["git", "-C", str(root), "add", *changed])
            msg = (f"Update kernel to {new['version']} ({new['source']['tag']})\n\n"
                   f"BORE {new['bore']['commit'][:12]}, config {new['config']['commit'][:12]}, "
                   f"{summary['keptModules']} kept modules.\n"
                   + "".join(f"- {n}\n" for n in notes) + f"\n{CO_AUTHOR}\n")
            run(["git", "-C", str(root), "commit", "-m", msg])
            summary["commit"] = run(["git", "-C", str(root), "rev-parse", "HEAD"],
                                    capture_output=True).stdout.strip()
            if args.push:
                run(["git", "-C", str(root), "push"])
                summary["pushed"] = True
        print(json.dumps(summary))
        return 0
    except BaseException as e:
        restore()
        summary.update({"status": "error", "error": str(e), "notes": notes + ["every file was put back as it was"]})
        print(json.dumps(summary))
        return 1


if __name__ == "__main__":
    sys.exit(main())
