#!/usr/bin/env python3
# tests/run.py – Tests nach Zweck gegen die gebauten bzw. installierten Pakete (bis 1.5.1 run.sh).
#
#   tests/run.py [--bauen] [r] [python] [julia] [methodik] [gleichlauf] [fehler] [ausgabe] [schnittstelle]
#                [--api] [--gleichlauf-lauf] [--jobs N]                              (aus einem beliebigen Ordner)
#
# Sprachen (ohne Angabe alle drei) und Gruppen (ohne Angabe alle) frei kombinierbar; je Sprache ein Einstieg:
#   R       Rscript tests/run.R <gruppen>                 (methodik, fehler, ausgabe, schnittstelle; testthat)
#   Python  python3 -m pytest tests/<gruppe> ...          (gleichlauf, fehler, ausgabe, schnittstelle)
#   Julia   julia --project=julia tests/run.jl <gruppen>  (gleichlauf, fehler, ausgabe, schnittstelle)
# Gruppen, die es in einer Sprache nicht gibt, entfallen dort (methodik nur in R; gleichlauf hat R als Herkunft).
# --api: Schnittstellenvergleich der drei Sprachen (tests/schnittstelle/run.py --check). --gleichlauf-lauf:
# tests/werkzeuge/gleichlauf/run.py --quick --no-build (erzeugt die Fälle mit R neu, Zufallsprüfungen). --bauen: vorher
# R in die erste Bibliothek von R_LIBS installieren, Python an Ort und Stelle und Julia (Pkg.build) bauen.
# --jobs N (seit 1.6.3): höchstens N Sprachen gleichzeitig (Standard 2 bzw. die Zahl der Prozessoren, wenn kleiner;
# Julia als längster Teil beginnt zuerst). Die Ausgabe eines Teils (stdout und stderr getrennt gesammelt) erscheint
# dann als Block mit Kopf- und Schlusszeile in der Reihenfolge R, Python, Julia, sobald er und die vor ihm fertig sind.
# --jobs 1: nacheinander mit direkter Ausgabe wie bis 1.6.2. Bauen, --api und --gleichlauf-lauf laufen danach allein.
# Voraussetzungen: R mit testthat und jsonlite, Python 3.10 oder neuer mit pytest, numpy, pandas, Julia 1.10 oder neuer.
# Ende 1, wenn ein Teil scheitert.
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SPRACHEN = ("r", "python", "julia")
GRUPPEN = ("methodik", "gleichlauf", "fehler", "ausgabe", "schnittstelle")
status = 0


def ausfuehren(cmd, cwd=None, out=None, err=None):
    """Befehl ausführen (Ausgabe direkt oder in die offenen Dateien out, err); (gelungen, Meldung bei fehlendem Programm)."""
    try:
        return subprocess.run(cmd, cwd=cwd, stdout=out, stderr=err).returncode == 0, None
    except OSError as e:
        return False, "run.py: %s: %s" % (cmd[0], e.strerror)


def schluss(name, ok, dauer):
    """Schlusszeile mit Dauer; status = 1, wenn der Teil scheiterte."""
    global status
    print("== %s: %s (%d s)" % (name, "ok" if ok else "FEHLER", dauer), flush=True)
    if not ok:
        status = 1


def lauf(name, cmd, cwd=None):
    """Kopfzeile, Befehl (Ausgabe direkt), Schlusszeile mit Dauer; status = 1, wenn der Befehl scheitert."""
    t0 = int(time.time())
    print("== " + name, flush=True)
    ok, msg = ausfuehren(cmd, cwd)
    if msg:
        print(msg, file=sys.stderr, flush=True)
    schluss(name, ok, int(time.time()) - t0)


