"""Vergleich des Datumskerns core/slc_rbase_date.cpp (über simlev._ext) mit R (date_fuzz.R).

    python3 tests/werkzeuge/gleichlauf/date_fuzz_cmp.py <ordner>
Textgleich heißt: dieselbe Zeichenkette (bzw. beide NA, beide Fehler) für format.Date und dieselben Tage für
as.Date. Geprüft werden fmt.tsv (dokumentierte Umwandlungen), fmt_sys.tsv (Schalter, Breiten, E/O, unbekannte
Umwandlungen; seit 1.3.0 Prüfziel), fmt_os.tsv (%OS mit digits.secs, seit 1.3.0) und parse.tsv. Ende 1 bei Abweichung.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "python"))
from simlev._r import fmt  # noqa: E402
from simlev import _ext  # noqa: E402


def unesc(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            out.append({"n": "\n", "t": "\t", "\\": "\\"}[s[i + 1]])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def esc(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


D = sys.argv[1]


def cmp_fmt(file, show):
    rows = [ln.rstrip("\n").split("\t") for ln in open(os.path.join(D, file), encoding="utf-8")]
    nf = 0
    for r in rows:
        old = fmt.set_options(digits_secs=None if len(r) < 4 or r[3] == "NULL" else float(r[3]))
        try:
            g = fmt._format_date_list(np.array([float(r[0])]), [unesc(r[1])])[0]
            g = "<NA>" if g is None else esc(g)
        except ValueError:
            g = "<ERR>"
        finally:
            fmt.set_options(**old)
        if g != r[2]:
            nf += 1
            if nf <= show:
                print("format  Tag %s  Format %r%s: R %r  Python %r"
                      % (r[0], r[1], "" if len(r) < 4 else "  digits.secs " + r[3], r[2][:200], g[:200]))
    return nf, len(rows)


bad = 0
for file, what in (("fmt.tsv", "dokumentierte Umwandlungen"), ("fmt_sys.tsv", "systemabhängige Formen wie glibc"),
                   ("fmt_os.tsv", "%OS mit digits.secs")):
    if not os.path.exists(os.path.join(D, file)):
        continue
    nf, n1 = cmp_fmt(file, 5)
    bad += nf
    print("format.Date (%s): %d/%d textgleich" % (what, n1 - nf, n1))
rows = [ln.rstrip("\n").split("\t") for ln in open(os.path.join(D, "parse.tsv"), encoding="utf-8")]
npar = 0
for r in rows:
    v = _ext.slc_r_strptime_ymd(unesc(r[0]), r[1])
    g = "NA" if v is None else "%d" % v
    if g != r[2]:
        npar += 1
        if npar <= 5:
            print("as.Date %r (%s): R %s  Python %s" % (r[0], r[1], r[2], g))
print("as.Date:     %d/%d gleich" % (len(rows) - npar, len(rows)))
print("Gesamt: %s" % ("gleich" if bad + npar == 0 else "ABWEICHUNG"))
sys.exit(1 if bad + npar else 0)
