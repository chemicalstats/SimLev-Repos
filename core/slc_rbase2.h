/* core/slc_rbase2.h – Grundfunktionen mit R-Regeln für Python und Julia, Teil 2 (SimLev core, seit 1.6.0)
 * Verfahren:  siehe slc_rbase_clust.cpp (dist, hclust), slc_rbase_vec.cpp (sort mit NA-Regeln, cut/.bincode, rle,
 *             median, weighted.mean), slc_rbase_cor.cpp (cor/cov mit spearman, cov2cor, scale),
 *             slc_rbase_smooth.cpp (regularize.values, filter), slc_rbase_models.cpp (p.adjust, ecdf) und
 *             slc_rbase_fmt.cpp (formatReal/encodeReal, round/signif, sprintf, formatC, prettyNum).
 * Zweck:      Bis 1.5.2 bildeten Python (python/simlev/_r/) und Julia (julia/src/r/) diese Funktionen von R je für
 *             sich nach; seit 1.6.0 rechnen beide mit diesen Kernen, die Sprachen behalten dünne Hüllen
 *             (Argumente, NA-Kennung, Rückgabe). R selbst behält seine Grundfunktionen; diese Dateien gehen nicht
 *             nach r/src/ (core/sync.py) und nicht in slc.h.
 * NA:         R's NA_real_ ist das NaN mit Nutzlast 1954 (0x7FF00000000007A2), R's NaN das ruhige
 *             0x7FF8000000000000. Die Kerne unterscheiden beide wie R.
 * Herkunft:           übersetzt aus R 4.3.3 über die Port-Funktionen python/simlev/_r/ und julia/src/r/ bis 1.5.2;
 *                     Einzelheiten in den Köpfen der .cpp-Dateien
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der
 *                     jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C++ im gemeinsamen Teil von C und C++, ohne R-Datenstrukturen, gemeinsamer Kern für Python und
 *                     Julia (nicht Teil des R-Pakets).
 * Prüforakel: R 1.5.2 von SimLev (Gleichlauf: clust_fuzz.R, vec_fuzz.R, cor_fuzz.R, smooth_fuzz.R, padj_fuzz.R,
 *             fmt_fuzz.R).
 */
#ifndef SLC_RBASE2_H
#define SLC_RBASE2_H

#include <math.h>
#include <stdint.h>
#include <string.h>

#include "slc_rbase.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── NA-Hilfen der rbase-Dateien (seit 1.6.3 hier; vorher je Datei eine Kopie; slc_rbase.cpp, das auch nach
 * r/src/ geht, behält seine eigenen): Bits als double, R's ISNA (NaN mit Nutzlast 1954), NA_real_, R_NaN ── */
static inline double slr_bits_d(uint64_t u)
{
    double d;
    memcpy(&d, &u, sizeof d);
    return d;
}
static inline int slr_is_na(double x)
{
    uint64_t u;
    if (!isnan(x)) return 0;
    memcpy(&u, &x, sizeof u);
    return (u & UINT64_C(0xFFFFFFFF)) == 1954;
}
#define SLR_NA  slr_bits_d(UINT64_C(0x7FF00000000007A2))
#define SLR_NAN slr_bits_d(UINT64_C(0x7FF8000000000000))

/* ── slc_rbase_clust.cpp: dist, hclust ──────────────────────────────────────
 * sl_r_dist: Zeilenabstände der nr × nc-Matrix x (spaltenweise); method 1 euclidean, 2 maximum, 3 manhattan,
 * 4 canberra, 5 binary, 6 minkowski (p); out nr(nr-1)/2 Werte; *warn = 1: "treating non-finite values as NA".
 * sl_r_hclust: n >= 2 Objekte, iopt 1 ward.D, 2 single, 3 complete, 4 average, 5 mcquitty, 6 median,
 * 7 centroid, 8 ward.D2; membr n Gewichte, diss n(n-1)/2 Abstände (nicht verändert); merge (n-1) × 2
 * spaltenweise, height n-1, order n. Rückgabe 0, SL_EARG oder SL_ENOMEM. */
void sl_r_dist(int64_t nr, int64_t nc, const double *x, int method, double p, double *out, int *warn) SL_NOTHROW;
int  sl_r_hclust(int64_t n, int iopt, const double *membr, const double *diss, int64_t *merge, double *height,
                 int64_t *order) SL_NOTHROW;