def gleichzeitig(teile, jobs):
    """Teile (Name, Befehl, zuerst) mit höchstens jobs gleichzeitig; Teile mit zuerst = True beginnen vorn. Ausgabe je Teil
    als Block wie bei lauf() in der Reihenfolge der Teile (stdout und stderr getrennt gesammelt, stdout zuerst)."""
    if jobs < 2 or len(teile) < 2:
        for name, cmd, _ in teile:
            lauf(name, cmd)
        return
    tmp = tempfile.mkdtemp(prefix="simlev-tests-")

    def arbeit(i):
        pfad = [os.path.join(tmp, "%d.%s" % (i, k)) for k in ("out", "err")]
        t0 = int(time.time())
        with open(pfad[0], "wb") as out, open(pfad[1], "wb") as err:
            ok, msg = ausfuehren(teile[i][1], None, out, err)
            if msg:
                err.write((msg + "\n").encode("utf-8", "surrogateescape"))
        return ok, int(time.time()) - t0, pfad

    try:
        with ThreadPoolExecutor(jobs) as ex:   # Reihenfolge der Abgabe = Reihenfolge des Beginns
            erg = {i: ex.submit(arbeit, i) for i in sorted(range(len(teile)), key=lambda i: not teile[i][2])}
            for i, (name, _, _) in enumerate(teile):
                ok, dauer, pfad = erg[i].result()
                print("== " + name, flush=True)
                for p, strom in zip(pfad, (sys.stdout, sys.stderr)):
                    with open(p, "rb") as h:
                        shutil.copyfileobj(h, strom.buffer)
                    strom.flush()
                schluss(name, ok, dauer)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    os.environ["LC_ALL"] = "C.UTF-8"
    os.chdir(ROOT)
    bauen = api = lauf_gl = False
    jobs = min(2, os.cpu_count() or 1)
    spr, gr = [], []
    it = iter(argv)
    for a in it:
        if a == "--bauen":
            bauen = True
        elif a == "--api":
            api = True
        elif a == "--gleichlauf-lauf":
            lauf_gl = True
        elif a == "--jobs":
            v = next(it, "")
            if not v.isdigit() or int(v) < 1:
                print("run.py: --jobs braucht eine Zahl >= 1", file=sys.stderr)
                return 2
            jobs = int(v)
        elif a in SPRACHEN:
            spr.append(a)
        elif a in GRUPPEN:
            gr.append(a)
        else:
            print("run.py: unbekannt: " + a, file=sys.stderr)
            return 2
    if not (not spr and not gr and (api or lauf_gl)):
        spr = spr or list(SPRACHEN)
        gr = gr or list(GRUPPEN)

    def nur(*erlaubt):   # gewählte Gruppen, die es in der Sprache gibt
        return [x for x in gr if x in erlaubt]

    if bauen:
        lib = os.environ.get("R_LIBS", "").split(":")[0]
        if not lib:
            print("run.py --bauen: R_LIBS nicht gesetzt", file=sys.stderr)
            return 2
        os.makedirs(lib, exist_ok=True)
        lauf("R CMD INSTALL", ["R", "CMD", "INSTALL", "--preclean", "-l", lib, "r"])
        lauf("Python build_ext", ["python3", "setup.py", "build_ext", "--inplace", "--force"], cwd="python")
        lauf("Julia Pkg.build", ["julia", "--project=julia", "-e", "using Pkg; Pkg.build()"])
    teile = []   # (Name, Befehl, zuerst)
    for s in spr:
        if s == "r":
            g = nur("methodik", "fehler", "ausgabe", "schnittstelle")
            if g:
                teile.append(("R (%s)" % " ".join(g), ["Rscript", "tests/run.R", *g], False))
        elif s == "python":
            g = nur("gleichlauf", "fehler", "ausgabe", "schnittstelle")
            if g:
                teile.append(("Python (%s)" % " ".join(g),
                              ["python3", "-m", "pytest", "-q", "-p", "no:cacheprovider", *("tests/" + x for x in g)], False))
        else:
            g = nur("gleichlauf", "fehler", "ausgabe", "schnittstelle")
            if g:
                teile.append(("Julia (%s)" % " ".join(g), ["julia", "--project=julia", "tests/run.jl", *g], True))
    gleichzeitig(teile, jobs)
    if api:
        lauf("Schnittstelle (tests/schnittstelle/run.py --check)", ["python3", "tests/schnittstelle/run.py", "--check"])
    if lauf_gl:
        lauf("Gleichlauf-Lauf (tests/werkzeuge/gleichlauf)", ["python3", "tests/werkzeuge/gleichlauf/run.py", "--quick", "--no-build"])
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
