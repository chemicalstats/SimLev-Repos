"""Verteilungsfunktionen aus R's nmath (R 4.3.3), bitgleich portiert.

Jede Funktion ist ein 1:1-Port des C-Codes aus ``src/nmath/`` (inklusive
aller Verzweigungen, Konstanten und Warnungen). Die öffentlichen Funktionen
tragen die R-Namen und -Argumente (``lower.tail`` → ``lower_tail``,
``log.p`` → ``log_p``) und wenden den skalaren Kern elementweise mit
R-Recycling an (wie ``math2_1``/``math3_2`` in ``stats/src/distn.c``):

- Skalar rein → Skalar raus; sonst ``numpy.ndarray`` in der Form des
  längsten Arguments (``pandas.Series`` bleibt ``Series``).
- ``NA``/``NaN`` in einem Argument ergibt ``NaN`` ohne Warnung.
- Entsteht sonst ein ``NaN``, folgt am Ende die R-Warnung
  ``"NaNs produced"``.

Interne Hilfen als skalare Funktionen (Argumente beliebige Zahlen, werden
zu ``float``), z. B. für das RNG-Modul: ``stirlerr(n)``, ``bd0(x, np)``,
``ebd0(x, M) -> (yh, yl)``, ``lgammacor(x)``, ``chebyshev_eval(x, a, n)``,
``chebyshev_init(dos, nos, eta)``, ``log1pmx(x)``, ``lgamma1p(a)``,
``logspace_add(lx, ly)``, ``logspace_sub(lx, ly)``, ``logspace_sum(lx)``,
``dpois_raw(x, lam, give_log=False)``, ``lgammafn(x)``,
``lgammafn_sign(x) -> (wert, vorzeichen)``, ``gammafn(x)``, ``sinpi``,
``cospi``, ``tanpi``, ``log1pexp``, ``log1mexp``, ``pgamma_raw``,
``pbeta_raw``, ``qchisq_appr``; dazu ``fmax2``, ``fmin2``, ``fsign``,
``imax2``, ``imin2``, ``R_forceint``, ``R_pow``, ``R_pow_di`` (aus ``_cmath``).

Skalare Kerne mit C-Signatur (nur Python-``float`` übergeben, Flags 0/1):
``dnorm4``, ``pnorm5``, ``pnorm_both``, ``qnorm5``, ``dt_``, ``pt_``,
``qt_``, ``pbeta_``, ``lbeta_``, ``beta_``, ``plogis_``, ``qlogis_``,
``dlogis_``, ``pgamma_``, ``qgamma_``, ``dgamma_``, ``pchisq_``,
``qchisq_``, ``dchisq_``, ``pf_``; ``bratio`` in ``_toms708``.

Rechnungen laufen über ``math`` (= glibc-libm) mit C-Semantik an Polstellen
(siehe ``_cmath``); keine numpy-Transzendentalfunktionen, kein scipy.
Nicht portiert: nicht-zentrale Verteilungen (``ncp``-Argument).
"""
from __future__ import annotations

import math
import warnings

import numpy as np
import pandas as pd

from . import _cmath as _c
from ._cmath import (
    DBL_EPSILON, DBL_MANT_DIG, DBL_MAX, DBL_MIN, DBL_MIN_EXP, INF, M_1_PI, M_1_SQRT_2PI, M_2PI,
    M_LN2, M_LN_SQRT_2PI, M_LN_SQRT_PId2, M_PI, M_PI_2, M_SQRT2, M_SQRT_32, NAN, NINF,
    R_Log1_Exp, R_forceint, R_nonint, R_pow, R_pow_di, c_int, c_lgamma, dv, exp, expm1, fmax2,
    fmin2, fmod, fsign, imax2, imin2, ldexp, log, log1p, ml_warning, pow, sqrt, trunc,
)
from ._cmath import logspace_add as _logspace_add, logspace_sub as _logspace_sub
from ._toms708 import bratio

__all__ = [
    "dnorm", "pnorm", "qnorm", "dt", "pt", "qt", "pbeta", "lgamma", "gamma", "lbeta", "beta",
    "plogis", "qlogis", "dlogis", "pchisq", "qchisq", "dchisq", "pgamma", "qgamma", "dgamma",
    "pf", "dpois",
]

_isnan = math.isnan
_pack_d = __import__("struct").Struct("<d").pack
_unpack_Q = __import__("struct").Struct("<Q").unpack
#: R's ``NA_real_`` (NaN mit Nutzlast 1954, signalisierend wie in R)
NA_REAL = __import__("struct").unpack("<d", (0x7FF00000000007A2).to_bytes(8, "little"))[0]


def _isna(x):
    """R_IsNA: NaN mit der Nutzlast 1954 im unteren Wort."""
    return x != x and (_unpack_Q(_pack_d(x))[0] & 0xFFFFFFFF) == 1954


def _na_or_nan(*vals):
    """``if_NA_Math*_set``: NA in einem Argument → NA, sonst NaN → R_NaN."""
    for v in vals:
        if _isna(v):
            return NA_REAL
    return NAN


_isfinite = math.isfinite
_floor = math.floor
_fabs = abs

R_MSG_NA = "NaNs produced"


def _warn_precision(s):
    ml_warning("full precision may not have been achieved in '%s'" % s)


def _warn_range(s):
    ml_warning("value out of range in '%s'" % s)


def _warn_underflow(s):
    ml_warning("underflow occurred in '%s'" % s)


# ══ Chebyshev, lgammacor, stirlerr, bd0 ═══════════════════════════════════

def _chebyshev_init(dos, nos, eta):
    if nos < 1:
        return 0
    err = 0.0
    i = 0
    for ii in range(1, nos + 1):
        i = nos - ii
        err += abs(dos[i])
        if err > eta:
            return i
    return i


def _chebyshev_eval(x, a, n):
    """Chebyshev-Reihe ``a[0:n]`` an der Stelle ``x`` (R's ``chebyshev_eval``)."""
    if n < 1 or n > 1000:
        return NAN
    if x < -1.1 or x > 1.1:
        return NAN
    twox = x * 2
    b2 = b1 = 0.0
    b0 = 0.0
    for i in range(1, n + 1):
        b2 = b1
        b1 = b0
        b0 = twox * b1 - b2 + a[n - i]
    return (b0 - b2) * 0.5


_ALGMCS = (
    +.1666389480451863247205729650822e+0,
    -.1384948176067563840732986059135e-4,
    +.9810825646924729426157171547487e-8,
    -.1809129475572494194263306266719e-10,
    +.6221098041892605227126015543416e-13,
    -.3399615005417721944303330599666e-15,
    +.2683181998482698748957538846666e-17,
    -.2868042435334643284144622399999e-19,
    +.3962837061046434803679306666666e-21,
    -.6831888753985766870111999999999e-23,
    +.1429227355942498147573333333333e-24,
    -.3547598158101070547199999999999e-26,
    +.1025680058010470912000000000000e-27,
    -.3401102254316748799999999999999e-29,
    +.1276642195630062933333333333333e-30,
)


def _lgammacor(x):
    """``lgamma(x) - ((x-0.5)*log(x) - x + log(sqrt(2pi)))`` für ``x >= 10``."""
    nalgm = 5
    xbig = 94906265.62425156
    xmax = 3.745194030963158e306
    if x < 10:
        return NAN
    elif x >= xmax:
        _warn_underflow("lgammacor")
    elif x < xbig:
        tmp = 10 / x
        return _chebyshev_eval(tmp * tmp * 2 - 1, _ALGMCS, nalgm) / x
    return 1 / (x * 12)


_SFERR_HALVES = (
    0.0,
    0.1534264097200273452913848,
    0.0810614667953272582196702,
    0.0548141210519176538961390,
    0.0413406959554092940938221,
    0.03316287351993628748511048,
    0.02767792568499833914878929,
    0.02374616365629749597132920,
    0.02079067210376509311152277,
    0.01848845053267318523077934,
    0.01664469118982119216319487,
    0.01513497322191737887351255,
    0.01387612882307074799874573,
    0.01281046524292022692424986,
    0.01189670994589177009505572,
    0.01110455975820691732662991,
    0.010411265261972096497478567,
    0.009799416126158803298389475,
    0.009255462182712732917728637,
    0.008768700134139385462952823,
    0.008330563433362871256469318,
    0.007934114564314020547248100,
    0.007573675487951840794972024,
    0.007244554301320383179543912,
    0.006942840107209529865664152,
    0.006665247032707682442354394,
    0.006408994188004207068439631,
    0.006171712263039457647532867,
    0.005951370112758847735624416,
    0.005746216513010115682023589,
    0.005554733551962801371038690,
)

_S0 = 0.083333333333333333333
_S1 = 0.00277777777777777777778
_S2 = 0.00079365079365079365079365
_S3 = 0.000595238095238095238095238
_S4 = 0.0008417508417508417508417508


def _stirlerr(n):
    """``log(n!) - log(sqrt(2*pi*n)*(n/e)^n)`` (R 4.3.3 ``stirlerr``)."""
    if n <= 15.0:
        nn = n + n
        if nn == c_int(nn):
            k = c_int(nn)
            if k < 0:   # in C undefiniert (Index < 0); R ruft stirlerr nur mit n >= 0 auf
                return NAN
            return _SFERR_HALVES[k]
        return _lgammafn(n + 1.) - (n + 0.5) * log(n) + n - M_LN_SQRT_2PI
    nn = n * n
    if n > 500:
        return (_S0 - _S1 / nn) / n
    if n > 80:
        return (_S0 - (_S1 - _S2 / nn) / nn) / n
    if n > 35:
        return (_S0 - (_S1 - (_S2 - _S3 / nn) / nn) / nn) / n
    return (_S0 - (_S1 - (_S2 - (_S3 - _S4 / nn) / nn) / nn) / nn) / n


def _bd0(x, np_):
    """Abweichungsterm ``x log(x/np) + np - x`` (Loader), R's ``bd0``."""
    if not _isfinite(x) or not _isfinite(np_) or np_ == 0.0:
        return NAN
    if abs(x - np_) < 0.1 * (x + np_):
        v = (x - np_) / (x + np_)
        s = (x - np_) * v
        if abs(s) < DBL_MIN:
            return s
        ej = 2 * x * v
        v *= v
        for j in range(1, 1000):
            ej *= v
            s_ = s
            s += ej / ((j << 1) + 1)
            if s == s_:
                return s
        ml_warning("_bd0(%g, %g): T.series failed to converge in 1000 it.; s=%g, ej/(2j+1)=%g\n"
                   .rstrip("\n") % (x, np_, s, ej / ((1000 << 1) + 1)))
    return x * log(x / np_) + np_ - x


