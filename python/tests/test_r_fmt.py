"""Tests für simlev._r.fmt (Formatierung und Druckausgabe wie R 4.3.3).

Die Referenzfälle stammen aus ``golden/modules/gen_r_fmt.R``; zusätzlich
einige feste Erwartungswerte (in R 4.3.3 ermittelt).
"""
import math
import os

import numpy as np
import pandas as pd
import pytest

from simlev._r import fmt as F
from simlev._r.reftree import load_case, run_case

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "golden", "modules", "r_fmt")
CASES = sorted(f for f in os.listdir(ROOT) if f.endswith(".json.gz")) if os.path.isdir(ROOT) else []
EXACT = np.finfo(np.longdouble).nmant >= 63


@pytest.mark.skipif(not EXACT, reason="formatReal nutzt 80-Bit-long-double (Linux/x86-64)")
@pytest.mark.parametrize("case", CASES)
def test_reference(case):
    errs = run_case(load_case(os.path.join(ROOT, case)))
    assert not errs, "\n".join(errs)


def test_as_character():
    x = np.array([0.1 + 0.2, 1e5, 1e15, 123456.7, 1 / 3, 1e-20, 123456789012345678.0, 2.0 ** 60, -0.0])
    assert list(F.as_character(x)) == ["0.3", "1e+05", "1e+15", "123456.7", "0.333333333333333", "1e-20",
                                       "123456789012345680", "1152921504606846976", "0"]
    assert F.as_character(-7.3639995566896049e-09) == "-7.3639995566896e-09"


def test_round_signif():
    assert F.r_round(0.15, 1) == 0.1
    assert F.r_round(2.675, 2) == 2.67
    assert F.r_round(-2.5) == -2.0
    assert F.r_round(1234.5678, -2) == 1200.0
    assert F.signif(123456, 2) == 120000.0
    assert math.isnan(F.r_round(math.nan, 2))


def test_format_numbers():
    assert list(F.format(np.array([1, 10, 100.5]))) == ["  1.0", " 10.0", "100.5"]
    assert F.format(1234567.891, big_mark=".", decimal_mark=",", nsmall=2) == "1.234.567,89"
    assert F.format(1234.5, big_mark=".", decimal_mark=",", nsmall=2) == "1.234,50"
    assert F.format(1e7, scientific=False) == "10000000"
    assert F.format(100000.0) == "1e+05"
    assert F.format(100000) == "100000"
    assert F.format(1 / 0.85, digits=5) == "1.1765"


def test_format_strings_and_dates():
    assert F.format("Endvermögen", width=14) == "Endvermögen   "
    assert list(F.format(np.array(["a\\b", "x"], dtype=object))) == ["a\\b", "x   "]
    d = np.array(["2024-02-29", "2021-01-03"], dtype="datetime64[D]")
    assert list(F.format_date(d, "%d.%m.%Y")) == ["29.02.2024", "03.01.2021"]
    assert list(F.format_date(d, "%G-%V %u %b %B")) == ["2024-09 4 Feb February", "2020-53 7 Jan January"]


def test_formatC_prettyNum():
    assert F.formatC(1234567.0, format="f", digits=0, big_mark=" ") == "1 234 567"
    assert list(F.formatC(np.array([0, 1.5, 123456.0]), format="fg", width=8, big_mark=" ")) == ["0", "     1.5", " 123 456"]
    assert F.formatC("Öl", width=5) == "   Öl"
    assert F.prettyNum(1234567, big_mark=",") == "1,234,567"


def test_sprintf():
    assert F.sprintf("%5s|%-6s|", "ä", "äb") == "   ä|äb   |"          # Breite in Bytes wie C
    assert F.sprintf("%5.1f|%+.2f|% .1f|%05.1f", F.NA_REAL, math.inf, math.nan, -math.inf) == "   NA|+Inf| NaN| -Inf"
    assert F.sprintf("%s", 1e5) == "1e+05"
    assert F.sprintf("%d", 3.0) == "3"
    assert F.sprintf("%#.3g", 999.5) == "1.e+03"                     # glibc
    assert list(F.sprintf("%a", np.array([1.0, 0.1, 5e-324]))) == ["0x1p+0", "0x1.999999999999ap-4", "0x0.0000000000001p-1022"]
    assert list(F.sprintf("%04d-%02d-01", 2024, np.arange(1, 3))) == ["2024-01-01", "2024-02-01"]
    with pytest.raises(ValueError, match="invalid format '%d'; use format %f, %e, %g or %a for numeric objects"):
        F.sprintf("%d", 1.5)


def test_print_vector():
    x = np.array([1.5, F.NA_REAL, -1e6])
    assert F.print_vector(x) == "[1]  1.5e+00       NA -1.0e+06"
    assert F.print_vector(pd.Series([1.0, 2.5, F.NA_REAL], index=["a", "b", "long name"])) == \
        "        a         b long name \n      1.0       2.5        NA "
    assert F.print_vector(np.array(["a", None], dtype=object), quote=False) == "[1] a    <NA>"
    assert F.print_vector(np.arange(1, 31)) == (
        " [1]  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25\n"
        "[26] 26 27 28 29 30")
    assert F.print_vector(pd.Categorical(["a", "b", None, "a"])) == "[1] a    b    <NA> a   \nLevels: a b"


def test_print_matrix_and_df():
    m = pd.DataFrame([[1.0, 0.25], [-0.5, 10.0]], index=["SPY", "TLT"], columns=["SPY", "TLT"])
    assert F.print_matrix(m) == "     SPY   TLT\nSPY  1.0  0.25\nTLT -0.5 10.00"
    assert F.print_matrix(np.array([[1, 3], [2, 4]])) == "     [,1] [,2]\n[1,]    1    3\n[2,]    2    4"
    d = pd.DataFrame({"a": [1.5, 2.0], "Typ": ["x", None], "ok": [True, False]})
    assert F.print_data_frame(d) == "    a  Typ    ok\n1 1.5    x  TRUE\n2 2.0 <NA> FALSE"
    assert F.print_data_frame(d, row_names=False) == "   a  Typ    ok\n 1.5    x  TRUE\n 2.0 <NA> FALSE"
    assert F.print_data_frame(pd.DataFrame()) == "data frame with 0 columns and 0 rows"


def test_print_list_cat():
    assert F.print_list({"a": 1.0, "b": "x"}) == '$a\n[1] 1\n\n$b\n[1] "x"\n'
    assert F.cat_str(1 / 3, 1e5, True, "x") == "0.3333333 1e+05 TRUE x"
    assert F.cat_str(1, 2, sep="\n") == "1\n2\n"
