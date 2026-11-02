"""N10: Vergleich des Datumskerns core/slc_rbase_date.c (über simlev._ext) mit R (date_fuzz.R).

    python3 tools/gleichlauf/date_fuzz_cmp.py <ordner>
Textgleich heißt: dieselbe Zeichenkette (bzw. beide NA) für format.Date und dieselben Tage für as.Date.
"""
import os
import sys

import numpy as np

sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "python"))
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
bad = 0


def cmp_fmt(file, show):
    rows = [ln.rstrip("\n").split("\t") for ln in open(os.path.join(D, file), encoding="utf-8")]
    z = np.array([float(r[0]) for r in rows])
    nf = 0
    for i, r in enumerate(rows):
        g = fmt._format_date_list(z[i:i + 1], [unesc(r[1])])[0]
        g = "<NA>" if g is None else esc(g)
        if g != r[2]:
            nf += 1
            if nf <= show:
                print("format  Tag %s  Format %r: R %r  Python %r" % (r[0], r[1], r[2], g))
    return nf, len(rows)


nf, n1 = cmp_fmt("fmt.tsv", 5)
print("format.Date (dokumentierte Umwandlungen): %d/%d textgleich" % (n1 - nf, n1))
ns, n2 = cmp_fmt("fmt_sys.tsv", 0)
print("format.Date (systemabhängige Formen, nur Bericht): %d/%d textgleich" % (n2 - ns, n2))
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
print("Gesamt: %s" % ("gleich" if nf + npar == 0 else "ABWEICHUNG"))
sys.exit(1 if nf + npar else 0)