_BD0_SCALE = (
    (0.6931471824645996, -1.9046542121259336e-09, -8.78318373858934e-17, 3.061840738529369e-24),
    (0.6853040456771851, -4.2578264469739224e-08, -1.1723105396588968e-15, 6.20339263720161e-23),
    (0.6773988008499146, 2.274189014883632e-08, 1.4411920431605914e-15, 7.046384546650164e-23),
    (0.6699305772781372, -4.8293856025338755e-08, -8.664795531738382e-16, 7.049557660755325e-24),
    (0.6624060869216919, -4.791602492559832e-08, -2.161508226230938e-15, 7.092968360825275e-23),
    (0.6548244953155518, 6.237715233226027e-09, 1.1806699607549086e-16, 6.660323533535123e-25),
    (0.6471850872039795, -4.220866856030625e-08, -1.3817589176253094e-15, -1.1159932395766606e-23),
    (0.6400018930435181, -4.979170142860312e-08, 4.887013763907625e-16, 1.6847465694533583e-23),
    (0.6327667236328125, -5.406177194799966e-08, -2.7224545250006775e-15, -2.9070780223955397e-23),
    (0.6249561309814453, 3.285935434860221e-08, 1.201672936775467e-16, -8.668233185091897e-24),
    (0.6181373596191406, -6.406189467789147e-11, 3.550580962335878e-18, -3.623679406748965e-25),
    (0.6107416152954102, 4.229853800552519e-08, 1.548143293520366e-15, -5.446353118719766e-23),
    (0.6032907962799072, 5.515817491641428e-08, 2.1193636784238266e-15, 1.247109826410663e-22),
    (0.5963221788406372, 3.28135385530004e-09, -1.4033469816541837e-16, 5.544061982643074e-24),
    (0.5893045663833618, 4.307998580088679e-08, -3.2446651600595306e-15, -2.569782398567476e-23),
    (0.5822374820709229, -3.983067387025585e-08, 2.9387905513776885e-15, 1.6124430498687833e-22),
    (0.5751199722290039, 2.242384056216906e-09, -2.204516403537114e-17, 4.078543753751354e-25),
    (0.5685046911239624, 4.422870603093543e-08, 2.7879957109977287e-16, -9.741708794029408e-24),
    (0.5618454217910767, 2.147161382026752e-08, 1.3374919170106156e-15, -2.326922260336506e-23),
    (0.554580807685852, 4.57783499996367e-09, 2.633145912141026e-16, 2.070995903387998e-23),
    (0.5478278398513794, -7.667999568639061e-09, 6.199095327775322e-16, 6.341979011056023e-24),
    (0.5410289764404297, -3.7302321231891256e-08, -3.3801781496424835e-15, 1.4469198371142414e-22),
    (0.5347557067871094, 4.382891916066001e-08, -8.601820749692393e-16, -8.775950563978016e-24),
    (0.5278670787811279, 1.0839714903454478e-08, -4.480281248130319e-16, 3.8840996084516777e-23),
    (0.5215104818344116, 4.2031594205127476e-08, 1.211009992711288e-15, -2.3206744819671555e-23),
    (0.5145297050476074, -1.2322940889930578e-08, 2.820084495413274e-16, 1.880026562185923e-23),
    (0.5080875158309937, -1.2297126872340414e-08, -4.295835588700959e-16, -1.8036626177499945e-23),
    (0.5016034841537476, 5.9145378372704727e-08, 1.2728561033550608e-15, -5.824094430019416e-23),
    (0.4950772523880005, 1.4409851090135817e-08, -6.381910184083422e-17, -3.500509376717118e-25),
    (0.48910707235336304, 2.745798610703787e-08, -1.4470418644525664e-15, 4.211866896949939e-23),
    (0.4824984669685364, 1.762245460668055e-08, 4.128675224747099e-16, 2.6082691866392177e-23),
    (0.4764525294303894, -1.2470243504481004e-08, -9.162193924794196e-17, 3.765782542240376e-24),
    (0.469759464263916, -5.450353945946063e-09, -4.304846960468561e-16, 2.074710343707083e-25),
    (0.46363574266433716, -1.7013046527125653e-09, 7.601622738878589e-18, -2.0415879231895994e-25),
    (0.4574742913246155, 6.943684516258486e-10, -2.5461310777374286e-17, 5.5412533419976475e-25),
    (0.4512746334075928, 1.0731865174307131e-08, 6.374000219845047e-16, 3.901547318408994e-23),
    (0.44503629207611084, 2.8650656958006948e-08, -9.155352545558342e-16, -4.7365878254772817e-23),
    (0.43938833475112915, 2.6186132373595683e-08, 1.3619601577579505e-15, -5.2672794844240613e-23),
    (0.4330751895904541, 1.9065733880552216e-08, 1.014319201479946e-15, 1.0145670737413337e-22),
    (0.42735910415649414, -1.141359362577532e-08, 1.3242044582274781e-16, -1.0240055893684678e-23),
    (0.42096930742263794, -1.2778508917676845e-08, 6.143525731270704e-16, 1.419242178938019e-23),
    (0.4151833653450012, -7.767916088141646e-09, 5.955443124124071e-16, 2.732668133771502e-23),
    (0.4093637466430664, 1.8807551072086426e-09, 1.9153331349462894e-16, -5.6208063158075e-24),
    (0.40351009368896484, -2.0416603518924603e-08, -2.93405013148838e-16, 1.894346911970581e-24),
    (0.39762192964553833, 1.0016001361634608e-09, 2.2863242352463633e-17, 9.458133611770764e-25),
    (0.3916988968849182, 1.545909711353488e-08, 1.0962823446210085e-15, 3.108302239821126e-23),
    (0.3864043951034546, -2.076412375373593e-09, 1.5073464810114547e-16, 7.412449454375094e-24),
    (0.38041436672210693, -8.244395388601333e-09, 1.4866224964678982e-16, -3.927292740683968e-24),
    (0.3743882179260254, 9.158529934438775e-09, 5.656919067358501e-16, 3.4213474905617904e-23),
    (0.36900103092193604, -2.2253590969967263e-08, 6.231405399548338e-16, -2.1564751355837555e-23),
    (0.36358463764190674, -2.6778728567933285e-08, -9.943908455716573e-16, -4.704929732945495e-24),
    (0.35745590925216675, -2.033036139437172e-08, -1.5794492077344114e-15, 6.318678032068057e-23),
    (0.3519763946533203, 2.850385882879891e-08, -9.566434575519799e-16, -6.409595040255684e-24),
    (0.3464667797088623, -1.236265312343221e-08, -6.003368248279719e-16, -2.860901497105794e-24),
    (0.3409265875816345, -6.110413286464222e-10, 1.7467136243918857e-17, 1.9962587429804357e-25),
    (0.3353555202484131, 2.167272583619706e-08, -1.0918773497788125e-15, -3.047574780704126e-23),
    (0.33045530319213867, -1.608884048209802e-08, -3.833435008838916e-16, -7.683741875124221e-24),
    (0.3248254060745239, 2.801670362373443e-08, -2.0725720961098414e-16, 1.3160777896524739e-23),
    (0.3191636800765991, 2.6222629401218e-08, -1.3995222573204161e-15, 8.599883909680833e-23),
    (0.31418323516845703, 2.6826626253750874e-08, -9.792556373536439e-16, 2.2954960929108544e-23),
    (0.3084607720375061, 1.368350943664609e-08, 5.591995050742643e-16, -1.1938701403427125e-23),
    (0.3034266233444214, -8.629042369534545e-09, -5.222554219259392e-16, 3.228770766379237e-23),
    (0.2983669638633728, 8.688424202318856e-09, 2.764116793423446e-16, -1.0171858868428321e-23),
    (0.29255300760269165, -4.91631446664087e-09, 2.562284723960507e-16, -2.6341575505102177e-23),
    (0.28743791580200195, -1.3782395669181824e-08, 7.29039351877645e-16, -4.431977943282236e-24),
    (0.28229647874832153, 2.3770866164340987e-08, 6.449228392264254e-16, 3.417536976845211e-23),
    (0.27712851762771606, 1.4733029018998423e-08, 6.793364114448283e-16, 3.593898034032222e-24),
    (0.27193373441696167, -1.8933320689029642e-08, 7.77939410955583e-16, 2.591972424742619e-23),
    (0.2667117714881897, 1.4300387263244119e-11, -7.458876800955772e-19, 4.247418782257993e-26),
    (0.2622140049934387, 7.802219315067305e-09, 5.022431038767539e-16, -2.4063174816868367e-23),
    (0.25694090127944946, 2.9618050234603288e-08, 7.279528203645545e-16, 2.638556081145549e-23),
    (0.2516399025917053, -6.44787778725231e-09, 4.122028133693521e-16, 7.427559296153698e-24),
    (0.2470736801624298, -1.9981829524340355e-09, -1.0909757890855787e-16, 6.236552089808213e-24),
    (0.24171993136405945, 5.523085988556886e-09, -2.686547633696265e-16, -2.764495989170092e-24),
    (0.23710808157920837, 1.0085374313462125e-08, -4.775626813761317e-16, 2.330620598032363e-23),
    (0.231700599193573, -1.3946383603524737e-08, 1.0970921279709183e-17, 3.229909378627549e-25),
    (0.22704219818115234, -6.451284839670279e-09, -4.2529947798112047e-16, -1.0260254677162862e-23),
    (0.2223619818687439, 1.4110645096820917e-08, 6.025568981827254e-16, 1.9385180739531644e-23),
    (0.21765980124473572, -8.286782815503102e-09, 5.232363919579781e-16, 5.078443538654066e-23),
    (0.21214580535888672, -8.254218641923217e-09, 3.255553133321774e-16, 1.571430013634162e-23),
    (0.20739519596099854, -1.6149279691290985e-09, 2.1131592679643073e-17, 1.4275617427027514e-24),
    (0.20262190699577332, 8.597639933327628e-09, -3.3804619056798137e-16, 2.5623235609364303e-24),
    (0.19782572984695435, 1.348296585490516e-08, -3.2024568730231384e-16, -2.5712252251631252e-23),
    (0.1930064558982849, 9.956859781112826e-10, 9.001674563844606e-17, -3.754797654135173e-24),
    (0.1889725625514984, 4.2415360113068346e-09, 3.8086815297465933e-16, -2.1147402916208568e-23),
    (0.18411031365394592, 6.931054841174955e-09, -3.4784858522920016e-16, 2.4665943434547742e-23),
    (0.17922431230545044, 5.0739235035734964e-09, 3.2221329189922637e-16, -1.0379009008973928e-23),
    (0.17431432008743286, 3.794385250444066e-09, 3.190066898587176e-16, 2.0292714723890484e-23),
    (0.17020416259765625, 3.4223344158590407e-09, -1.8846416901959178e-16, 1.1415315069779235e-23),
    (0.16524958610534668, -1.3210039284672348e-08, -2.3213954359040806e-16, 3.043054213286757e-24),
    (0.1602703034877777, 6.007922159767531e-09, -7.521047737154288e-17, -1.2649106048711768e-25),
    (0.15610191226005554, -1.2301535790015805e-08, 3.0175617567361414e-16, -8.633806506327147e-24),
    (0.15191605687141418, -1.4845571882915465e-08, -3.265830289949929e-16, -1.5268151962784823e-23),
    (0.14686977863311768, -4.6748995785605985e-09, -4.294291341758996e-16, 1.328295982896899e-23),
    (0.142645001411438, 9.186472027522541e-09, -8.049373155998929e-16, 1.437998766909278e-23),
    (0.1384023129940033, 9.86511672351753e-09, -8.837306496940929e-16, 7.295324909194215e-24),
    (0.1332872211933136, 9.990350768873668e-10, 3.316946610734358e-17, 2.7351440526086287e-24),
    (0.129004567861557, -7.46120853989396e-09, -6.212113165383437e-16, 1.855187264989731e-24),
    (0.12470348179340363, -3.2924463155836747e-09, -7.404120132741752e-17, 1.3246955625609024e-24),
    (0.12038381397724152, 3.3791991427278845e-09, 1.6214981996371606e-16, -6.00070673940474e-24),
    (0.11604541540145874, 3.5638392237302696e-10, -7.354219635108878e-18, 7.794312440645008e-26),
    (0.11168810725212097, 3.136765958089427e-09, -8.994406293238225e-19, -7.920937558182207e-26),
    (0.10731174051761627, -4.728527791542092e-09, -4.2976339455270984e-16, 5.351143287258107e-24),
    (0.10291612148284912, 2.8332007850906393e-09, 4.925742757234052e-17, 2.794436810397303e-24),
    (0.09850110113620758, 4.970725164810119e-09, 4.130512756847049e-16, 6.313449560595865e-25),
    (0.09406651556491852, -6.525850970717784e-09, -1.3492816627243298e-16, -9.079650179574527e-24),
    (0.08961215615272522, 2.5369617517867482e-09, 1.6110664594961319e-16, -5.189504504486964e-24),
    (0.08603434264659882, -5.304795713811927e-09, 5.127575488441481e-17, 1.463615545692133e-24),
    (0.08154398202896118, 2.0112156384755053e-09, 8.065769331577608e-17, -3.0150319017810437e-24),
    (0.07703337073326111, 5.7495661565099e-09, -2.503851097302985e-16, -1.846143093040508e-23),
    (0.07250232994556427, 1.177662634077592e-09, -3.525476857925506e-17, 1.3164077898906505e-24),
    (0.0688626617193222, -7.043545302565235e-09, 2.49712406751501e-16, 1.0686882487619963e-23),
    (0.06429435312747955, -2.422082090447475e-09, -2.0555896149129847e-16, 8.602907613530545e-24),
    (0.0606246218085289, 7.905943261166115e-12, -8.270443345471096e-19, -2.3533820836754142e-26),
    (0.056018441915512085, -5.139745296034448e-10, -3.811651571366802e-17, 1.9072195442219776e-24),
    (0.052318163216114044, -3.5574325707443677e-09, 9.191155834145393e-17, -5.321463973420977e-24),
    (0.04767347127199173, -1.8026349302147082e-09, 1.0329634289704177e-16, -2.2283569301283993e-24),
    (0.04394212365150452, -1.795005699634089e-09, -5.3817402974104447e-17, -1.3996196977941442e-24),
    (0.040196798741817474, 3.8451930528538014e-10, -2.4485452721520977e-17, -7.386769024377949e-26),
    (0.0354953333735466, -3.5901653872016936e-10, -2.073207767866976e-17, -2.412097216555168e-26),
    (0.0317181795835495, 6.87235046648027e-10, -6.430478093749473e-18, 1.3508692031871337e-25),
    (0.02792670577764511, 7.568773385813188e-10, -4.22031585165944e-17, 2.534760563692782e-24),
    (0.02412080392241478, -1.1255707477175747e-09, 4.89700584100947e-17, 1.4172214525647275e-24),
    (0.01934296265244484, 1.9068610579431322e-10, -1.0635946218849709e-17, -5.300489542457734e-25),
    (0.015504186972975731, -4.3701048335620385e-10, 6.61106154763715e-18, 2.5398086818405174e-25),
    (0.01165061630308628, 9.168890091615367e-10, -1.5848697818454755e-17, -1.350491609984469e-24),
    (0.007782140746712685, -3.046577434773212e-10, 7.793435996762285e-18, 4.660100148208369e-25),
    (0.0038986406289041042, -2.1324678134426733e-10, 1.2541658163801307e-19, 8.745035431740123e-27),
    (0.0, 0.0, 0.0, 0.0),
)


