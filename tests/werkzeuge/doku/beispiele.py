#!/usr/bin/env python3
"""Führt die Code-Beispiele der Dokumentation aus und vergleicht ihre Ausgaben.

    tests/werkzeuge/doku/beispiele.py [--write] [--jobs N] [r] [python] [julia]          (aus einem beliebigen Ordner)
    tests/werkzeuge/doku/beispiele.py [--write] [--jobs N] [--sprache r,python,julia] <datei> ...

Sprachen ohne Angabe: alle drei. Seit 1.6.3 laufen bis zu N Sprachen gleichzeitig (Standard 2 bzw. die Zahl der
Prozessoren, wenn kleiner; Julia als längste zuerst), die Läufe einer Sprache nacheinander; Ausgabe und Ergebnis wie
nacheinander (--jobs 1), in der Reihenfolge der Dateien. Ohne Datei werden alle Beispiele der Tutorials und READMEs geprüft
(bis 1.5.1 beispiele.sh): README.md (Wurzel, r/, python/, julia/), die Vignette
r/vignettes/getting-started.Rmd, die Tutorials python/examples/tutorial.md und julia/examples/tutorial.md
sowie die Skripte python/examples/*.py und julia/examples/*.jl. Die Abbildungen des Haupt-README schreibt
tests/werkzeuge/doku/bilder.py. Voraussetzung: gebaute bzw. installierte Pakete wie für tests/run.py (R aus
R_LIBS, Python an Ort und Stelle gebaut, Julia nach Pkg.build). Setzt LC_ALL=C.UTF-8 und läuft in der Repo-Wurzel.

Gelesen werden Markdown- und R-Markdown-Dateien. Ausgeführt werden die Codeblöcke
```r, ```python und ```julia (in .Rmd die Chunks ```{r ...}``` außer eval = FALSE),
je Datei und Sprache in einem gemeinsamen Lauf in einem leeren Arbeitsordner, damit
spätere Blöcke auf frühere aufbauen. Ein Block mit der Zeile
<!-- beispiele: nicht ausführen --> direkt davor wird übersprungen (z. B. Installation).

Folgt einem Codeblock (nur durch Leerzeilen getrennt) ein Block ```text, ist das die
erwartete Ausgabe des Codeblocks (Standardausgabe). Eine Zeile, die nur aus "..."
besteht, steht für beliebig viele Zeilen. Abweichungen sind Fehler. Mit --write
werden erwartete Ausgaben ohne "..." durch die tatsächliche Ausgabe ersetzt.

Steht in einer Datei die Zeile <!-- beispiele: gleiche Ausgaben -->, müssen dort außerdem
die erwarteten Ausgaben des n-ten R-, Python- und Julia-Blocks Zeile für Zeile übereinstimmen,
einschließlich der Leerzeilen (seit 1.4.3; zuvor hängte Julias display() bei manchen Objekten eine
Leerzeile an, die nicht zählte). So zeigt
z. B. das Haupt-README, dass alle drei Sprachen dasselbe rechnen.

.py- und .jl-Dateien werden als Ganzes ausgeführt.

Umgebung: R über Rscript (Paket aus R_LIBS), Python mit PYTHONPATH=<repo>/python
(Erweiterung an Ort und Stelle gebaut), Julia mit --project=<repo>/julia.
Ende 1, wenn ein Beispiel scheitert oder eine Ausgabe abweicht.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import Future, ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
SKIP = "<!-- beispiele: nicht ausführen -->"
SAME = "<!-- beispiele: gleiche Ausgaben -->"
MARK = "@@SIMLEV-BEISPIEL-{}@@"
LANGS = {"r": "r", "R": "r", "python": "python", "julia": "julia"}


def blocks(path):
    """Codeblöcke als Liste von dicts: lang, code, line, expected (Liste oder None), exp_span."""
    lines = open(path, encoding="utf-8").read().split("\n")
    rmd = path.endswith(".Rmd")
    out, i = [], 0
    while i < len(lines):
        m = re.match(r"^(\s*)```\s*(\{?[\w]+)?(.*)$", lines[i])
        if not m:
            i += 1
            continue
        info = (m.group(2) or "") + (m.group(3) or "")
        start = i
        j = i + 1
        while j < len(lines) and not re.match(r"^\s*```\s*$", lines[j]):
            j += 1
        body = lines[i + 1:j]
        lang = None
        if rmd and info.startswith("{r"):
            if not re.search(r"eval\s*=\s*FALSE", info):
                lang = "r"
        elif not rmd:
            lang = LANGS.get(info.strip())
        skip = start > 0 and lines[start - 1].strip() == SKIP
        i = j + 1
        if lang and not skip:
            b = {"lang": lang, "code": "\n".join(body), "line": start + 1, "expected": None, "span": None}
            k = i
            while k < len(lines) and lines[k].strip() == "":
                k += 1
            if k < len(lines) and re.match(r"^\s*```\s*text\s*$", lines[k]):
                e = k + 1
                while e < len(lines) and not re.match(r"^\s*```\s*$", lines[e]):
                    e += 1
                b["expected"] = lines[k + 1:e]
                b["span"] = (k + 1, e)
                i = e + 1
            out.append(b)
    return out, lines


def script(lang, bl):
    parts = []
    for n, b in enumerate(bl):
        m = MARK.format(n)
        if lang == "r":
            parts.append('cat("\\n{}\\n")'.format(m))
        elif lang == "python":
            parts.append('print("\\n{}", flush=True)'.format(m))
        else:
            parts.append('println("\\n{}"); flush(stdout)'.format(m))
        parts.append(b["code"])
    return "\n".join(parts) + "\n"


def command(lang, file):
    if lang == "r":
        return ["Rscript", file]
    if lang == "python":
        return [sys.executable, file]
    return ["julia", "--project=" + os.path.join(ROOT, "julia"), file]


def run(lang, code, suffix):
    env = dict(os.environ)
    env["PYTHONPATH"] = os.path.join(ROOT, "python") + (":" + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    env.setdefault("LC_ALL", "C.UTF-8")
    with tempfile.TemporaryDirectory(prefix="simlev-doku-") as tmp:
        f = os.path.join(tmp, "beispiel" + suffix)
        with open(f, "w", encoding="utf-8") as h:
            h.write(code)
        p = subprocess.run(command(lang, f), cwd=tmp, env=env, capture_output=True, text=True, encoding="utf-8")
    return p.returncode, p.stdout, p.stderr


def clean(lines):
    lines = [l.rstrip() for l in lines]
    while lines and lines[0] == "":
        lines.pop(0)
    while lines and lines[-1] == "":
        lines.pop()
    return lines


def matches(exp, act):
    """exp mit Zeilen "..." als Platzhalter für beliebig viele Zeilen."""
    exp, act = clean(exp), clean(act)
    memo = {}

    def go(i, j):
        if (i, j) in memo:
            return memo[(i, j)]
        if i == len(exp):
            r = j == len(act)
        elif exp[i].strip() == "...":
            r = any(go(i + 1, k) for k in range(j, len(act) + 1))
        else:
            r = j < len(act) and exp[i] == act[j] and go(i + 1, j + 1)
        memo[(i, j)] = r
        return r

    return go(0, 0)


def check_same(rel, bl, lines):
    """Erwartete Ausgaben der n-ten Blöcke je Sprache vergleichen (mit Leerzeilen)."""
    if SAME not in (l.strip() for l in lines):
        return True
    sel = {lang: [b for b in bl if b["lang"] == lang] for lang in ("r", "python", "julia")}
    bad = []
    if len({len(v) for v in sel.values()}) != 1:
        bad.append("ungleiche Zahl der Blöcke: " + ", ".join("{} {}".format(k, len(v)) for k, v in sel.items()))
    else:
        for r, p, j in zip(sel["r"], sel["python"], sel["julia"]):
            e = [clean(b["expected"] or []) for b in (r, p, j)]
            if not (e[0] == e[1] == e[2]):
                bad.append("Ausgaben nach Block Zeile {} (R), {} (Python), {} (Julia) ungleich".format(
                    r["line"], p["line"], j["line"]))
    print("{:<40} {:<7} {:>3} Blöcke, gleiche Ausgaben  {}".format(rel, "alle", len(sel["r"]), "ok" if not bad else "FEHLER"))
    for m in bad:
        print("   " + m)
    return not bad


def jobs_of(path, langs):
    """Läufe einer Datei in der Reihenfolge von check_file: Liste (Sprache, Code, Endung)."""
    if path.endswith((".py", ".jl")):
        lang = "python" if path.endswith(".py") else "julia"
        return [(lang, open(path, encoding="utf-8").read(), os.path.splitext(path)[1])] if lang in langs else []
    bl, _ = blocks(path)
    return [(lang, script(lang, sel), {"r": ".R", "python": ".py", "julia": ".jl"}[lang])
            for lang in ("r", "python", "julia")
            if lang in langs and (sel := [b for b in bl if b["lang"] == lang])]


def run_all(files, langs, jobs):
    """Alle Läufe vorab starten: je Sprache nacheinander (in der Reihenfolge der Dateien), bis zu jobs Sprachen
    gleichzeitig, Julia zuerst. Liefert je Datei die Futures ihrer Läufe in der Reihenfolge von jobs_of."""
    per_file, chains = [], {}
    for f in files:
        futs = []
        for lang, code, suffix in jobs_of(f, langs):
            fut = Future()
            chains.setdefault(lang, []).append((fut, lang, code, suffix))
            futs.append(fut)
        per_file.append(futs)

    def chain(items):
        for fut, lang, code, suffix in items:
            try:
                fut.set_result(run(lang, code, suffix))
            except BaseException as e:   # noqa: BLE001 - Fehler beim Aufrufer melden
                fut.set_exception(e)

    ex = ThreadPoolExecutor(max(1, jobs))
    for lang in sorted(chains, key=lambda l: l != "julia"):
        ex.submit(chain, chains[lang])
    ex.shutdown(wait=False)
    return per_file


def check_file(path, langs, write, futs=None):
    """Datei prüfen; futs: vorab gestartete Läufe (run_all), sonst laufen sie hier nacheinander."""
    rel = os.path.relpath(path, ROOT)
    ok = True
    res = (run(*j) for j in jobs_of(path, langs)) if futs is None else (f.result() for f in futs)
    if path.endswith((".py", ".jl")):
        lang = "python" if path.endswith(".py") else "julia"
        if lang not in langs:
            return True
        rc, so, se = next(res)
        print("{:<40} {:<7} {}".format(rel, lang, "ok" if rc == 0 else "FEHLER"))
        if rc != 0:
            print(se[-3000:])
        return rc == 0
    bl, lines = blocks(path)
    edits = []
    for lang in ("r", "python", "julia"):
        sel = [b for b in bl if b["lang"] == lang]
        if not sel or lang not in langs:
            continue
        rc, so, se = next(res)
        seg = re.split(r"\n?" + re.escape(MARK.format("X")).replace("X", r"(\d+)") + r"\n", so)
        outs = {}
        for k in range(1, len(seg) - 1, 2):
            outs[int(seg[k])] = seg[k + 1].split("\n")
        bad = []
        for n, b in enumerate(sel):
            if n not in outs:
                bad.append("Block Zeile {} nicht erreicht".format(b["line"]))
                continue
            if b["expected"] is None:
                continue
            if matches(b["expected"], outs[n]):
                continue
            if write and not any(l.strip() == "..." for l in b["expected"]):
                edits.append((b["span"], clean(outs[n])))
            else:
                bad.append("Ausgabe nach Block Zeile {} weicht ab:\n--- erwartet\n{}\n--- erhalten\n{}".format(
                    b["line"], "\n".join(clean(b["expected"])), "\n".join(clean(outs[n]))))
        if rc != 0:
            bad.append("Abbruch (Ende {}):\n{}".format(rc, se[-3000:]))
        n_exp = sum(b["expected"] is not None for b in sel)
        print("{:<40} {:<7} {:>3} Blöcke, {:>2} Ausgaben  {}".format(
            rel, lang, len(sel), n_exp, "ok" if not bad else "FEHLER"))
        for m in bad:
            print("   " + m.replace("\n", "\n   "))
        ok = ok and not bad
    if edits:
        for (a, e), new in sorted(edits, reverse=True):
            lines[a:e] = new
        with open(path, "w", encoding="utf-8") as h:
            h.write("\n".join(lines))
        print("   {} Ausgaben neu geschrieben".format(len(edits)))
    if langs == {"r", "python", "julia"}:
        bl, lines = blocks(path)
        ok = check_same(rel, bl, lines) and ok
    return ok


# Dateien ohne Angabe (relativ zur Repo-Wurzel; dazu python/examples/*.py und julia/examples/*.jl)
DATEIEN = ["README.md", "r/README.md", "python/README.md", "julia/README.md", "r/vignettes/getting-started.Rmd",
           "python/examples/tutorial.md", "julia/examples/tutorial.md"]


def main(argv):
    write = "--write" in argv
    langs = {"r", "python", "julia"}
    jobs = min(2, os.cpu_count() or 1)
    spr, files = [], []
    it = iter(a for a in argv if a != "--write")
    for a in it:
        if a == "--sprache":
            langs = set(next(it).split(","))
        elif a == "--jobs":
            v = next(it, "")
            if not v.isdigit() or int(v) < 1:
                print("beispiele.py: --jobs braucht eine Zahl >= 1", file=sys.stderr)
                return 2
            jobs = int(v)
        elif a in ("r", "python", "julia"):
            spr.append(a)
        elif a.startswith("-"):
            print("beispiele.py: unbekannt: " + a, file=sys.stderr)
            return 2
        else:
            files.append(os.path.abspath(a))
    if spr:
        langs = set(spr)
    os.environ["LC_ALL"] = "C.UTF-8"
    os.chdir(ROOT)
    if not files:
        files = [os.path.join(ROOT, f) for f in DATEIEN]
        for muster in ("python/examples/*.py", "julia/examples/*.jl"):
            files += [os.path.join(ROOT, f) for f in sorted(glob.glob(muster))]
    per_file = run_all(files, langs, jobs) if jobs > 1 else [None] * len(files)
    ok = all([check_file(f, langs, write, futs) for f, futs in zip(files, per_file)])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
