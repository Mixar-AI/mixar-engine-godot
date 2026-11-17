#!/usr/bin/env python3
"""Concurrent imports against a real, headless Godot editor.

Mixar runs several agents at once; each may send an export package (a GLB and
its textures) through the link at nearly the same moment, sometimes the same
package into the same folder. Before imports were serialized the editor read a
texture while another call was still copying it (ERR_FILE_CORRUPT), called
reimport_files() inside a running import ("recursively, this is not allowed")
and then crashed (signal 11).

    python3 test/run_concurrent_import_e2e.py --godot /path/to/Godot [--rounds 3]

Each round fires several import_package calls in the same instant (separate
connections, so the editor takes them in the same frame): the same package into
one folder twice, and other packages into their own folders. It checks that
the editor survives, every call answers only once its import is done (the main
file and every texture are imported), the imports never overlapped, status
shows the queue, and the log has no corrupt read or recursive reimport.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import sys
import tempfile
import threading
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_e2e  # noqa: E402  (the shared client, launcher and check())
from run_e2e import check, launch, FAILURES  # noqa: E402

ROOT = run_e2e.ROOT
BAD_LOG_LINES = ("reimport_files() recursively", "ERR_FILE_CORRUPT", "Error loading image",
                 "Program crashed", "handle_crash")
# Godot 4.7's own, with a window, on any first import of a GLB that uses textures, one at
# a time too: the scene import flags its textures as used in 3D, and the editor reimports
# them (ResourceImporterTexture::update_imports) in a frame reimport_files() runs after it
# clears is_importing(). Counted, not failed.
ENGINE_NOISE = "Task 'reimport' already exists"


def png_noise(path: str, size: int) -> None:
    """An RGB PNG of noise (it barely compresses, so it is big and slow to write)."""
    raw = bytearray()
    for _ in range(size):
        raw.append(0)
        raw.extend(os.urandom(size * 3))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
                 + chunk(b"IDAT", zlib.compress(bytes(raw), 1)) + chunk(b"IEND", b""))


def glb_textured(path: str, name: str, textures: list[str]) -> None:
    """A GLB quad whose material uses external PNGs (base colour, then normal)."""
    pos = struct.pack("<12f", 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0)
    uv = struct.pack("<8f", 0, 1, 1, 1, 1, 0, 0, 0)
    idx = struct.pack("<6H", 0, 1, 2, 0, 2, 3)
    blob = pos + uv + idx
    material = {"name": name + "_mat", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}
    if len(textures) > 1:
        material["normalTexture"] = {"index": 1}
    doc = {
        "asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "TEXCOORD_0": 1}, "indices": 2,
                                    "material": 0}]}],
        "materials": [material],
        "images": [{"uri": "textures/" + t} for t in textures],
        "textures": [{"source": i} for i in range(len(textures))],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]},
            {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC2"},
            {"bufferView": 2, "componentType": 5123, "count": 6, "type": "SCALAR"},
        ],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(pos)},
                        {"buffer": 0, "byteOffset": len(pos), "byteLength": len(uv)},
                        {"buffer": 0, "byteOffset": len(pos) + len(uv), "byteLength": len(idx)}],
        "buffers": [{"byteLength": len(blob)}],
    }
    js = json.dumps(doc).encode()
    js += b" " * (-len(js) % 4)
    blob += b"\0" * (-len(blob) % 4)
    body = struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + blob
    with open(path, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


def make_package(root: str, name: str, tex_size: int) -> str:
    folder = os.path.join(root, name)
    os.makedirs(os.path.join(folder, "textures"))
    textures = [f"{name}_Body_basecolor.001.png", f"{name}_Body_normal.001.png"]
    for t in textures:
        png_noise(os.path.join(folder, "textures", t), tex_size)
    glb_textured(os.path.join(folder, name + ".glb"), name, textures)
    with open(os.path.join(folder, "manifest.json"), "w") as fh:
        json.dump({"asset": name, "format": "glb", "generator": "Mixar export_package",
                   "files": [{"file": name + ".glb"}] + [{"file": "textures/" + t} for t in textures]}, fh)
    return folder


def fire(client, calls: list[tuple[str, dict]], timeout: float) -> list:
    """Every call at once, each on its own connection; the results in order."""
    results: list = [None] * len(calls)
    start = threading.Barrier(len(calls))

    def one(i, name, args):
        start.wait()
        try:
            results[i] = client.call(name, args, timeout=timeout)
        except Exception as err:  # the editor died or dropped the connection
            results[i] = {"isError": True, "content": [{"text": f"{type(err).__name__}: {err}"}],
                          "structuredContent": {}}

    threads = [threading.Thread(target=one, args=(i, n, a)) for i, (n, a) in enumerate(calls)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results


def imported(project: str, folder: str, files: list[str]) -> list[str]:
    """Files of res://mixar/<folder>/ that have no valid import yet."""
    missing = []
    for f in files:
        sidecar = os.path.join(project, "mixar", folder, f + ".import")
        if not os.path.isfile(sidecar) or "valid=false" in open(sidecar).read():
            missing.append(f)
    return missing


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", required=True)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--tex-size", type=int, default=2048, help="texture edge in pixels (2048 = a 12 MB PNG)")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--serial", action="store_true", help="one import at a time (a baseline for the log checks)")
    ap.add_argument("--windowed", action="store_true",
                    help="run the editor with a window (its progress dialog runs frames during an import)")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="mixar-link-concurrent-")
    home, project, exports = (os.path.join(tmp, d) for d in ("home", "project", "Mixar Exports"))
    for d in (home, project, exports):
        os.makedirs(d)
    shutil.copytree(os.path.join(ROOT, "addons"), os.path.join(project, "addons"))
    with open(os.path.join(project, "project.godot"), "w") as fh:
        fh.write(run_e2e.PROJECT_GODOT.replace("[autoload]\n\nTestPrinter=\"*res://test_printer.gd\"\n", ""))
    names = ["RubbleOperator", "Crate", "Barrel"]
    packages = {n: make_package(exports, n, args.tex_size) for n in names}
    files = {n: [n + ".glb", f"textures/{n}_Body_basecolor.001.png", f"textures/{n}_Body_normal.001.png"]
             for n in names}
    # A Tripo rig: its import retargets, which reimports the GLB (the reimport_files() call).
    packages["Hero"] = run_e2e.humanoid_package(exports, "Hero", "tripo", wave=False)
    files["Hero"] = ["Hero.glb"]

    log_path = os.path.join(tmp, "godot.log")
    if args.windowed:  # launch() is always headless
        real = run_e2e.subprocess.Popen
        run_e2e.subprocess.Popen = lambda cmd, **kw: real([c for c in cmd if c != "--headless"], **kw)
        try:
            proc, client, log = launch(args.godot, project, home, log_path)
        finally:
            run_e2e.subprocess.Popen = real
    else:
        proc, client, log = launch(args.godot, project, home, log_path)
    try:
        check(client is not None, "editor connects")
        if client is None:
            return 1
        for rnd in range(args.rounds):
            if rnd:  # new pixels, so every round really reimports the textures
                for n in names:
                    for f in files[n][1:]:
                        png_noise(os.path.join(packages[n], f), args.tex_size)
            # Two agents send the same package into the same folder; two others send their own.
            calls = [("import_package", {"source_dir": packages["RubbleOperator"], "folder": "RubbleOperator"}),
                     ("import_package", {"source_dir": packages["RubbleOperator"], "folder": "RubbleOperator"}),
                     ("import_package", {"source_dir": packages["Crate"], "folder": "Crate"}),
                     ("import_package", {"source_dir": packages["Barrel"], "folder": "Barrel"}),
                     ("import_package", {"source_dir": packages["Hero"], "folder": "Hero"})]
            seen_queue: list = []
            stop = threading.Event()

            def watch():
                while not stop.is_set():
                    try:
                        st = client.call("status", timeout=10)["structuredContent"].get("imports")
                        if st:
                            seen_queue.append(st)
                    except Exception:
                        pass
                    time.sleep(0.05)

            watcher = threading.Thread(target=watch)
            watcher.start()
            t0 = time.time()
            if args.serial:
                results = [fire(client, [c], timeout=400)[0] for c in calls]
            else:
                results = fire(client, calls, timeout=400)
            stop.set()
            watcher.join()
            alive = proc.poll() is None
            check(alive, f"round {rnd + 1}: the editor survives {len(calls)} simultaneous imports",
                  f"exit code {proc.returncode}")
            if not alive:
                break
            for (_, a), r in zip(calls, results):
                sc = r.get("structuredContent", {})
                check(not r["isError"] and sc.get("imported") is True,
                      f"round {rnd + 1}: {a['folder']} import answers ok", r["content"][0]["text"][:300])
                missing = imported(project, a["folder"], files[a["folder"]])
                check(not missing, f"round {rnd + 1}: {a['folder']} main file and textures imported when it answers",
                      missing)
            hero = results[-1].get("structuredContent", {})
            if rnd == 0:  # later rounds: the rig already has the humanoid names
                check(hero.get("retarget", {}).get("naming") == "tripo",
                      "the rig is retargeted (its reimport ran inside the burst)", hero)
            # Serialized: every import reports when it ran, and no two overlapped.
            spans = sorted((r["structuredContent"].get("started_ms", 0), r["structuredContent"].get("finished_ms", 0))
                           for r in results if not r["isError"])
            valid = len(spans) == len(calls) and all(0 < a <= b for a, b in spans)
            overlap = any(b[0] < a[1] for a, b in zip(spans, spans[1:]))
            check(valid and not overlap, f"round {rnd + 1}: imports ran one at a time", spans)
            ahead = sorted(r["structuredContent"].get("jobs_ahead", -1) for r in results)
            check(ahead == list(range(len(calls))), f"round {rnd + 1}: each import waited for the ones ahead of it",
                  ahead)
            if not any(q.get("queued") for q in seen_queue):
                print(f"  note: round {rnd + 1}: the status poll did not catch a queued import")
            st = client.call("status")["structuredContent"].get("imports", {})
            check(st.get("running") is None and not st.get("queued"), f"round {rnd + 1}: the queue drains", st)
            print(f"  round {rnd + 1}: {time.time() - t0:.1f} s")
        staging = os.path.join(project, ".godot", "mixar_link", "staging")
        check(not os.path.isdir(staging) or not os.listdir(staging), "no staged files left behind",
              os.listdir(staging) if os.path.isdir(staging) else "")
        stray = [os.path.join(d, f) for d, _, fs in os.walk(os.path.join(project, "mixar"))
                 for f in fs if f.startswith(".mixar")]
        check(not stray, "no temporary files in res://mixar", stray)
        if proc.poll() is None:
            lines = client.call("log", {"errors_only": True, "max_lines": 1000})["structuredContent"]["lines"]
            bad = [line["text"] for line in lines if any(b in line["text"] for b in BAD_LOG_LINES)]
            check(not bad, "no corrupt reads or recursive reimports in the editor log", bad[:4])
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except Exception:
            proc.kill()
        log.close()
        text = open(log_path, errors="replace").read()
        if ENGINE_NOISE in text:
            print(f"  note: the editor logged \"{ENGINE_NOISE}\" {text.count(ENGINE_NOISE)} time(s) (Godot's own; see ENGINE_NOISE)")
        bad = [b for b in BAD_LOG_LINES if b in text]
        check(not bad, "the editor's own output has no corrupt read, recursive reimport or crash", bad)
        if FAILURES or args.keep:
            print(f"temp folder kept: {tmp} (editor log: {log_path})")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{'FAILED' if FAILURES else 'OK'}: {len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