def _ebd0(x, M):
    """``x log(x/M) + M - x`` in zwei Teilen ``(yh, yl)`` (R's ``ebd0``)."""
    Sb = 10
    S = 1024.0
    N = 128
    yl = yh = 0.0
    if x == M:
        return yh, yl
    if x == 0:
        return M, yl
    if M == 0:
        return INF, yl
    if dv(M, x) == INF:
        return M, yl
    r, e = math.frexp(M / x)
    if M_LN2 * float(-e) > 1. + DBL_MAX / x:
        return INF, yl
    i = c_int(_c.floor((r - 0.5) * (2 * N) + 0.5))
    f = _c.floor(dv(S, 0.5 + i / (2.0 * N)) + 0.5)
    fg = ldexp(f, -(e + Sb))
    if fg == INF:
        return fg, yl
    if not 0 <= i <= N:   # nur bei NaN-Argumenten (in C undefiniert)
        return NAN, yl

    def add1(d, yh, yl):
        d1 = _c.floor(d + 0.5)
        d2 = d - d1
        return yh + d1, yl + d2

    yh, yl = add1(-x * _log1pmx((M * fg - x) / x), yh, yl)
    if fg == 1:
        return yh, yl
    sc_i = _BD0_SCALE[i]
    sc_0 = _BD0_SCALE[0]
    for j in range(4):
        yh, yl = add1(x * sc_i[j], yh, yl)
        yh, yl = add1(-x * sc_0[j] * e, yh, yl)
        if not _isfinite(yh):
            return INF, 0.0
    yh, yl = add1(M, yh, yl)
    yh, yl = add1(-M * fg, yh, yl)
    return yh, yl


_M_SQRT_2PI = 2.50662827463100050241576528481104525301
_X_LRG = 2.86111748575702815380240589208115399625e+307


def _dpois_raw(x, lam, give_log):
    """Poisson-Dichte für reelles ``x >= 0`` (R's ``dpois_raw``)."""
    if lam == 0:
        if x == 0:
            return 0.0 if give_log else 1.0
        return NINF if give_log else 0.0
    if not _isfinite(lam):
        return NINF if give_log else 0.0
    if x < 0:
        return NINF if give_log else 0.0
    if x <= lam * DBL_MIN:
        return -lam if give_log else exp(-lam)
    if lam < x * DBL_MIN:
        if not _isfinite(x):
            return NINF if give_log else 0.0
        v = -lam + x * log(lam) - _lgammafn(x + 1)
        return v if give_log else exp(v)
    yh, yl = _ebd0(x, lam)
    yl += _stirlerr(x)
    Lrg_x = x >= _X_LRG
    r = _M_SQRT_2PI * sqrt(x) if Lrg_x else M_2PI * x
    if give_log:
        return -yl - yh - (log(r) if Lrg_x else 0.5 * log(r))
    return exp(-yl) * exp(-yh) / (r if Lrg_x else sqrt(r))


def _dpois(x, lam, give_log):
    if _isnan(x) or _isnan(lam):
        return x + lam
    if lam < 0:
        return NAN
    if R_nonint(x):
        ml_warning("non-integer x = %f" % x)
        return NINF if give_log else 0.0
    if x < 0 or not _isfinite(x):
        return NINF if give_log else 0.0
    x = R_forceint(x)
    return _dpois_raw(x, lam, give_log)


# ══ gamma, lgamma, beta ════════════════════════════════════════════════════

def _sinpi(x):
    if _isnan(x):
        return x
    if not _isfinite(x):
        return NAN
    x = fmod(x, 2.)
    if x <= -1:
        x += 2.
    elif x > 1.:
        x -= 2.
    if x == 0. or x == 1.:
        return 0.
    if x == 0.5:
        return 1.
    if x == -0.5:
        return -1.
    return _c.sin(M_PI * x)


def _cospi(x):
    if _isnan(x):
        return x
    if not _isfinite(x):
        return NAN
    x = fmod(abs(x), 2.)
    if fmod(x, 1.) == 0.5:
        return 0.
    if x == 1.:
        return -1.
    if x == 0.:
        return 1.
    return _c.cos(M_PI * x)


def _tanpi(x):
    """R's ``Rtanpi`` (glibc 2.39 hat kein ``tanpi``)."""
    if _isnan(x):
        return x
    if not _isfinite(x):
        return NAN
    x = fmod(x, 1.)
    if x <= -0.5:
        x += 1
    elif x > 0.5:
        x -= 1
    if x == 0.:
        return 0.
    if x == 0.5:
        return NAN
    if x == 0.25:
        return 1.
    if x == -0.25:
        return -1.
    return _c.tan(M_PI * x)


_GAMCS = (
    +.8571195590989331421920062399942e-2,
    +.4415381324841006757191315771652e-2,
    +.5685043681599363378632664588789e-1,
    -.4219835396418560501012500186624e-2,
    +.1326808181212460220584006796352e-2,
    -.1893024529798880432523947023886e-3,
    +.3606925327441245256578082217225e-4,
    -.6056761904460864218485548290365e-5,
    +.1055829546302283344731823509093e-5,
    -.1811967365542384048291855891166e-6,
    +.3117724964715322277790254593169e-7,
    -.5354219639019687140874081024347e-8,
    +.9193275519859588946887786825940e-9,
    -.1577941280288339761767423273953e-9,
    +.2707980622934954543266540433089e-10,
    -.4646818653825730144081661058933e-11,
    +.7973350192007419656460767175359e-12,
    -.1368078209830916025799499172309e-12,
    +.2347319486563800657233471771688e-13,
    -.4027432614949066932766570534699e-14,
    +.6910051747372100912138336975257e-15,
    -.1185584500221992907052387126192e-15,
    +.2034148542496373955201026051932e-16,
    -.3490054341717405849274012949108e-17,
    +.5987993856485305567135051066026e-18,
    -.1027378057872228074490069778431e-18,
    +.1762702816060529824942759660748e-19,
    -.3024320653735306260958772112042e-20,
    +.5188914660218397839717833550506e-21,
    -.8902770842456576692449251601066e-22,
    +.1527474068493342602274596891306e-22,
    -.2620731256187362900257328332799e-23,
    +.4496464047830538670331046570666e-24,
    -.7714712731336877911703901525333e-25,
    +.1323635453126044036486572714666e-25,
    -.2270999412942928816702313813333e-26,
    +.3896418998003991449320816639999e-27,
    -.6685198115125953327792127999999e-28,
    +.1146998663140024384347613866666e-28,
    -.1967938586345134677295103999999e-29,
    +.3376448816585338090334890666666e-30,
    -.5793070335782135784625493333333e-31,
)

_G_NGAM = 22
_G_XMIN = -170.5674972726612
_G_XMAX = 171.61447887182298
_G_XSML = 2.2474362225598545e-308
_G_DXREL = 1.490116119384765696e-8


def _gammafn(x):
    """Gammafunktion (R's ``gammafn``)."""
    if _isnan(x):
        return x
    if x == 0 or (x < 0 and (not _isfinite(x) or x == _floor(x))):
        return NAN
    y = abs(x)
    if y <= 10:
        n = int(x)
        if x < 0:
            n -= 1
        y = x - n
        n -= 1
        value = _chebyshev_eval(y * 2 - 1, _GAMCS, _G_NGAM) + .9375
        if n == 0:
            return value
        if n < 0:
            if x < -0.5 and abs(x - int(x - 0.5) / x) < _G_DXREL:
                _warn_precision("gammafn")
            if y < _G_XSML:
                _warn_range("gammafn")
                if x > 0:
                    return INF
                else:
                    return NINF
            n = -n
            for i in range(n):
                value /= (x + i)
            return value
        else:
            for i in range(1, n + 1):
                value *= (y + i)
            return value
    else:
        if x > _G_XMAX:
            return INF
        if x < _G_XMIN:
            return 0.
        if y <= 50 and y == int(y):
            value = 1.
            for i in range(2, int(y)):
                value *= i
        else:
            # (2*y == (int)2*y) ist in C immer wahr ((int)2 * y)
            value = exp((y - 0.5) * log(y) - y + M_LN_SQRT_2PI + _stirlerr(y))
        if x > 0:
            return value
        if abs((x - int(x - 0.5)) / x) < _G_DXREL:
            _warn_precision("gammafn")
        sinpiy = _sinpi(y)
        if sinpiy == 0:
            _warn_range("gammafn")
            return INF
        return -M_PI / (y * sinpiy * value)


_LG_XMAX = 2.5327372760800758e+305
_LG_DXREL = 1.490116119384765625e-8


def _lgammafn_sign(x):
    """``(lgamma(x), sign(gamma(x)))`` wie R's ``lgammafn_sign``."""
    sgn = 1
    if _isnan(x):
        return x, sgn
    if x < 0 and fmod(_c.floor(-x), 2.) == 0:
        sgn = -1
    if x <= 0 and x == trunc(x):
        return INF, sgn
    y = abs(x)
    if y < 1e-306:
        return -log(y), sgn
    if y <= 10:
        return log(abs(_gammafn(x))), sgn
    if y > _LG_XMAX:
        return INF, sgn
    if x > 0:
        if x > 1e17:
            return x * (log(x) - 1.), sgn
        elif x > 4934720.:
            return M_LN_SQRT_2PI + (x - 0.5) * log(x) - x, sgn
        else:
            return M_LN_SQRT_2PI + (x - 0.5) * log(x) - x + _lgammacor(x), sgn
    sinpiy = abs(_sinpi(y))
    if sinpiy == 0:  # pragma: no cover - oben abgefangen
        ml_warning(" ** should NEVER happen! *** [lgamma.c: Neg.int, y=%g]\n".rstrip("\n") % y)
        return NAN, sgn
    ans = M_LN_SQRT_PId2 + (x - 0.5) * log(y) - x - log(sinpiy) - _lgammacor(y)
    if abs((x - trunc(x - 0.5)) * ans / x) < _LG_DXREL:
        _warn_precision("lgamma")
    return ans, sgn