/* ── slc_rbase_vec.cpp: .bincode, seq.int(length.out), median ─────────────────
 * sl_r_bincode: Intervallnummer (1-basiert, double) der x in nb aufsteigenden Grenzen b, sonst NA.
 * sl_r_seq_len: seq.int(from, to, length.out = n) nach out (n Werte).
 * sl_r_median: median(x, na.rm); isint: ganzzahlige Eingabe (Mittel wie mean für ganze Zahlen). Rückgabe 0 (*res),
 * 1 = NA (NA ohne na.rm oder leer; *res NA) oder SL_ENOMEM. */
void sl_r_bincode(int64_t n, const double *x, int64_t nb, const double *b, int right, int include_lowest,
                  double *out) SL_NOTHROW;
void sl_r_seq_len(double from, double to, int64_t n, double *out) SL_NOTHROW;
int  sl_r_median(int64_t n, const double *x, int narm, int isint, double *res) SL_NOTHROW;

/* ── slc_rbase_cor.cpp: cor/cov mit Rängen, cov2cor, scale ───────────────────
 * sl_r_cor: x n × ncx, y n × ncy oder NULL (spaltenweise); xmat/ymat: Eingabe ist eine Matrix (Rang einer Zeile = 1);
 * use 1–5 wie sl_r_cov; method 0 pearson, 1 kendall, 2 spearman; ans ncx × ncy (ohne y ncx × ncx; paarweise mit
 * ncx = 1 die rohe Zelle r, die Prüfung von r + t(r) - diag(diag(r)) bleibt beim Host). Fehlertexte wie R mit SL_EARG.
 * sl_r_cov2cor: p × p; *warn = 1: "diag(V) had non-positive or NA entries; ...".
 * sl_r_scale: x nr × nc an Ort und Stelle; center/scale 0 nein, 1 berechnen (Ergebnis in cen/sc), 2 vorgegeben. */
int  sl_r_cor(sl_ctx *cx, int64_t n, int64_t ncx, const double *x, int xmat, int64_t ncy, const double *y, int ymat,
              int use, int method, int cor, double *ans, int *sd0) SL_NOTHROW;
void sl_r_cov2cor(int64_t p, const double *v, double *out, int *warn) SL_NOTHROW;
int  sl_r_scale(int64_t nr, int64_t nc, double *x, int center, double *cen, int scale, double *sc) SL_NOTHROW;

/* ── slc_rbase_smooth.cpp: regularize.values, filter ────────────────────────
 * sl_r_regularize: Paare (x, y) der Länge n; narm wie na.rm; mode 0 Funktion bzw. mean (sortieren, zusammenfassen),
 * 1 list("ordered", f) (nur zusammenfassen), 2 "ordered" (nichts); mean: y je Gruppe über mean, sonst liefert yo die
 * m umgeordneten y und grp ihre Gruppennummern (0-basiert) für die Funktion des Hosts. xo, yo, grp: n Plätze;
 * *m_out Paare nach dem Entfernen, *nout Länge von xo (und yo bei mean oder ohne Zusammenfassen), *collapsed: Warnung
 * "collapsing to unique 'x' values", *kept_na: NA behalten (na.rm = FALSE). Rückgabe 0 oder SL_ENOMEM.
 * sl_r_filter_conv / sl_r_filter_rec: eine Reihe der Länge n, Filter nf; init nf Startwerte (jüngster zuerst wie R). */
int  sl_r_regularize(int64_t n, const double *x, const double *y, int narm, int mode, int mean, double *xo, double *yo,
                     int64_t *grp, int64_t *m_out, int64_t *nout, int *collapsed, int *kept_na) SL_NOTHROW;
void sl_r_filter_conv(int64_t n, const double *x, int64_t nf, const double *f, int sides, int circular,
                      double *out) SL_NOTHROW;
int  sl_r_filter_rec(int64_t n, const double *x, int64_t nf, const double *f, const double *init, double *out) SL_NOTHROW;

/* ── slc_rbase_models.cpp: p.adjust, ecdf ─────────────────────────────────────
 * sl_r_p_adjust: lp Werte ohne NA, n >= lp (> 1; geprüft vom Host), Verfahren SL_PADJ_*; out lp Werte.
 * sl_r_ecdf: Sprungstellen vals und Höhen y (je höchstens n), *nv ihre Zahl; SL_EARG ohne Wert ohne NA. */
