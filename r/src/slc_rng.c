/* core/slc_rng.c – Zufallsgenerator xoshiro256** mit SplitMix64-Seeding und Sprung (SimLev core, Etappe 9)
 * Verfahren:  xoshiro256** (256 Bit Zustand, Periode 2^256 - 1): lineare Zustandsabbildung
 *             mit Schiebe-, Rotations- und XOR-Schritten (a = 17, b = 45), Ausgabe
 *             rotl(s1 * 5, 7) * 9. Seeding: die ganze Zahl seed (int64, im Zweierkomplement als
 *             uint64) startet SplitMix64; dessen erste vier Ausgaben sind der Zustand (ein
 *             Nullzustand kann so nicht entstehen). Sprung um 2^128 Schritte: Auswertung des
 *             Sprungpolynoms J(x) = x^(2^128) mod P(x) an der Zustandsabbildung T, also
 *             J(T) s = sum_i j_i T^i s (Akkumulation über 256 Schritte). Gleichverteilung aus den
 *             oberen 53 Bit: u = (floor(x / 2^11) + 1/2) 2^-53, also u in (0, 1).
 * Quellen:    Blackman, D., Vigna, S. (2021). Scrambled linear pseudorandom number generators.
 *               ACM Transactions on Mathematical Software 47(4), Art. 36, 1–32.
 *               doi:10.1145/3460772; arXiv:1805.01407 (Abschnitte 3–4: xoshiro256 und der
 *               Verwürfler **, Parameter a = 17, b = 45, s = 5, r = 7, t = 9; Abschnitt über das
 *               Springen mit dem charakteristischen Polynom).
 *             Steele, G. L., Lea, D., Flood, C. H. (2014). Fast splittable pseudorandom number
 *               generators. Proceedings OOPSLA 2014, 453–472.
 *               doi:10.1145/2660193.2660195 (SplitMix: Weyl-Folge mit ungeradem Inkrement gamma
 *               und 64-Bit-Mischfunktion).
 *             Stafford, D. (2011). Better bit mixing – improving on MurmurHash3's 64-bit
 *               finalizer (Variante "Mix13": Verschiebungen 30, 27, 31 und Multiplikatoren
 *               0xbf58476d1ce4e5b9, 0x94d049bb133111eb); diese Mischfunktion nutzt der Java-Typ
 *               SplittableRandom, der Steele u. a. (2014) umsetzt, und Blackman/Vigna (2021)
 *               empfehlen SplitMix64 zum Seeding.
 * Konstanten: selbst hergeleitet in core/tools/gen_constants.py: Inkrement gamma = ungerade
 *             Zahl nächst 2^64 / goldener Schnitt; Sprungpolynom per Berlekamp-Massey und
 *             Quadrieren (gleich dem in Blackman/Vigna 2021 veröffentlichten Wert). Aus der
 *             Quelle: die Verfahrensparameter 17, 45, 5, 7, 9 (Blackman/Vigna 2021) und die
 *             Mischkonstanten von SplitMix64 (Stafford 2011, Variante 13).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: unabhängige Rechnung in Python mit großen Ganzzahlen; java.util.SplittableRandom
 *             (nur Ausgaben von SplitMix64); scratchpad/e91/.
 */
#define SLC_NEED_JUMP
#include "slc_internal.h"
#include "slc_constants.h"

static uint64_t rotl64(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }

uint64_t sl_splitmix64(uint64_t *x)
{
    uint64_t z = (*x += SLC_SPLITMIX_GAMMA);
    z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb);
    return z ^ (z >> 31);
}

void sl_rng_seed(sl_rng *r, int64_t seed)
{
    uint64_t x = (uint64_t) seed;      /* Zweierkomplement (C99 6.3.1.3: modulo 2^64) */
    int i;
    for (i = 0; i < 4; i++) r->s[i] = sl_splitmix64(&x);
}

void sl_rng_seed_entropy(sl_rng *r, uint64_t t_ns, uint64_t pid, uint64_t counter)
{
    uint64_t x = t_ns, a, b, c;
    a = sl_splitmix64(&x);
    x = pid ^ a;
    b = sl_splitmix64(&x);
    x = counter ^ b;
    c = sl_splitmix64(&x);
    sl_rng_seed(r, (int64_t) c);
}

/* lineare Zustandsabbildung T von xoshiro256 */
static void step(uint64_t *s)
{
    const uint64_t t = s[1] << 17;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl64(s[3], 45);
}

uint64_t sl_rng_next(sl_rng *r)
{
    const uint64_t out = rotl64(r->s[1] * 5, 7) * 9;
    step(r->s);
    return out;
}

void sl_rng_jump(sl_rng *r)
{
    uint64_t acc[4] = {0, 0, 0, 0};
    int i, b, k;
    for (i = 0; i < 4; i++)
        for (b = 0; b < 64; b++) {
            if ((slc_jump128[i] >> b) & 1u)
                for (k = 0; k < 4; k++) acc[k] ^= r->s[k];
            step(r->s);
        }
    for (k = 0; k < 4; k++) r->s[k] = acc[k];
}

int sl_rng_streams(sl_ctx *cx, const sl_rng *base, int64_t n, sl_rng *out)
{
    sl_rng cur = *base;
    int64_t i;
    if (n < 0) return sl_fail(cx, SL_EARG, "Ströme: Anzahl negativ");
    for (i = 0; i < n; i++) {
        sl_rng_jump(&cur);
        out[i] = cur;
        if ((i & 1023) == 1023 && sl_interrupted(cx)) return SL_EINTR;
    }
    return SL_OK;
}

int32_t sl_rng_seed31(sl_rng *g)
{
    return (int32_t) (sl_rng_next(g) >> 33);
}

double sl_unif01(sl_rng *r)
{
    return ((double) (sl_rng_next(r) >> 11) + 0.5) * SLC_TWO_M53;
}

int sl_runif(sl_ctx *cx, sl_rng *r, int64_t n, double a, double b, double *out)
{
    int64_t i;
    if (!(isfinite(a) && isfinite(b) && a <= b)) {
        for (i = 0; i < n; i++) out[i] = NAN;
        if (n > 0) sl_warn(cx, "runif: NaN erzeugt");
        return SL_OK;
    }
    for (i = 0; i < n; i++) {
        out[i] = a + (b - a) * sl_unif01(r);
        SL_POLL(cx, i);
    }
    return SL_OK;
}