def _lgammafn(x):
    """``log|Gamma(x)|`` (R's ``lgammafn``, nicht C-``lgamma``)."""
    if _isnan(x):
        return x
    if x <= 0 and x == trunc(x):
        return INF
    y = abs(x)
    if y < 1e-306:
        return -log(y)
    if y <= 10:
        return log(abs(_gammafn(x)))
    if y > _LG_XMAX:
        return INF
    if x > 0:
        if x > 1e17:
            return x * (log(x) - 1.)
        elif x > 4934720.:
            return M_LN_SQRT_2PI + (x - 0.5) * log(x) - x
        else:
            return M_LN_SQRT_2PI + (x - 0.5) * log(x) - x + _lgammacor(x)
    return _lgammafn_sign(x)[0]


def lbeta_(a, b):
    """``log(beta(a, b))`` (R's ``lbeta``)."""
    if _isnan(a) or _isnan(b):
        return a + b
    p = q = a
    if b < p:
        p = b
    if b > q:
        q = b
    if p < 0:
        return NAN
    elif p == 0:
        return INF
    elif not _isfinite(q):
        return NINF
    if p >= 10:
        corr = _lgammacor(p) + _lgammacor(q) - _lgammacor(p + q)
        return log(q) * -0.5 + M_LN_SQRT_2PI + corr \
            + (p - 0.5) * log(p / (p + q)) + q * log1p(-p / (p + q))
    elif q >= 10:
        corr = _lgammacor(q) - _lgammacor(p + q)
        return _lgammafn(p) + corr + p - p * log(p + q) \
            + (q - 0.5) * log1p(-p / (p + q))
    else:
        if p < 1e-306:
            return c_lgamma(p) + (c_lgamma(q) - c_lgamma(p + q))
        else:
            return log(_gammafn(p) * (_gammafn(q) / _gammafn(p + q)))


def beta_(a, b):
    """Betafunktion (R's ``beta``)."""
    xmax = 171.61447887182298
    if _isnan(a) or _isnan(b):
        return a + b
    if a < 0 or b < 0:
        return NAN
    elif a == 0 or b == 0:
        return INF
    elif not _isfinite(a) or not _isfinite(b):
        return 0.
    if a + b < xmax:
        return dv(1, _gammafn(a + b)) * _gammafn(a) * _gammafn(b)
    else:
        val = lbeta_(a, b)
        return exp(val)


# ══ Normalverteilung ══════════════════════════════════════════════════════

_DNORM_BIG = 2 * math.sqrt(DBL_MAX)
_DNORM_UFL = math.sqrt(-2 * M_LN2 * (DBL_MIN_EXP + 1 - DBL_MANT_DIG))


def dnorm4(x, mu, sigma, give_log):
    if _isnan(x) or _isnan(mu) or _isnan(sigma):
        return x + mu + sigma
    if sigma < 0:
        return NAN
    if not _isfinite(sigma):
        return NINF if give_log else 0.
    if not _isfinite(x) and mu == x:
        return NAN
    if sigma == 0:
        return INF if (x == mu) else (NINF if give_log else 0.)
    x = (x - mu) / sigma
    if not _isfinite(x):
        return NINF if give_log else 0.
    x = abs(x)
    if x >= _DNORM_BIG:
        return NINF if give_log else 0.
    if give_log:
        return -(M_LN_SQRT_2PI + 0.5 * x * x + log(sigma))
    if x < 5:
        return M_1_SQRT_2PI * exp(-0.5 * x * x) / sigma
    if x > _DNORM_UFL:
        return 0.
    x1 = ldexp(R_forceint(ldexp(x, 16)), -16)
    x2 = x - x1
    return M_1_SQRT_2PI / sigma * (exp(-0.5 * x1 * x1) * exp((-0.5 * x2 - x1) * x2))


def pnorm5(x, mu, sigma, lower_tail, log_p):
    if _isnan(x) or _isnan(mu) or _isnan(sigma):
        return x + mu + sigma
    if not _isfinite(x) and mu == x:
        return NAN
    if sigma <= 0:
        if sigma < 0:
            return NAN
        if x < mu:
            return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
        return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
    p = (x - mu) / sigma
    if not _isfinite(p):
        if x < mu:
            return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
        return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
    x = p
    cum, ccum = pnorm_both(x, 0 if lower_tail else 1, log_p)
    return cum if lower_tail else ccum


_PN_A = (2.2352520354606839287, 161.02823106855587881, 1067.6894854603709582,
         18154.981253343561249, 0.065682337918207449113)
_PN_B = (47.20258190468824187, 976.09855173777669322, 10260.932208618978205,
         45507.789335026729956)
_PN_C = (0.39894151208813466764, 8.8831497943883759412, 93.506656132177855979,
         597.27027639480026226, 2494.5375852903726711, 6848.1904505362823326,
         11602.651437647350124, 9842.7148383839780218, 1.0765576773720192317e-8)
_PN_D = (22.266688044328115691, 235.38790178262499861, 1519.377599407554805,
         6485.558298266760755, 18615.571640885098091, 34900.952721145977266,
         38912.003286093271411, 19685.429676859990727)
_PN_P = (0.21589853405795699, 0.1274011611602473639, 0.022235277870649807,
         0.001421619193227893466, 2.9112874951168792e-5, 0.02307344176494017303)
_PN_Q = (1.28426009614491121, 0.468238212480865118, 0.0659881378689285515,
         0.00378239633202758244, 7.29751555083966205e-5)
_PN_EPS = DBL_EPSILON * 0.5
_ldexp = math.ldexp
_mtrunc = math.trunc
_mlog = math.log
_mexp = math.exp


def pnorm_both(x, i_tail, log_p):
    """``(cum, ccum)`` wie R's ``pnorm_both`` (``i_tail`` 0/1/2 = unten/oben/beide)."""
    cum = ccum = NAN
    if _isnan(x):
        return x, x
    eps = _PN_EPS
    lower = i_tail != 1
    upper = i_tail != 0
    y = abs(x)
    if y <= 0.67448975:
        if y > eps:
            a = _PN_A
            b = _PN_B
            xsq = x * x
            xnum = a[4] * xsq
            xden = xsq
            for i in range(3):
                xnum = (xnum + a[i]) * xsq
                xden = (xden + b[i]) * xsq
        else:
            xnum = xden = 0.0
        temp = x * (xnum + _PN_A[3]) / (xden + _PN_B[3])
        if lower:
            cum = 0.5 + temp
        if upper:
            ccum = 0.5 - temp
        if log_p:
            if lower:
                cum = log(cum)
            if upper:
                ccum = log(ccum)
        return cum, ccum
    elif y <= M_SQRT_32:
        c = _PN_C
        d = _PN_D
        xnum = c[8] * y
        xden = y
        for i in range(7):
            xnum = (xnum + c[i]) * y
            xden = (xden + d[i]) * y
        temp = (xnum + c[7]) / (xden + d[7])
        X = y
    elif (log_p and y < 1e170) or (lower and -37.5193 < x < 8.2924) \
            or (upper and -8.2924 < x < 37.5193):
        p = _PN_P
        q = _PN_Q
        xsq = 1.0 / (x * x)
        xnum = p[5] * xsq
        xden = xsq
        for i in range(4):
            xnum = (xnum + p[i]) * xsq
            xden = (xden + q[i]) * xsq
        temp = xsq * (xnum + p[4]) / (xden + q[4])
        temp = (M_1_SQRT_2PI - temp) / y
        X = x
    else:
        if x > 0:
            return (0. if log_p else 1.), (NINF if log_p else 0.)
        return (NINF if log_p else 0.), (0. if log_p else 1.)

    # do_del(X)
    xsq = _ldexp(float(_mtrunc(_ldexp(X, 4))), -4)
    dl = (X - xsq) * (X + xsq)
    if log_p:
        cum = (-xsq * _ldexp(xsq, -1)) - _ldexp(dl, -1) + log(temp)
        if (lower and x > 0.) or (upper and x <= 0.):
            ccum = log1p(-exp(-xsq * _ldexp(xsq, -1)) * exp(-_ldexp(dl, -1)) * temp)
    else:
        cum = exp(-xsq * _ldexp(xsq, -1)) * exp(-_ldexp(dl, -1)) * temp
        ccum = 1.0 - cum
    # swap_tail
    if x > 0.:
        temp = cum
        if lower:
            cum = ccum
        ccum = temp
    return cum, ccum


def qnorm5(p, mu, sigma, lower_tail, log_p):
    if _isnan(p) or _isnan(mu) or _isnan(sigma):
        return p + mu + sigma
    # R_Q_P01_boundaries(p, ML_NEGINF, ML_POSINF)
    if log_p:
        if p > 0:
            return NAN
        if p == 0:
            return INF if lower_tail else NINF
        if p == NINF:
            return NINF if lower_tail else INF
    else:
        if p < 0 or p > 1:
            return NAN
        if p == 0:
            return NINF if lower_tail else INF
        if p == 1:
            return INF if lower_tail else NINF
    if sigma < 0:
        return NAN
    if sigma == 0:
        return mu

    if log_p:
        p_ = exp(p) if lower_tail else -expm1(p)
    else:
        p_ = p if lower_tail else (0.5 - p + 0.5)
    q = p_ - 0.5

    if abs(q) <= .425:
        r = .180625 - q * q
        val = q * (((((((r * 2509.0809287301226727 +
                         33430.575583588128105) * r + 67265.770927008700853) * r +
                       45921.953931549871457) * r + 13731.693765509461125) * r +
                     1971.5909503065514427) * r + 133.14166789178437745) * r +
                   3.387132872796366608) \
            / (((((((r * 5226.495278852854561 +
                     28729.085735721942674) * r + 39307.89580009271061) * r +
                   21213.794301586595867) * r + 5394.1960214247511077) * r +
                 687.1870074920579083) * r + 42.313330701600911252) * r + 1.)
    else:
        if log_p and ((lower_tail and q <= 0) or (not lower_tail and q > 0)):
            lp = p
        else:
            if q > 0:
                if log_p:
                    arg = -expm1(p) if lower_tail else exp(p)
                else:
                    arg = (0.5 - p + 0.5) if lower_tail else p
            else:
                arg = p_
            lp = log(arg)
        r = sqrt(-lp)
        if r <= 5.:
            r += -1.6
            val = (((((((r * 7.7454501427834140764e-4 +
                         .0227238449892691845833) * r + .24178072517745061177) *
                       r + 1.27045825245236838258) * r +
                      3.64784832476320460504) * r + 5.7694972214606914055) *
                    r + 4.6303378461565452959) * r +
                   1.42343711074968357734) \
                / (((((((r *
                         1.05075007164441684324e-9 + 5.475938084995344946e-4) *
                        r + .0151986665636164571966) * r +
                       .14810397642748007459) * r + .68976733498510000455) *
                     r + 1.6763848301838038494) * r +
                    2.05319162663775882187) * r + 1.)
        elif r <= 27:
            r += -5.
            val = (((((((r * 2.01033439929228813265e-7 +
                         2.71155556874348757815e-5) * r +
                        .0012426609473880784386) * r + .026532189526576123093) *
                      r + .29656057182850489123) * r +
                     1.7848265399172913358) * r + 5.4637849111641143699) *
                   r + 6.6579046435011037772) \
                / (((((((r *
                         2.04426310338993978564e-15 + 1.4215117583164458887e-7) *
                        r + 1.8463183175100546818e-5) * r +
                       7.868691311456132591e-4) * r + .0148753612908506148525)
                     * r + .13692988092273580531) * r +
                    .59983220655588793769) * r + 1.)
        else:
            if r >= 6.4e8:
                val = r * M_SQRT2
            else:
                s2 = -ldexp(lp, 1)
                x2 = s2 - log(M_2PI * s2)
                if r < 36000.:
                    x2 = s2 - log(M_2PI * x2) - 2. / (2. + x2)
                    if r < 840.:
                        x2 = s2 - log(M_2PI * x2) + 2 * log1p(- (1 - 1 / (4 + x2)) / (2. + x2))
                        if r < 109.:
                            x2 = s2 - log(M_2PI * x2) + \
                                2 * log1p(- (1 - (1 - 5 / (6 + x2)) / (4. + x2)) / (2. + x2))
                            if r < 55.:
                                x2 = s2 - log(M_2PI * x2) + \
                                    2 * log1p(- (1 - (1 - (5 - 9 / (8. + x2)) / (6. + x2))
                                                 / (4. + x2)) / (2. + x2))
                val = sqrt(x2)
        if q < 0.0:
            val = -val
    return mu + sigma * val


