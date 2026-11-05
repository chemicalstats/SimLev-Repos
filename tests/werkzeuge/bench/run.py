#!/usr/bin/env python3
# Messbasis: R, Python und Julia nacheinander messen (nie gleichzeitig), dann zusammenführen (bis 1.5.1 run.sh).
#   R_LIBS=<Bibliothek mit SimLev> tests/werkzeuge/bench/run.py [aufgaben]     z. B. T1,T8; Voreinstellung alle außer P1
#   R_LIBS=<…> tests/werkzeuge/bench/run.py P1     bootstrap mit cores = 1 und 2 (R/Python: Fork, Julia: -t 2)
#   (die frühere Option --ohne-c, Python ohne C-Erweiterung, ist seit 1.0.0 entfallen)
# Ergebnis: tests/werkzeuge/bench/ergebnis_<JJJJ-MM-TT>.csv (bei P1: ergebnis_<JJJJ-MM-TT>_parallel.csv). Eine vorhandene
# Messdatei wird nie überschrieben: Gibt es sie schon, heißt die neue ergebnis_<JJJJ-MM-TT>[_parallel]_2.csv,
# dann _3, … (die Endung steht am Ende, also z. B. ergebnis_2026-10-27_parallel_2.csv).
# Zwischenordner: tests/werkzeuge/bench/out/{r,python,julia}.csv (bei P1 *_parallel.csv)
# sind die Einzelauszüge des letzten Laufs je Sprache; jeder Lauf überschreibt sie. Sie gelten nicht als
# Ergebnis: Ihr Inhalt steht vollständig in der Ergebnisdatei (merge.py übernimmt alle Zeilen).
# Bricht ab, sobald ein Schritt scheitert (Rückgabewert des Schritts). Python 3.10 oder neuer, nur Standardbibliothek.
import datetime
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def lauf(*cmd):
    sys.stdout.flush()
    try:
        rc = subprocess.run(list(cmd)).returncode
    except OSError as e:   # Programm fehlt: wie die Shell mit 127
        print("run.py: %s: %s" % (cmd[0], e.strerror), file=sys.stderr)
        rc = 127
    if rc:
        sys.exit(rc if rc > 0 else 128 - rc)


def main(argv):
    os.environ["LC_ALL"] = "C.UTF-8"
    # ein Kern: keine BLAS-/OpenMP-/Julia-Threads
    for k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "JULIA_NUM_THREADS"):
        os.environ[k] = "1"
    os.chdir(os.path.join(HERE, "..", "..", ".."))
    out = os.path.join(HERE, "out")
    os.makedirs(out, exist_ok=True)
    tasks = argv[0] if argv else ""
    ta = tasks.split()   # wie $tasks ohne Anführungszeichen: leer = keine Angabe
    sfx = ""
    if tasks == "P1":
        sfx = "_parallel"
        os.environ["JULIA_NUM_THREADS"] = "2"   # cores = 2 braucht in Julia zwei Threads; BLAS bleibt bei einem
    lauf("Rscript", os.path.join(HERE, "bench.R"), os.path.join(out, "r%s.csv" % sfx), *ta)
    lauf("python3", os.path.join(HERE, "bench.py"), os.path.join(out, "python%s.csv" % sfx), *ta)
    lauf("julia", "--project=julia", os.path.join(HERE, "bench.jl"), os.path.join(out, "julia%s.csv" % sfx), *ta)
    # Ergebnisdatei ohne Überschreiben: ergebnis_<Datum><sfx>.csv, sonst mit _2, _3, …
    erg = os.path.join(HERE, "ergebnis_%s%s" % (datetime.date.today().isoformat(), sfx))
    if os.path.exists(erg + ".csv"):
        i = 2
        while os.path.exists("%s_%d.csv" % (erg, i)):
            i += 1
        erg = "%s_%d" % (erg, i)
    lauf("python3", os.path.join(HERE, "merge.py"), "--out", erg + ".csv", "--alt", os.path.join(HERE, "anhang_e_2026-10-20.csv"),
         *(os.path.join(out, "%s%s.csv" % (s, sfx)) for s in ("r", "python", "julia")))
    print("Ergebnis: %s.csv" % erg)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