enum { SL_PADJ_HOLM = 0, SL_PADJ_HOCHBERG = 1, SL_PADJ_HOMMEL = 2, SL_PADJ_BONFERRONI = 3, SL_PADJ_BH = 4,
       SL_PADJ_BY = 5, SL_PADJ_NONE = 6 };
int sl_r_p_adjust(int64_t lp, const double *p, double n, int method, double *out) SL_NOTHROW;
int sl_r_ecdf(int64_t n, const double *x, double *vals, double *y, int64_t *nv) SL_NOTHROW;

/* ── slc_rbase_fmt.cpp: round/signif, formatReal, encodeReal, as.character, str_signif, sprintf ─────────────
 * Texte als ein Puffer *out (UTF-8, Bytes) mit n + 1 Grenzen *off (malloc, freigeben mit sl_r_free).
 * sl_r_fround, sl_r_fprec, sl_r_round_vec: seit 1.6.3 in slc_rbase.cpp (Deklaration in slc_rbase.h).
 * sl_r_format_real: (w, d, e) wie formatReal für digits, nsmall, scipen; na: Maske der NA (NULL: Nutzlast 1954).
 * sl_r_encode_real: encodeReal0 je Wert (NA als nastr, rechtsbündig in w), drop0: Endnullen entfernen, dec: Dezimalzeichen.
 * sl_r_as_character_real: as.character je Wert (15 Stellen, ohne Endnullen; NA als "NA").
 * sl_r_str_signif: formatC (str_signif) mit width, digits, format ("d", "f", "e", "E", "g", "G", "fg"), flag; istrlen je
 * Wert (Ausgabe höchstens istrlen + 2 Bytes); isint: Ganzzahlen ("d"). Fehler mit SL_EARG.
 * sl_r_sprintf: nfmt Formate (NULL = NA), nargs Argumente mit Typ SL_RS_*, Länge, Daten (int32 mit NA = INT_MIN bzw.
 * double) und Texten str[k] (character: Pflicht; factor: Beschriftung je Element; Date: as.character je Element; sonst
 * NULL); scipen und dec für as.character von Zahlen bei %s. *nout Ergebnisse, *nunused nicht benutzte Argumente (Warnung
 * des Hosts). Fehlertexte wie R mit SL_EARG. */
enum { SL_RS_LGL = 0, SL_RS_INT = 1, SL_RS_DBL = 2, SL_RS_CHR = 3, SL_RS_FACTOR = 4, SL_RS_DATE = 5 };
void   sl_r_free(void *p) SL_NOTHROW;
void   sl_r_format_real(int64_t n, const double *x, const unsigned char *na, int digits, int nsmall, int scipen,
                        int *w, int *d, int *e) SL_NOTHROW;
int    sl_r_encode_real(int64_t n, const double *x, const unsigned char *na, int w, int d, int e, const char *dec,
                        const char *nastr, int drop0, char **out, int64_t **off) SL_NOTHROW;
int    sl_r_as_character_real(int64_t n, const double *x, int scipen, const char *dec, char **out,
                              int64_t **off) SL_NOTHROW;
int    sl_r_str_signif(sl_ctx *cx, int64_t n, const double *x, int isint, int width, int digits, const char *format,
                       const char *flag, const int64_t *istrlen, char **out, int64_t **off) SL_NOTHROW;
int    sl_r_sprintf(sl_ctx *cx, int64_t nfmt, const char *const *fmt, int nargs, const int *type, const int64_t *len,
                    const void *const *data, const char *const *const *str, int scipen, const char *dec, char **out,
                    int64_t **off, int64_t *nout, int *nunused) SL_NOTHROW;
/* sl_r_sprintf1: ein Format, höchstens 16 skalare Argumente (dv[k] bzw. iv[k] bzw. sv[k] je Typ); Ergebnis nach out
 * (cap Bytes), Rückgabe die volle Länge (> cap: erneut mit größerem Puffer), -1 Fehler (Text nach err), -2 ohne
 * Speicher. Ohne Kontext und ohne Speicher des Hosts (schneller Weg der Engine-Texte). */
int64_t sl_r_sprintf1(const char *fmt, int nargs, const int *type, const double *dv, const int32_t *iv,
                      const char *const *sv, int scipen, const char *dec, char *out, int64_t cap, char *err,
                      int64_t errcap, int *nunused) SL_NOTHROW;

#ifdef __cplusplus
}
#endif

#endif /* SLC_RBASE2_H */