# ══ t-Verteilung ══════════════════════════════════════════════════════════

_DT_T = {}   # dt(): nur von n abhängiger Term (n > 0 endlich)


def dt_(x, n, give_log):
    if _isnan(x) or _isnan(n):
        return x + n
    if n <= 0:
        return NAN
    if not _isfinite(x):
        return NINF if give_log else 0.
    if not _isfinite(n):
        return dnorm4(x, 0., 1., give_log)

    t = _DT_T.get(n)
    if t is None:
        t = -_bd0(n / 2., (n + 1) / 2.) + _stirlerr((n + 1) / 2.) - _stirlerr(n / 2.)
        if len(_DT_T) > 4096:
            _DT_T.clear()
        _DT_T[n] = t
    x2n = x * x / n
    ax = 0.
    lrg_x2n = x2n > 1. / DBL_EPSILON
    if lrg_x2n:
        ax = abs(x)
        l_x2n = log(ax) - log(n) / 2.
        u = n * l_x2n
    elif x2n > 0.2:
        l_x2n = log(1 + x2n) / 2.
        u = n * l_x2n
    else:
        l_x2n = log1p(x2n) / 2.
        u = -_bd0(n / 2., (n + x * x) / 2.) + x * x / 2.

    if give_log:
        return t - u - (M_LN_SQRT_2PI + l_x2n)
    I_sqrt_ = (sqrt(n) / ax) if lrg_x2n else exp(-l_x2n)
    return exp(t - u) * M_1_SQRT_2PI * I_sqrt_


def pt_(x, n, lower_tail, log_p):
    if _isnan(x) or _isnan(n):
        return x + n
    if n <= 0.0:
        return NAN
    if not _isfinite(x):
        if x < 0:
            return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
        return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
    if not _isfinite(n):
        return pnorm5(x, 0.0, 1.0, lower_tail, log_p)

    nx = 1 + (x / n) * x
    if nx > 1e100:
        lval = -0.5 * n * (2 * log(abs(x)) - log(n)) - lbeta_(0.5 * n, 0.5) - log(0.5 * n)
        val = lval if log_p else exp(lval)
    else:
        if n > x * x:
            val = pbeta_(x * x / (n + x * x), 0.5, n / 2., 0, log_p)
        else:
            val = pbeta_(1. / nx, n / 2., 0.5, 1, log_p)

    if x <= 0.:
        lower_tail = not lower_tail

    if log_p:
        if lower_tail:
            return log1p(-0.5 * exp(val))
        else:
            return val - M_LN2
    else:
        val /= 2.
        return val if not lower_tail else (0.5 - val + 0.5)


def qt_(p, ndf, lower_tail, log_p):
    eps = 1.e-12
    if _isnan(p) or _isnan(ndf):
        return p + ndf
    # R_Q_P01_boundaries(p, ML_NEGINF, ML_POSINF)
    if log_p:
        if p > 0:
            return NAN
        if p == 0:
            return INF if lower_tail else NINF
        if p == NINF:
            return NINF if lower_tail else INF
    else:
        if p < 0 or p > 1:
            return NAN
        if p == 0:
            return NINF if lower_tail else INF
        if p == 1:
            return INF if lower_tail else NINF

    if ndf <= 0:
        return NAN

    if ndf < 1:
        accu = 1e-13
        Eps = 1e-11
        iter_ = 0
        # p = R_DT_qIv(p)
        if log_p:
            p = exp(p) if lower_tail else -expm1(p)
        else:
            p = p if lower_tail else (0.5 - p + 0.5)
        if p > 1 - DBL_EPSILON:
            return INF
        pp = fmin2(1 - DBL_EPSILON, p * (1 + Eps))
        ux = 1.
        while ux < DBL_MAX and pt_(ux, ndf, True, False) < pp:
            ux *= 2
        pp = p * (1 - Eps)
        lx = -1.
        while lx > -DBL_MAX and pt_(lx, ndf, True, False) > pp:
            lx *= 2
        while True:
            nx = 0.5 * (lx + ux)
            if pt_(nx, ndf, True, False) > p:
                ux = nx
            else:
                lx = nx
            if not (dv(ux - lx, abs(nx)) > accu):
                break
            iter_ += 1
            if not (iter_ < 1000):
                break
        if iter_ >= 1000:
            _warn_precision("qt")
        return 0.5 * (lx + ux)

    if ndf > 1e20:
        return qnorm5(p, 0., 1., lower_tail, log_p)

    P = exp(p) if log_p else p  # R_D_qIv(p)

    neg = (not lower_tail or P < 0.5) and (lower_tail or P > 0.5)
    is_neg_lower = (lower_tail == neg)
    if neg:
        P = 2 * ((P if lower_tail else -expm1(p)) if log_p else (p if lower_tail else (0.5 - p + 0.5)))
    else:
        P = 2 * ((-expm1(p) if lower_tail else P) if log_p else ((0.5 - p + 0.5) if lower_tail else p))

    if abs(ndf - 2) < eps:
        if P > DBL_MIN:
            if 3 * P < DBL_EPSILON:
                q = 1 / sqrt(P)
            elif P > 0.9:
                q = (1 - P) * sqrt(2 / (P * (2 - P)))
            else:
                q = sqrt(2 / (P * (2 - P)) - 2)
        else:
            if log_p:
                q = (exp(- p / 2) / M_SQRT2) if is_neg_lower else dv(1, sqrt(-expm1(p)))
            else:
                q = INF
    elif ndf < 1 + eps:
        if P == 1.:
            q = 0.0
        elif P > 0:
            q = dv(1, _tanpi(P / 2.))
        else:
            if log_p:
                q = (M_1_PI * exp(-p)) if is_neg_lower else dv(-1., (M_PI * expm1(p)))
            else:
                q = INF
    else:
        x = 0.
        log_P2 = 0.
        a = 1 / (ndf - 0.5)
        b = 48 / (a * a)
        c = ((20700 * a / b - 98) * a - 16) * a + 96.36
        d = ((94.5 / (b + c) - 3) / b + 1) * sqrt(a * M_PI_2) * ndf
        P_ok1 = P > DBL_MIN or not log_p
        P_ok = P_ok1
        y = 0.
        if P_ok1:
            y = pow(d * P, 2.0 / ndf)
            P_ok = (y >= DBL_EPSILON)
        if not P_ok:
            if is_neg_lower:
                log_P2 = p if log_p else log(p)            # R_D_log(p)
            else:
                log_P2 = R_Log1_Exp(p) if log_p else log1p(-p)   # R_D_LExp(p)
            x = (log(d) + M_LN2 + log_P2) / ndf
            y = exp(2 * x)

        if (ndf < 2.1 and P > 0.5) or y > 0.05 + a:
            if P_ok:
                x = qnorm5(0.5 * P, 0., 1., True, False)
            else:
                x = qnorm5(log_P2, 0., 1., lower_tail, True)
            y = x * x
            if ndf < 5:
                c += 0.3 * (ndf - 4.5) * (x + 0.6)
            c = (((0.05 * d * x - 5) * x - 7) * x - 2) * x + b + c
            y = (((((0.4 * y + 6.3) * y + 36) * y + 94.5) / c
                  - y - 3) / b + 1) * x
            y = expm1(a * y * y)
            q = sqrt(ndf * y)
        elif not P_ok and x < - M_LN2 * DBL_MANT_DIG:
            q = sqrt(ndf) * exp(-x)
        else:
            inner = dv(ndf + 6, ndf * y) - 0.089 * d - 0.822
            y = ((dv(1, inner * (ndf + 2) * 3) + 0.5 / (ndf + 4))
                 * y - 1) * (ndf + 1) / (ndf + 2) + dv(1, y)
            q = sqrt(ndf * y)

        if P_ok1:
            M = abs(math.sqrt(DBL_MAX / 2.) - ndf)
            it = 0
            while True:
                it += 1
                if not (it - 1 < 10):
                    break
                y = dt_(q, ndf, False)
                if not (y > 0):
                    break
                x = (pt_(q, ndf, False, False) - P / 2) / y
                if not _isfinite(x):
                    break
                if not (abs(x) > 1e-14 * abs(q)):
                    break
                F = (q * (ndf + 1) / (2 * (q * q + ndf))) if (abs(q) < M) else \
                    ((ndf + 1) / (2 * (q + ndf / q)))
                del_q = x * (1. + x * F)
                if _isfinite(del_q) and _isfinite(q + del_q):
                    q += del_q
                elif _isfinite(x) and _isfinite(q + x):
                    q += x
                else:
                    break
    return -q if neg else q


# ══ Beta ══════════════════════════════════════════════════════════════════

def _pbeta_raw(x, a, b, lower_tail, log_p):
    if x >= 1:
        return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
    if a == 0 or b == 0 or not _isfinite(a) or not _isfinite(b):
        if a == 0 and b == 0:
            return -M_LN2 if log_p else 0.5
        if a == 0 or dv(a, b) == 0:
            return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
        if b == 0 or dv(b, a) == 0:
            return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
        if x < 0.5:
            return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
        return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
    if x <= 0:
        return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
    x1 = 0.5 - x + 0.5
    w, wc, ierr = bratio(a, b, x, x1, log_p)
    if ierr and ierr != 11 and ierr != 14:
        ml_warning("_pbeta_raw(%g, a=%g, b=%g, lower=%d, log=%d) -> bratio() gave error code %d"
                   % (x, a, b, int(bool(lower_tail)), int(bool(log_p)), ierr))
    return w if lower_tail else wc


def pbeta_(x, a, b, lower_tail, log_p):
    if _isnan(x) or _isnan(a) or _isnan(b):
        return x + a + b
    if a < 0 or b < 0:
        return NAN
    return _pbeta_raw(x, a, b, lower_tail, log_p)


# ══ Logistische Verteilung ════════════════════════════════════════════════

def _log1pexp(x):
    """``log(1 + exp(x))`` ohne Überlauf (R's ``log1pexp``)."""
    if x <= 18.:
        return log1p(exp(x))
    if x > 33.3:
        return x
    return x + exp(-x)


def _log1mexp(x):
    return R_Log1_Exp(-x)


def plogis_(x, location, scale, lower_tail, log_p):
    if _isnan(x) or _isnan(location) or _isnan(scale):
        return x + location + scale
    if scale <= 0.0:
        return NAN
    x = (x - location) / scale
    if _isnan(x):
        return NAN
    if not _isfinite(x):
        if x > 0:
            return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
        return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
    if log_p:
        return -_log1pexp(-x if lower_tail else x)
    else:
        return 1 / (1 + exp(-x if lower_tail else x))


def qlogis_(p, location, scale, lower_tail, log_p):
    if _isnan(p) or _isnan(location) or _isnan(scale):
        return p + location + scale
    if log_p:
        if p > 0:
            return NAN
        if p == 0:
            return INF if lower_tail else NINF
        if p == NINF:
            return NINF if lower_tail else INF
    else:
        if p < 0 or p > 1:
            return NAN
        if p == 0:
            return NINF if lower_tail else INF
        if p == 1:
            return INF if lower_tail else NINF
    if scale < 0.:
        return NAN
    if scale == 0.:
        return location
    if log_p:
        if lower_tail:
            p = p - R_Log1_Exp(p)
        else:
            p = R_Log1_Exp(p) - p
    else:
        p = log((p / (1. - p)) if lower_tail else ((1. - p) / p))
    return location + scale * p


def dlogis_(x, location, scale, give_log):
    if _isnan(x) or _isnan(location) or _isnan(scale):
        return x + location + scale
    if scale <= 0.0:
        return NAN
    x = abs((x - location) / scale)
    e = exp(-x)
    f = 1.0 + e
    return -(x + log(scale * f * f)) if give_log else e / (scale * f * f)


# ══ Gamma-Verteilung (pgamma.c, dgamma.c, qgamma.c) ═══════════════════════

_SCALEFACTOR = 1.157920892373162e+77   # (2^32)^8 = 2^256
_M_CUTOFF = M_LN2 * 1024 / DBL_EPSILON


def logcf(x, i, d, eps):
    c1 = 2 * d
    c2 = i + d
    c4 = c2 + d
    a1 = c2
    b1 = i * (c2 - i * x)
    b2 = d * d * x
    a2 = c4 * c2 - b2
    b2 = c4 * b1 - i * b2
    sf = _SCALEFACTOR
    while abs(a2 * b1 - a1 * b2) > abs(eps * b1 * b2):
        c3 = c2 * c2 * x
        c2 += d
        c4 += d
        a1 = c4 * a2 - c3 * a1
        b1 = c4 * b2 - c3 * b1

        c3 = c1 * c1 * x
        c1 += d
        c4 += d
        a2 = c4 * a1 - c3 * a2
        b2 = c4 * b1 - c3 * b2

        if abs(b2) > sf:
            a1 /= sf
            b1 /= sf
            a2 /= sf
            b2 /= sf
        elif abs(b2) < 1 / sf:
            a1 *= sf
            b1 *= sf
            a2 *= sf
            b2 *= sf
    return dv(a2, b2)


def _log1pmx(x):
    """``log(1+x) - x``, genau auch für kleine ``x`` (R's ``log1pmx``)."""
    minLog1Value = -0.79149064
    if x > 1 or x < minLog1Value:
        return log1p(x) - x
    else:
        r = x / (2 + x)
        y = r * r
        if abs(x) < 1e-2:
            two = 2.0
            return r * ((((two / 9 * y + two / 7) * y + two / 5) * y +
                         two / 3) * y - x)
        else:
            tol_logcf = 1e-14
            return r * (2 * y * logcf(y, 3, 2, tol_logcf) - x)


_LG1P_COEFFS = (
    0.3224670334241132182362075833230126e-0,
    0.6735230105319809513324605383715000e-1,
    0.2058080842778454787900092413529198e-1,
    0.7385551028673985266273097291406834e-2,
    0.2890510330741523285752988298486755e-2,
    0.1192753911703260977113935692828109e-2,
    0.5096695247430424223356548135815582e-3,
    0.2231547584535793797614188036013401e-3,
    0.9945751278180853371459589003190170e-4,
    0.4492623673813314170020750240635786e-4,
    0.2050721277567069155316650397830591e-4,
    0.9439488275268395903987425104415055e-5,
    0.4374866789907487804181793223952411e-5,
    0.2039215753801366236781900709670839e-5,
    0.9551412130407419832857179772951265e-6,
    0.4492469198764566043294290331193655e-6,
    0.2120718480555466586923135901077628e-6,
    0.1004322482396809960872083050053344e-6,
    0.4769810169363980565760193417246730e-7,
    0.2271109460894316491031998116062124e-7,
    0.1083865921489695409107491757968159e-7,
    0.5183475041970046655121248647057669e-8,
    0.2483674543802478317185008663991718e-8,
    0.1192140140586091207442548202774640e-8,
    0.5731367241678862013330194857961011e-9,
    0.2759522885124233145178149692816341e-9,
    0.1330476437424448948149715720858008e-9,
    0.6422964563838100022082448087644648e-10,
    0.3104424774732227276239215783404066e-10,
    0.1502138408075414217093301048780668e-10,
    0.7275974480239079662504549924814047e-11,
    0.3527742476575915083615072228655483e-11,
    0.1711991790559617908601084114443031e-11,
    0.8315385841420284819798357793954418e-12,
    0.4042200525289440065536008957032895e-12,
    0.1966475631096616490411045679010286e-12,
    0.9573630387838555763782200936508615e-13,
    0.4664076026428374224576492565974577e-13,
    0.2273736960065972320633279596737272e-13,
    0.1109139947083452201658320007192334e-13,
)


def _lgamma1p(a):
    """``log(gamma(a+1))``, genau auch für kleine ``a`` (R's ``lgamma1p``)."""
    if abs(a) >= 0.5:
        return _lgammafn(a + 1)
    eulers_const = 0.5772156649015328606065120900824024
    N = 40
    c = 0.2273736845824652515226821577978691e-12
    tol_logcf = 1e-14
    lgam = c * logcf(-a / 2, N + 2, 1, tol_logcf)
    coeffs = _LG1P_COEFFS
    for i in range(N - 1, -1, -1):
        lgam = coeffs[i] - a * lgam
    return (a * lgam - eulers_const) * a - _log1pmx(a)


def logspace_sum(logx):
    """``log(sum(exp(logx)))`` (long-double-Summe wie R)."""
    n = len(logx)
    if n == 0:
        return NINF
    if n == 1:
        return float(logx[0])
    if n == 2:
        return logspace_add(float(logx[0]), float(logx[1]))
    Mx = float(logx[0])
    for i in range(1, n):
        if Mx < logx[i]:
            Mx = float(logx[i])
    LD = np.longdouble
    s = LD(0.)
    for i in range(n):
        s += np.exp(LD(float(logx[i]) - Mx))
    return Mx + float(np.log(s))


def _dpois_wrap(x_plus_1, lam, give_log):
    if not _isfinite(lam):
        return NINF if give_log else 0.
    if x_plus_1 > 1:
        return _dpois_raw(x_plus_1 - 1, lam, give_log)
    if lam > abs(x_plus_1 - 1) * _M_CUTOFF:
        v = -lam - _lgammafn(x_plus_1)
        return v if give_log else exp(v)
    else:
        d = _dpois_raw(x_plus_1, lam, give_log)
        return d + log(x_plus_1 / lam) if give_log else d * (x_plus_1 / lam)


def _pgamma_smallx(x, alph, lower_tail, log_p):
    sum_ = 0.
    c = alph
    n = 0.
    while True:
        n += 1
        c *= -x / n
        term = c / (alph + n)
        sum_ += term
        if not (abs(term) > DBL_EPSILON * abs(sum_)):
            break
    if lower_tail:
        f1 = log1p(sum_) if log_p else 1 + sum_
        if alph > 1:
            f2 = _dpois_raw(alph, x, log_p)
            f2 = f2 + x if log_p else f2 * exp(x)
        elif log_p:
            f2 = alph * log(x) - _lgamma1p(alph)
        else:
            f2 = pow(x, alph) / exp(_lgamma1p(alph))
        return f1 + f2 if log_p else f1 * f2
    else:
        lf2 = alph * log(x) - _lgamma1p(alph)
        if log_p:
            return R_Log1_Exp(log1p(sum_) + lf2)
        else:
            f1m1 = sum_
            f2m1 = expm1(lf2)
            return -(f1m1 + f2m1 + f1m1 * f2m1)


def _pd_upper_series(x, y, log_p):
    term = x / y
    sum_ = term
    while True:
        y += 1
        term *= x / y
        sum_ += term
        if not (term > sum_ * DBL_EPSILON):
            break
    return log(sum_) if log_p else sum_


def _pd_lower_cf(y, d):
    f = 0.0
    max_it = 200000
    sf = _SCALEFACTOR
    if y == 0:
        return 0.0
    f0 = dv(y, d)
    if abs(y - 1) < abs(d) * DBL_EPSILON:
        return f0
    if f0 > 1.:
        f0 = 1.
    c2 = y
    c4 = d
    a1 = 0.
    b1 = 1.
    a2 = y
    b2 = d
    while b2 > sf:
        a1 /= sf
        b1 /= sf
        a2 /= sf
        b2 /= sf
    i = 0.
    of = -1.
    while i < max_it:
        i += 1
        c2 -= 1
        c3 = i * c2
        c4 += 2
        a1 = c4 * a2 + c3 * a1
        b1 = c4 * b2 + c3 * b1

        i += 1
        c2 -= 1
        c3 = i * c2
        c4 += 2
        a2 = c4 * a1 + c3 * a2
        b2 = c4 * b1 + c3 * b2

        if b2 > sf:
            a1 /= sf
            b1 /= sf
            a2 /= sf
            b2 /= sf

        if b2 != 0:
            f = a2 / b2
            if abs(f - of) <= DBL_EPSILON * fmax2(f0, abs(f)):
                return f
            of = f
    ml_warning(" ** NON-convergence in pgamma()'s pd_lower_cf() f= %g.\n".rstrip("\n") % f)
    return f


def _pd_lower_series(lam, y):
    term = 1.
    sum_ = 0.
    while y >= 1 and term > sum_ * DBL_EPSILON:
        term *= y / lam
        sum_ += term
        y -= 1
    if y != _c.floor(y):
        f = _pd_lower_cf(y, lam + 1 - y)
        sum_ += term * f
    return sum_


def _dpnorm(x, lower_tail, lp):
    if x < 0:
        x = -x
        lower_tail = not lower_tail
    if x > 10 and not lower_tail:
        term = 1 / x
        sum_ = term
        x2 = x * x
        i = 1.
        while True:
            term *= -i / x2
            sum_ += term
            i += 2
            if not (abs(term) > DBL_EPSILON * sum_):
                break
        return 1 / sum_
    else:
        d = dnorm4(x, 0., 1., False)
        return d / exp(lp)


_PPA_A = (-1e99, 2 / 3., -4 / 135., 8 / 2835., 16 / 8505., -8992 / 12629925.,
          -334144 / 492567075., 698752 / 1477701225.)
_PPA_B = (-1e99, 1 / 12., 1 / 288., -139 / 51840., -571 / 2488320., 163879 / 209018880.,
          5246819 / 75246796800., -534703531 / 902961561600.)


def _ppois_asymp(x, lam, lower_tail, log_p):
    coefs_a = _PPA_A
    coefs_b = _PPA_B
    dfm = lam - x
    pt__ = - _log1pmx(dv(dfm, x))
    s2pt = sqrt(2 * x * pt__)
    if dfm < 0:
        s2pt = -s2pt

    res12 = 0.
    res1_ig = res1_term = sqrt(x)
    res2_ig = res2_term = s2pt
    for i in range(1, 8):
        res12 += res1_ig * coefs_a[i]
        res12 += res2_ig * coefs_b[i]
        res1_term *= pt__ / i
        res2_term *= 2 * pt__ / (2 * i + 1)
        res1_ig = dv(res1_ig, x) + res1_term
        res2_ig = dv(res2_ig, x) + res2_term

    elfb = x
    elfb_term = 1.
    for i in range(1, 8):
        elfb += elfb_term * coefs_b[i]
        elfb_term = dv(elfb_term, x)
    if not lower_tail:
        elfb = -elfb

    f = dv(res12, elfb)
    np_ = pnorm5(s2pt, 0.0, 1.0, not lower_tail, log_p)
    if log_p:
        n_d_over_p = _dpnorm(s2pt, not lower_tail, np_)
        return np_ + log1p(f * n_d_over_p)
    else:
        nd = dnorm4(s2pt, 0., 1., log_p)
        return np_ + f * nd


def _pgamma_raw(x, alph, lower_tail, log_p):
    """Regularisierte unvollständige Gammafunktion (R's ``pgamma_raw``)."""
    # R_P_bounds_01(x, 0., ML_POSINF)
    if x <= 0.:
        return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
    if x >= INF:
        return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)

    if x < 1:
        res = _pgamma_smallx(x, alph, lower_tail, log_p)
    elif x <= alph - 1 and x < 0.8 * (alph + 50):
        sum_ = _pd_upper_series(x, alph, log_p)
        d = _dpois_wrap(alph, x, log_p)
        if not lower_tail:
            res = R_Log1_Exp(d + sum_) if log_p else 1 - d * sum_
        else:
            res = sum_ + d if log_p else sum_ * d
    elif alph - 1 < x and alph < 0.8 * (x + 50):
        d = _dpois_wrap(alph, x, log_p)
        if alph < 1:
            if x * DBL_EPSILON > 1 - alph:
                sum_ = 0. if log_p else 1.
            else:
                f = _pd_lower_cf(alph, x - (alph - 1)) * x / alph
                sum_ = log(f) if log_p else f
        else:
            sum_ = _pd_lower_series(x, alph - 1)
            sum_ = log1p(sum_) if log_p else 1 + sum_
        if not lower_tail:
            res = sum_ + d if log_p else sum_ * d
        else:
            res = R_Log1_Exp(d + sum_) if log_p else 1 - d * sum_
    else:
        res = _ppois_asymp(alph - 1, x, not lower_tail, log_p)

    if not log_p and res < DBL_MIN / DBL_EPSILON:
        return exp(_pgamma_raw(x, alph, lower_tail, 1))
    return res


def pgamma_(x, alph, scale, lower_tail, log_p):
    if _isnan(x) or _isnan(alph) or _isnan(scale):
        return x + alph + scale
    if alph < 0. or scale <= 0.:
        return NAN
    x /= scale
    if _isnan(x):
        return x
    if alph == 0.:
        if x <= 0:
            return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
        return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
    return _pgamma_raw(x, alph, lower_tail, log_p)


def dgamma_(x, shape, scale, give_log):
    if _isnan(x) or _isnan(shape) or _isnan(scale):
        return x + shape + scale
    if shape < 0 or scale <= 0:
        return NAN
    if x < 0:
        return NINF if give_log else 0.
    if shape == 0:
        return INF if x == 0 else (NINF if give_log else 0.)
    if x == 0:
        if shape < 1:
            return INF
        if shape > 1:
            return NINF if give_log else 0.
        return -log(scale) if give_log else 1 / scale
    if shape < 1:
        pr = _dpois_raw(shape, x / scale, give_log)
        if give_log:
            return pr + (log(shape / x) if _isfinite(shape / x) else log(shape) - log(x))
        return pr * shape / x
    pr = _dpois_raw(shape - 1, x / scale, give_log)
    return pr - log(scale) if give_log else pr / scale


def _R_DT_log(p, lower_tail, log_p):
    if lower_tail:
        return p if log_p else log(p)
    return R_Log1_Exp(p) if log_p else log1p(-p)


def _R_DT_Clog(p, lower_tail, log_p):
    if lower_tail:
        return R_Log1_Exp(p) if log_p else log1p(-p)
    return p if log_p else log(p)


def _qchisq_appr(p, nu, g, lower_tail, log_p, tol):
    """Startwert für qgamma (AS 91; R's ``qchisq_appr``)."""
    C7 = 4.67
    C8 = 6.66
    C9 = 6.73
    C10 = 13.32
    if _isnan(p) or _isnan(nu):
        return p + nu
    if (log_p and p > 0) or (not log_p and (p < 0 or p > 1)):
        return NAN
    if nu <= 0:
        return NAN

    alpha = 0.5 * nu
    c = alpha - 1

    p1 = _R_DT_log(p, lower_tail, log_p)
    if nu < (-1.24) * p1:
        lgam1pa = _lgamma1p(alpha) if (alpha < 0.5) else (log(alpha) + g)
        ch = exp((lgam1pa + p1) / alpha + M_LN2)
    elif nu > 0.32:
        x = qnorm5(p, 0, 1, lower_tail, log_p)
        p1 = 2. / (9 * nu)
        ch = nu * pow(x * sqrt(p1) + 1 - p1, 3)
        if ch > 2.2 * nu + 6:
            ch = -2 * (_R_DT_Clog(p, lower_tail, log_p) - c * log(0.5 * ch) + g)
    else:
        ch = 0.4
        a = _R_DT_Clog(p, lower_tail, log_p) + g + c * M_LN2
        while True:
            q = ch
            p1 = 1. / (1 + ch * (C7 + ch))
            p2 = ch * (C9 + ch * (C8 + ch))
            t = -0.5 + (C7 + 2 * ch) * p1 - (C9 + ch * (C10 + 3 * ch)) / p2
            ch -= dv(1 - exp(a + 0.5 * ch) * p2 * p1, t)
            if not (abs(q - ch) > tol * abs(ch)):
                break
    return ch


def qgamma_(p, alpha, scale, lower_tail, log_p):
    EPS1 = 1e-2
    EPS2 = 5e-7
    EPS_N = 1e-15
    MAXIT = 1000
    pMIN = 1e-100
    pMAX = (1 - 1e-14)
    i420 = 1. / 420.
    i2520 = 1. / 2520.
    i5040 = 1. / 5040

    max_it_Newton = 1

    if _isnan(p) or _isnan(alpha) or _isnan(scale):
        return p + alpha + scale
    # R_Q_P01_boundaries(p, 0., ML_POSINF)
    if log_p:
        if p > 0:
            return NAN
        if p == 0:
            return INF if lower_tail else 0.
        if p == NINF:
            return 0. if lower_tail else INF
    else:
        if p < 0 or p > 1:
            return NAN
        if p == 0:
            return 0. if lower_tail else INF
        if p == 1:
            return INF if lower_tail else 0.

    if alpha < 0 or scale <= 0:
        return NAN
    if alpha == 0:
        return 0.
    if alpha < 1e-10:
        max_it_Newton = 7

    # p_ = R_DT_qIv(p)
    if log_p:
        p_ = exp(p) if lower_tail else -expm1(p)
    else:
        p_ = p if lower_tail else (0.5 - p + 0.5)

    g = _lgammafn(alpha)

    # Phase I
    ch = _qchisq_appr(p, 2 * alpha, g, lower_tail, log_p, EPS1)
    goto_end = False
    if not _isfinite(ch):
        max_it_Newton = 0
        goto_end = True
    elif ch < EPS2:
        max_it_Newton = 20
        goto_end = True
    elif p_ > pMAX or p_ < pMIN:
        max_it_Newton = 20
        goto_end = True

    if not goto_end:
        # Phase II
        c = alpha - 1
        s6 = (120 + c * (346 + 127 * c)) * i5040
        ch0 = ch
        for i in range(1, MAXIT + 1):
            q = ch
            p1 = 0.5 * ch
            p2 = p_ - _pgamma_raw(p1, alpha, True, False)
            if not _isfinite(p2) or ch <= 0:
                ch = ch0
                max_it_Newton = 27
                break
            t = p2 * exp(alpha * M_LN2 + g + p1 - c * log(ch))
            b = t / ch
            a = 0.5 * t - b * c
            s1 = (210 + a * (140 + a * (105 + a * (84 + a * (70 + 60 * a))))) * i420
            s2 = (420 + a * (735 + a * (966 + a * (1141 + 1278 * a)))) * i2520
            s3 = (210 + a * (462 + a * (707 + 932 * a))) * i2520
            s4 = (252 + a * (672 + 1182 * a) + c * (294 + a * (889 + 1740 * a))) * i5040
            s5 = (84 + 2264 * a + c * (1175 + 606 * a)) * i2520

            ch += t * (1 + 0.5 * t * s1 - b * c * (s1 - b * (s2 - b * (s3 - b * (s4 - b * (s5 - b * s6))))))
            if abs(q - ch) < EPS2 * ch:
                break
            if abs(q - ch) > 0.1 * ch:
                if ch < q:
                    ch = 0.9 * q
                else:
                    ch = 1.1 * q

    # END:
    x = 0.5 * scale * ch
    if max_it_Newton:
        if not log_p:
            p = log(p)
            log_p = True
        if x == 0:
            _1_p = 1. + 1e-7
            _1_m = 1. - 1e-7
            x = DBL_MIN
            p_ = pgamma_(x, alpha, scale, lower_tail, log_p)
            if (lower_tail and p_ > p * _1_p) or (not lower_tail and p_ < p * _1_m):
                return 0.
        else:
            p_ = pgamma_(x, alpha, scale, lower_tail, log_p)
        if p_ == NINF:
            return 0.0
        for i in range(1, max_it_Newton + 1):
            p1 = p_ - p
            if abs(p1) < abs(EPS_N * p):
                break
            g = dgamma_(x, alpha, scale, log_p)
            if g == (NINF if log_p else 0.):
                break
            t = p1 * exp(p_ - g) if log_p else p1 / g
            t = x - t if lower_tail else x + t
            p_ = pgamma_(t, alpha, scale, lower_tail, log_p)
            if abs(p_ - p) > abs(p1) or (i > 1 and abs(p_ - p) == abs(p1)):
                break
            x = t
    return x


def pchisq_(x, df, lower_tail, log_p):
    return pgamma_(x, df / 2., 2., lower_tail, log_p)


def qchisq_(p, df, lower_tail, log_p):
    return qgamma_(p, 0.5 * df, 2.0, lower_tail, log_p)


def dchisq_(x, df, give_log):
    return dgamma_(x, df / 2., 2., give_log)


def pf_(x, df1, df2, lower_tail, log_p):
    if _isnan(x) or _isnan(df1) or _isnan(df2):
        return x + df2 + df1
    if df1 <= 0. or df2 <= 0.:
        return NAN
    if x <= 0.:
        return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
    if x >= INF:
        return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
    if df2 == INF:
        if df1 == INF:
            if x < 1.:
                return (NINF if log_p else 0.) if lower_tail else (0. if log_p else 1.)
            if x == 1.:
                return -M_LN2 if log_p else 0.5
            if x > 1.:
                return (0. if log_p else 1.) if lower_tail else (NINF if log_p else 0.)
        return pchisq_(x * df1, df1, lower_tail, log_p)
    if df1 == INF:
        return pchisq_(df2 / x, df2, not lower_tail, log_p)
    if df1 * x > df2:
        x = pbeta_(df2 / (df2 + df1 * x), df2 / 2., df1 / 2., not lower_tail, log_p)
    else:
        x = pbeta_(df1 * x / (df2 + df1 * x), df1 / 2., df2 / 2., lower_tail, log_p)
    return x if not _isnan(x) else NAN


# ══ Vektorisierung wie stats/src/distn.c ═════════════════════════════════

def _prep(x):
    """Argument → (Liste von floats, Form, Index/None, ist_skalar)."""
    if isinstance(x, pd.Series):
        a = x.to_numpy(dtype=np.float64, na_value=np.nan)
        return a.tolist(), a.shape, x.index, False
    if isinstance(x, (float, int)) and not isinstance(x, bool):
        return [float(x)], None, None, True
    if isinstance(x, (bool, np.bool_)):
        return [float(x)], None, None, True
    if isinstance(x, np.generic):
        return [float(x)], None, None, True
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 0:
        return [float(a)], None, None, True
    return a.ravel(order="F").tolist(), a.shape, None, False


def _vectorize(f, args, ints=(), math1=False):
    """Skalaren Kern ``f(*args, *ints)`` mit R-Recycling anwenden."""
    preps = [_prep(a) for a in args]
    lens = [len(p[0]) for p in preps]
    if all(p[3] for p in preps):
        vals = [p[0][0] for p in preps]
        if any(v != v for v in vals):
            return vals[0] if math1 else _na_or_nan(*vals)
        y = f(*vals, *ints)
        if y != y:
            warnings.warn(R_MSG_NA, stacklevel=3)
        return y
    if min(lens) == 0:
        return np.empty(0, dtype=np.float64)
    n = max(lens)
    # Form/Index vom ersten Argument maximaler Länge (R: SHALLOW_DUPLICATE_ATTRIB)
    k = lens.index(n)
    shape = preps[k][1]
    index = preps[k][2]
    lists = [p[0] for p in preps]
    if n >= 64:
        long_ = [j for j in range(len(lists)) if lens[j] > 1]
        if len(long_) == 1 and lens[long_[0]] == n:
            # gleiche Eingaben (Bitmuster) nur einmal rechnen, in Reihenfolge des
            # ersten Auftretens (Warnungen in derselben Reihenfolge wie in R)
            j = long_[0]
            bits = np.array(lists[j], dtype=np.float64).view(np.int64)
            ub, first, inv = np.unique(bits, return_index=True, return_inverse=True)
            if len(ub) <= 0.75 * n:
                order = np.argsort(first, kind="stable")
                rank = np.empty_like(order)
                rank[order] = np.arange(len(order))
                sub = list(lists)
                sub[j] = ub[order].view(np.float64).tolist()
                vals = _vectorize(f, [np.array(v) if k == j else v[0] for k, v in enumerate(sub)],
                                  ints, math1)
                res = np.asarray(vals, dtype=np.float64)[rank[inv.ravel()]]
                if shape is not None and len(shape) > 1:
                    res = res.reshape(shape, order="F")
                if index is not None:
                    return pd.Series(res, index=index)
                return res
    out = [0.0] * n
    naflag = False
    nargs = len(lists)
    if nargs == 1:
        l0 = lists[0]
        for i in range(n):
            a = l0[i]
            if a != a:
                out[i] = a
                continue
            y = f(a, *ints)
            if y != y:
                naflag = True
            out[i] = y
    elif nargs == 2:
        l0, l1 = lists
        n0, n1 = len(l0), len(l1)
        for i in range(n):
            a = l0[i % n0]
            b = l1[i % n1]
            if a != a or b != b:
                out[i] = _na_or_nan(a, b)
                continue
            y = f(a, b, *ints)
            if y != y:
                naflag = True
            out[i] = y
    else:
        lens_ = [len(l) for l in lists]
        for i in range(n):
            vals = [lists[j][i % lens_[j]] for j in range(nargs)]
            if any(v != v for v in vals):
                out[i] = _na_or_nan(*vals)
                continue
            y = f(*vals, *ints)
            if y != y:
                naflag = True
            out[i] = y
    if naflag:
        warnings.warn(R_MSG_NA, stacklevel=3)
    res = np.array(out, dtype=np.float64)
    if shape is not None and len(shape) > 1:
        res = res.reshape(shape, order="F")
    if index is not None:
        return pd.Series(res, index=index)
    return res


def _flag(v):
    return 1 if v else 0


def _no_ncp(ncp):
    if ncp is not None:
        raise NotImplementedError("nicht-zentrale Verteilungen (ncp) sind nicht portiert")


# ── öffentliche Funktionen (R-Signaturen) ──────────────────────────────────

def dnorm(x, mean=0, sd=1, log=False):
    """Dichte der Normalverteilung (R ``dnorm``)."""
    return _vectorize(dnorm4, (x, mean, sd), (_flag(log),))


def pnorm(q, mean=0, sd=1, lower_tail=True, log_p=False):
    """Verteilungsfunktion der Normalverteilung (R ``pnorm``)."""
    return _vectorize(pnorm5, (q, mean, sd), (_flag(lower_tail), _flag(log_p)))


def qnorm(p, mean=0, sd=1, lower_tail=True, log_p=False):
    """Quantile der Normalverteilung (R ``qnorm``)."""
    return _vectorize(qnorm5, (p, mean, sd), (_flag(lower_tail), _flag(log_p)))


def dt(x, df, ncp=None, log=False):
    """Dichte der t-Verteilung (R ``dt``, zentral)."""
    _no_ncp(ncp)
    return _vectorize(dt_, (x, df), (_flag(log),))


def pt(q, df, ncp=None, lower_tail=True, log_p=False):
    """Verteilungsfunktion der t-Verteilung (R ``pt``, zentral)."""
    _no_ncp(ncp)
    return _vectorize(pt_, (q, df), (_flag(lower_tail), _flag(log_p)))


def qt(p, df, ncp=None, lower_tail=True, log_p=False):
    """Quantile der t-Verteilung (R ``qt``, zentral)."""
    _no_ncp(ncp)
    return _vectorize(qt_, (p, df), (_flag(lower_tail), _flag(log_p)))


def pbeta(q, shape1, shape2, ncp=None, lower_tail=True, log_p=False):
    """Verteilungsfunktion der Betaverteilung (R ``pbeta``, zentral)."""
    _no_ncp(ncp)
    return _vectorize(pbeta_, (q, shape1, shape2), (_flag(lower_tail), _flag(log_p)))


def lgamma(x):
    """``log|Gamma(x)|`` (R ``lgamma`` = ``lgammafn``)."""
    return _vectorize(_lgammafn, (x,), math1=True)


def gamma(x):
    """Gammafunktion (R ``gamma`` = ``gammafn``)."""
    return _vectorize(_gammafn, (x,), math1=True)


def lbeta(a, b):
    """``log(beta(a, b))`` (R ``lbeta``)."""
    return _vectorize(lbeta_, (a, b))


def beta(a, b):
    """Betafunktion (R ``beta``)."""
    return _vectorize(beta_, (a, b))


def plogis(q, location=0, scale=1, lower_tail=True, log_p=False):
    """Verteilungsfunktion der logistischen Verteilung (R ``plogis``)."""
    return _vectorize(plogis_, (q, location, scale), (_flag(lower_tail), _flag(log_p)))


def qlogis(p, location=0, scale=1, lower_tail=True, log_p=False):
    """Quantile der logistischen Verteilung (R ``qlogis``)."""
    return _vectorize(qlogis_, (p, location, scale), (_flag(lower_tail), _flag(log_p)))


def dlogis(x, location=0, scale=1, log=False):
    """Dichte der logistischen Verteilung (R ``dlogis``)."""
    return _vectorize(dlogis_, (x, location, scale), (_flag(log),))


def _rate_scale(rate, scale):
    if rate is not None and scale is not None:
        r = np.asarray(rate, dtype=np.float64)
        s = np.asarray(scale, dtype=np.float64)
        if np.all(np.abs(r * s - 1) < 1e-15):
            warnings.warn("specify 'rate' or 'scale' but not both", stacklevel=3)
        else:
            raise ValueError("specify 'rate' or 'scale' but not both")
        return scale
    if scale is not None:
        return scale
    if rate is None:
        return 1.0
    if np.isscalar(rate):
        return 1 / float(rate) if float(rate) != 0 else INF
    r = np.asarray(rate, dtype=np.float64)
    with np.errstate(divide="ignore"):
        return 1 / r


def pgamma(q, shape, rate=None, scale=None, lower_tail=True, log_p=False):
    """Verteilungsfunktion der Gammaverteilung (R ``pgamma``)."""
    sc = _rate_scale(rate, scale)
    return _vectorize(pgamma_, (q, shape, sc), (_flag(lower_tail), _flag(log_p)))


def qgamma(p, shape, rate=None, scale=None, lower_tail=True, log_p=False):
    """Quantile der Gammaverteilung (R ``qgamma``)."""
    sc = _rate_scale(rate, scale)
    return _vectorize(qgamma_, (p, shape, sc), (_flag(lower_tail), _flag(log_p)))


def dgamma(x, shape, rate=None, scale=None, log=False):
    """Dichte der Gammaverteilung (R ``dgamma``)."""
    sc = _rate_scale(rate, scale)
    return _vectorize(dgamma_, (x, shape, sc), (_flag(log),))


def pchisq(q, df, ncp=None, lower_tail=True, log_p=False):
    """Verteilungsfunktion der Chi-Quadrat-Verteilung (R ``pchisq``, zentral)."""
    _no_ncp(ncp)
    return _vectorize(pchisq_, (q, df), (_flag(lower_tail), _flag(log_p)))


def qchisq(p, df, ncp=None, lower_tail=True, log_p=False):
    """Quantile der Chi-Quadrat-Verteilung (R ``qchisq``, zentral)."""
    _no_ncp(ncp)
    return _vectorize(qchisq_, (p, df), (_flag(lower_tail), _flag(log_p)))


def dchisq(x, df, ncp=None, log=False):
    """Dichte der Chi-Quadrat-Verteilung (R ``dchisq``, zentral)."""
    _no_ncp(ncp)
    return _vectorize(dchisq_, (x, df), (_flag(log),))


def pf(q, df1, df2, ncp=None, lower_tail=True, log_p=False):
    """Verteilungsfunktion der F-Verteilung (R ``pf``, zentral)."""
    _no_ncp(ncp)
    return _vectorize(pf_, (q, df1, df2), (_flag(lower_tail), _flag(log_p)))


def dpois(x, lambda_, log=False):
    """Poisson-Wahrscheinlichkeiten (R ``dpois``)."""
    return _vectorize(_dpois, (x, lambda_), (_flag(log),))


# Aliase mit C-Namen für andere Module
dnorm_scalar = dnorm4
pnorm_scalar = pnorm5
qnorm_scalar = qnorm5
gammafn_scalar = _gammafn


# ── skalare Hilfen (öffentlich; Argumente werden zu Python-float) ─────────
# Die Kerne arbeiten mit Python-floats (C-Semantik über _cmath); numpy-Skalare
# würden numpy-Warnungen auslösen, daher hier die Umwandlung.

def stirlerr(n):
    """``log(n!) - log(sqrt(2*pi*n)*(n/e)^n)`` (R 4.3.3 ``stirlerr``)."""
    return _stirlerr(float(n))


def bd0(x, np_):
    """Abweichungsterm ``x log(x/np) + np - x`` (R's ``bd0``)."""
    return _bd0(float(x), float(np_))


def ebd0(x, M):
    """``x log(x/M) + M - x`` als ``(yh, yl)`` (R's ``ebd0``)."""
    return _ebd0(float(x), float(M))


def lgammacor(x):
    """Korrekturterm von ``lgamma`` für ``x >= 10`` (R's ``lgammacor``)."""
    return _lgammacor(float(x))


def chebyshev_eval(x, a, n):
    """Chebyshev-Reihe ``a[0:n]`` an der Stelle ``x`` (R's ``chebyshev_eval``)."""
    return _chebyshev_eval(float(x), [float(v) for v in a[:n]], int(n))


def chebyshev_init(dos, nos, eta):
    """Anzahl benötigter Chebyshev-Terme (R's ``chebyshev_init``)."""
    return _chebyshev_init([float(v) for v in dos], int(nos), float(eta))


def log1pmx(x):
    """``log(1+x) - x`` (R's ``log1pmx``)."""
    return _log1pmx(float(x))


def lgamma1p(a):
    """``log(gamma(a+1))`` (R's ``lgamma1p``)."""
    return _lgamma1p(float(a))


def logspace_add(logx, logy):
    """``log(exp(logx) + exp(logy))`` (R's ``logspace_add``)."""
    return _logspace_add(float(logx), float(logy))


def logspace_sub(logx, logy):
    """``log(exp(logx) - exp(logy))`` (R's ``logspace_sub``)."""
    return _logspace_sub(float(logx), float(logy))


def dpois_raw(x, lam, give_log=False):
    """Poisson-Dichte für reelles ``x`` (R's ``dpois_raw``)."""
    return _dpois_raw(float(x), float(lam), 1 if give_log else 0)


def lgammafn(x):
    """``log|Gamma(x)|`` skalar (R's ``lgammafn``)."""
    return _lgammafn(float(x))


def lgammafn_sign(x):
    """``(lgamma(x), Vorzeichen von Gamma(x))`` (R's ``lgammafn_sign``)."""
    return _lgammafn_sign(float(x))


def gammafn(x):
    """``Gamma(x)`` skalar (R's ``gammafn``)."""
    return _gammafn(float(x))


def sinpi(x):
    return _sinpi(float(x))


def cospi(x):
    return _cospi(float(x))


def tanpi(x):
    return _tanpi(float(x))


def log1pexp(x):
    """``log(1 + exp(x))`` (R's ``log1pexp``)."""
    return _log1pexp(float(x))


def log1mexp(x):
    """``log(1 - exp(-x))`` (R's ``log1mexp``)."""
    return _log1mexp(float(x))


def pgamma_raw(x, alph, lower_tail=True, log_p=False):
    return _pgamma_raw(float(x), float(alph), 1 if lower_tail else 0, 1 if log_p else 0)


def pbeta_raw(x, a, b, lower_tail=True, log_p=False):
    return _pbeta_raw(float(x), float(a), float(b), 1 if lower_tail else 0, 1 if log_p else 0)


def qchisq_appr(p, nu, g, lower_tail, log_p, tol):
    return _qchisq_appr(float(p), float(nu), float(g), 1 if lower_tail else 0, 1 if log_p else 0, float(tol))
