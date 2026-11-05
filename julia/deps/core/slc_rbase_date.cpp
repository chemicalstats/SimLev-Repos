/* core/slc_rbase_date.cpp – Datumsformat und -lesen wie R für Python und Julia (SimLev core)
 *
 * Verfahren:  Kalender: proleptischer Gregorianischer Kalender, Tage seit 1970-01-01 <-> (Jahr, Monat,
 *             Tag) mit ganzzahliger Ära-Rechnung (400-Jahres-Zyklen; H. Hinnant, "chrono-Compatible
 *             Low-Level Date Algorithms", gemeinfrei, wie bisher in den Ports und in fifo/tax_core).
 *             Format: format.Date/strftime für ein Datum (00:00 UTC) in der C-Locale mit den
 *             Umwandlungen der R-Hilfe ?strptime (%a %A %b %B %c %C %d %D %e %F %g %G %h %H %I %j %k %l
 *             %m %M %n %p %P %r %R %s %S %t %T %u %U %V %w %W %x %X %y %Y %z %Z %%, %E[cCyYxX],
 *             %O[dHImMUVwWy], R's %OSn). Leeres Format: "%Y-%m-%d" (Standard von format.Date).
 *             Lesen: as.Date(x, format = "%Y<sep>%m<sep>%d") (strptime): vor jeder Zahl werden
 *             Leerzeichen (nur ' ') übersprungen, %Y liest 1–4, %m und %d 1–2 Ziffern (0–9999,
 *             1–12, 1–31), das Trennzeichen muss folgen, der Rest nach dem Tag bleibt unbeachtet;
 *             ungültige Kalendertage ergeben NA.
 * Plattform:  ?strptime nennt Schalter, Breiten und andere Umwandlungen "system-specific". Festgelegt wie
 *             glibc unter Linux (glibc-Handbuch "Formatting Calendar Time", strftime; R 4.3.3 unter
 *             Linux als Orakel, Gleichlauf: date_fuzz.R):
 *             - Angabe: % [Schalter …] [Breite] [E|O] Umwandlung. Schalter "_" (mit Leerzeichen füllen),
 *               "-" (nicht füllen), "0" (mit Nullen füllen) – der letzte gilt –, "^" (Großbuchstaben),
 *               "#" (Groß-/Kleinschreibung tauschen). Breite dezimal (intern höchstens 1.000.000).
 *             - Zahlen haben eine natürliche Breite (%d %e %g %H %I %k %l %m %M %S %U %V %W %y: 2; %j: 3;
 *               %z: 4; %C %G %s %u %w %Y: keine) und füllen mit Nullen (%e %k %l: Leerzeichen; %s ohne
 *               Schalter: Leerzeichen). Breite = max(Breite, natürliche Breite); "-" lässt die natürliche Breite weg,
 *               eine angegebene Breite füllt dann mit Leerzeichen. Negative Zahlen: Minus vor den Nullen bzw.
 *               nach den Leerzeichen; bei %s mit Nullen stehen die Nullen vor dem Minus.
 *             - %z: "+" und "0000" je für sich mit der Breite (z. B. "%5z" -> "    +00000").
 *             - Text (%a %A %b %B %h %p %P %Z, %n %t %%) und zusammengesetzte Formen (%c %D %F %r %R %T %x %X)
 *               füllen eine Breite links mit Leerzeichen ("0": Nullen). "^": Großbuchstaben (nicht bei %P);
 *               "#": bei a A b B h Großbuchstaben, bei %p und %Z Kleinbuchstaben (vor "^"), sonst ohne Wirkung.
 *             - E nur bei c C x X y Y sowie bei Umwandlungen, die den Modifikator übergehen
 *               (% n t p P r R s T u z Z); O bei allen Zahlen außer %Y, bei b B h und ebenso bei
 *               % n t p P r R s T z Z. Sonst (z. B. %Ed, %OY, %Oa) wie eine unbekannte Umwandlung.
 *             - Unbekannte Umwandlung oder unvollständige Angabe am Ende: die Angabe als Text, mit Breite
 *               gefüllt, mit "^" (bei b/h auch "#") in Großbuchstaben (z. B. "%5q" -> "  %5q").
 *             - R's %OSn: das erste Vorkommen von "%OS" (als Text gesucht) mit einer folgenden Ziffer n
 *               (über 6: 6), sonst n = getOption("digits.secs") (nicht gesetzt: 0; Parameter digits_secs),
 *               wird im Format ersetzt – bei n = 0 durch "%S", sonst durch die Sekunden als Text ("00." und
 *               n Nullen) – und das Format dann als Ganzes ausgegeben (so wird aus "%%OS" bei n = 0 "%S").
 *             - Ergebnisse über 2048 Bytes sind wie in R ein Fehler ("output string exceeded 2048 bytes").
 * Zweck:      Python (python/simlev/_r/fmt.py u. a.) und Julia (julia/src/r/_fmt_format.jl u. a.)
 *             bildeten Format und Lesen je für sich nach; seit 1.2.0 rechnen beide mit diesem Kern.
 *             R behält sein eigenes Datumsformat (Datei wird nicht nach r/src/ kopiert).
 * Locale:     Monats- und Tagesnamen, %p, %c, %x, %X wie in der C-Locale (wie bisher in den Ports;
 *             SimLev formatiert Daten in R unter LC_TIME=C).
 * Grenzen:    |Tage| < 1e14 (dann passt %s in 64 Bit); größere Werte meldet sl_r_strftime mit -1
 *             (R selbst rechnet dort mit Überlauf).
 * Herkunft:           nachgebildet nach R 4.3.3, Hilfeseiten ?strptime, ?format.Date, ?as.Date, dem
 *                     glibc-Handbuch (strftime) und der Logik der bisherigen Port-Funktionen;
 *                     Kalenderrechnung siehe den Teil-Block bei sl_r_civil_from_days (slc_rbase.cpp); R 4.3.3 diente
 *                     als Orakel (Gleichlauf: date_fuzz.R)
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation
 *                     (laut Kopf der jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C99 ohne R-Datenstrukturen, gemeinsamer Kern für Python und Julia (nicht Teil
 *                     des R-Pakets); nur Datum (00:00 UTC) in der C-Locale.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "slc_rbase.h"

/* sl_r_civil_from_days, sl_r_days_from_civil: seit 1.6.3 in slc_rbase.cpp (auch für slc_prep.cpp und r/src/),
 * Abrundungsdivision sl_r_fdiv in slc_rbase.h */

static int is_leap_(int64_t y)
{
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

/* ── Ausgabepuffer: schreibt, solange Platz ist, zählt immer ─────────────────── */
typedef struct {
    char *buf;
    int64_t cap, len;
} obuf_;

static void put_(obuf_ *o, const char *s, int64_t n)
{
    if (o->len < o->cap) {
        const int64_t k = (o->cap - o->len < n) ? o->cap - o->len : n;
        memcpy(o->buf + o->len, s, (size_t) k);
    }
    o->len += n;
}

static void putc_(obuf_ *o, char c, int64_t times)
{
    for (int64_t i = 0; i < times; i++) put_(o, &c, 1);
}

static const char *const MON_[12] = {"January", "February", "March", "April", "May", "June", "July",
                                     "August", "September", "October", "November", "December"};
static const char *const WDAY_[7] = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
                                     "Saturday"};

typedef struct {
    char pad;          /* 0 (keiner), '-', '_', '0': der letzte Füllschalter gilt */
    int up, sw;        /* '^', '#' */
    int64_t width;     /* 0 = keine Breite */
} spec_;

/* Füllzeichen für Breiten bei Text: '0' mit Schalter 0, sonst Leerzeichen */
static char tfill_(const spec_ *sp)
{
    return sp->pad == '0' ? '0' : ' ';
}

/* Zahl v mit natürlicher Breite `digits` und Standard-Füllzeichen `fill`:
 *   kein Schalter: Breite max(width, digits) mit `fill`; '_': mit Leerzeichen; '0': mit Nullen;
 *   '-': keine natürliche Breite, eine angegebene Breite füllt mit Leerzeichen.
 * Negativ: bei Leerzeichen steht das Minus direkt vor den Ziffern, bei Nullen vor den Nullen, außer mit
 * zero_first (%s): dann die Nullen vor dem Minus. */
static void numx_(obuf_ *o, const spec_ *sp, int64_t v, int64_t digits, char fill, int zero_first)
{
    char tmp[24];
    int n = 0;
    const int neg = v < 0;
    uint64_t a = neg ? (uint64_t) 0 - (uint64_t) v : (uint64_t) v;
    do {
        tmp[n++] = (char) ('0' + (int) (a % 10));
        a /= 10;
    } while (a);
    char s[24];
    for (int i = 0; i < n; i++) s[i] = tmp[n - 1 - i];
    int64_t w;
    if (sp->pad == '-') {
        fill = ' ';
        w = sp->width;
    } else {
        if (sp->pad == '_') fill = ' ';
        else if (sp->pad == '0') fill = '0';
        w = sp->width > digits ? sp->width : digits;
    }
    const int64_t np = w - neg - n;                      /* Anzahl Füllzeichen */
    if (fill == '0' && !zero_first) {
        if (neg) putc_(o, '-', 1);
        if (np > 0) putc_(o, '0', np);
    } else {
        if (np > 0) putc_(o, fill, np);
        if (neg) putc_(o, '-', 1);
    }
    put_(o, s, n);
}

static void num_(obuf_ *o, const spec_ *sp, int64_t v, int64_t digits, char fill)
{
    numx_(o, sp, v, digits, fill, 0);
}

/* Text t (n Bytes): Breite mit tfill_; up = Großbuchstaben, low = Kleinbuchstaben (ASCII) */
static void text_(obuf_ *o, const spec_ *sp, const char *t, int64_t n, int up, int low)
{
    if (sp->width > n) putc_(o, tfill_(sp), sp->width - n);
    for (int64_t i = 0; i < n; i++) {
        char c = t[i];
        if (low && c >= 'A' && c <= 'Z') c = (char) (c + 32);
        else if (up && c >= 'a' && c <= 'z') c = (char) (c - 32);
        put_(o, &c, 1);
    }
}

static void strf_(obuf_ *o, int64_t z, const char *fmt, int64_t n);

/* Zusammengesetzte Umwandlung: ohne Schalter formatiert, dann als Text mit Breite und '^' ('#' wirkt nicht) */
static void composite_(obuf_ *o, const spec_ *sp, int64_t z, const char *f)
{
    char tmp[160];
    obuf_ t = {tmp, (int64_t) sizeof tmp, 0};
    strf_(&t, z, f, (int64_t) strlen(f));
    text_(o, sp, tmp, t.len < (int64_t) sizeof tmp ? t.len : (int64_t) sizeof tmp, sp->up, 0);
}

/* Modifikator E bzw. O zulässig? Sonst wird die ganze Angabe als Text ausgegeben (wie unbekannte
 * Umwandlungen). Festgelegt wie glibc unter Linux (R 4.3.3 als Orakel): E nur bei c C x X y Y (dokumentiert)
 * sowie bei Umwandlungen ohne alternative Darstellung, die den Modifikator übergehen (% n t p P r R s T u z Z);
 * O bei allen Zahlen, bei b B h (Monatsnamen) und ebenso bei % n t p P r R s T z Z; nicht bei a A c D F x X Y. */
static int mod_ok_(char mod, char k)
{
    if (k == '\0') return 0;
    if (mod == 'E') return strchr("ABDFGHIMSUVWabdeghjklmw", k) == NULL;
    if (mod == 'O') return strchr("ADFXYacx", k) == NULL;
    return 1;
}

static void strf_(obuf_ *o, int64_t z, const char *fmt, int64_t n)
{
    int64_t y;
    int m, d;
    sl_r_civil_from_days(z, &y, &m, &d);
    const int64_t wd = (z + 4) - sl_r_fdiv(z + 4, 7) * 7;            /* 0 = Sonntag */
    const int64_t yday = z - sl_r_days_from_civil(y, 1, 1);      /* 0-basiert */
    int64_t i = 0;
    while (i < n) {
        const char c = fmt[i];
        if (c != '%') {
            put_(o, &c, 1);
            i++;
            continue;
        }
        const int64_t start = i;
        i++;
        spec_ sp = {0, 0, 0, 0};
        while (i < n && (fmt[i] == '-' || fmt[i] == '_' || fmt[i] == '0' || fmt[i] == '^' || fmt[i] == '#')) {
            if (fmt[i] == '^') sp.up = 1;
            else if (fmt[i] == '#') sp.sw = 1;
            else sp.pad = fmt[i];
            i++;
        }
        while (i < n && fmt[i] >= '0' && fmt[i] <= '9') {
            if (sp.width < 1000000) sp.width = sp.width * 10 + (fmt[i] - '0');
            i++;
        }
        if (sp.width > 1000000) sp.width = 1000000;
        char mod = 0;
        if (i < n && (fmt[i] == 'E' || fmt[i] == 'O')) mod = fmt[i++];
        if (i >= n) {                                  /* unvollständige Angabe am Ende: als Text */
            text_(o, &sp, fmt + start, n - start, sp.up, 0);
            break;
        }
        const char k = fmt[i];
        i++;
        int bad = mod && !mod_ok_(mod, k);
        if (!bad) {
            switch (k) {
            case 'Y': case 'C': case 'G': {
                int64_t v = y;
                if (k == 'G') {
                    const int64_t th = z - ((wd + 6) % 7) + 3;   /* Donnerstag derselben Woche */
                    int tm, td;
                    sl_r_civil_from_days(th, &v, &tm, &td);
                } else if (k == 'C') {
                    v = sl_r_fdiv(y, 100);
                }
                num_(o, &sp, v, 1, '0');                         /* Jahre: ohne natürliche Breite */
                break;
            }
            case 'g': case 'V': {
                const int64_t th = z - ((wd + 6) % 7) + 3;
                int64_t ty;
                int tm, td;
                sl_r_civil_from_days(th, &ty, &tm, &td);
                const int64_t gw = sl_r_fdiv(th - sl_r_days_from_civil(ty, 1, 1), 7) + 1;
                num_(o, &sp, k == 'g' ? ty - sl_r_fdiv(ty, 100) * 100 : gw, 2, '0');
                break;
            }
            case 'y': num_(o, &sp, y - sl_r_fdiv(y, 100) * 100, 2, '0'); break;
            case 'm': num_(o, &sp, m, 2, '0'); break;
            case 'd': num_(o, &sp, d, 2, '0'); break;
            case 'e': num_(o, &sp, d, 2, ' '); break;
            case 'j': num_(o, &sp, yday + 1, 3, '0'); break;
            case 'u': num_(o, &sp, wd == 0 ? 7 : wd, 1, '0'); break;
            case 'w': num_(o, &sp, wd, 1, '0'); break;
            case 'U': num_(o, &sp, sl_r_fdiv(yday + 7 - wd, 7), 2, '0'); break;
            case 'W': num_(o, &sp, sl_r_fdiv(yday + 7 - (wd + 6) % 7, 7), 2, '0'); break;
            case 'H': case 'M': case 'S': num_(o, &sp, 0, 2, '0'); break;
            case 'I': num_(o, &sp, 12, 2, '0'); break;
            case 'k': num_(o, &sp, 0, 2, ' '); break;
            case 'l': num_(o, &sp, 12, 2, ' '); break;
            case 's': numx_(o, &sp, z * 86400, 1, ' ', 1); break;
            case 'z': {                                          /* Vorzeichen und hhmm je mit der Breite */
                text_(o, &sp, "+", 1, 0, 0);
                num_(o, &sp, 0, 4, '0');
                break;
            }
            case 'b': case 'h': text_(o, &sp, MON_[m - 1], 3, sp.up || sp.sw, 0); break;
            case 'B': text_(o, &sp, MON_[m - 1], (int64_t) strlen(MON_[m - 1]), sp.up || sp.sw, 0); break;
            case 'a': text_(o, &sp, WDAY_[wd], 3, sp.up || sp.sw, 0); break;
            case 'A': text_(o, &sp, WDAY_[wd], (int64_t) strlen(WDAY_[wd]), sp.up || sp.sw, 0); break;
            case 'p': text_(o, &sp, "AM", 2, 0, sp.sw); break;
            case 'P': text_(o, &sp, "am", 2, 0, 0); break;
            case 'Z': text_(o, &sp, "UTC", 3, 0, sp.sw); break;
            case 'F': composite_(o, &sp, z, "%Y-%m-%d"); break;
            case 'D': case 'x': composite_(o, &sp, z, "%m/%d/%y"); break;
            case 'T': case 'X': composite_(o, &sp, z, "%H:%M:%S"); break;
            case 'R': composite_(o, &sp, z, "%H:%M"); break;
            case 'r': composite_(o, &sp, z, "%I:%M:%S %p"); break;
            case 'c': composite_(o, &sp, z, "%a %b %e %H:%M:%S %Y"); break;
            case 'n': text_(o, &sp, "\n", 1, 0, 0); break;
            case 't': text_(o, &sp, "\t", 1, 0, 0); break;
            case '%': text_(o, &sp, "%", 1, 0, 0); break;
            default: bad = 1; break;
            }
        }
        /* unbekannt oder unzulässiger Modifikator: die Angabe als Text (mit Breite; '^' und bei b/h auch '#'
         * in Großbuchstaben, wie glibc unter Linux) */
        if (bad) text_(o, &sp, fmt + start, i - start, sp.up || (sp.sw && (k == 'b' || k == 'h')), 0);
    }
}

/* Umfang wie R: längere Ergebnisse meldet R als Fehler ("output string exceeded 2048 bytes") */
#define SL_R_STRFTIME_MAX 2048

int64_t sl_r_strftime(int64_t z, const char *fmt, int64_t flen, int digits_secs, char *buf, int64_t cap)
{
    if (z >= INT64_C(100000000000000) || z <= -INT64_C(100000000000000)) return -1;
    /* Leeres Format: Standardformat von format.Date (?strptime: "%Y-%m-%d", wenn alle Zeiten Mitternacht) */
    if (flen == 0) {
        fmt = "%Y-%m-%d";
        flen = 8;
    }
    obuf_ o = {buf, cap, 0};
    /* R's %OSn (?strptime: "Specific to R is %OSn ... truncated to 0 <= n <= 6 decimal places (and if %OS is
     * not followed by a digit, it uses the setting of getOption("digits.secs"), or if that is unset, n = 0)").
     * Nur das erste Vorkommen von "%OS" (als Text gesucht) gilt; es wird im Format ersetzt und das Format dann
     * als Ganzes ausgegeben: bei n = 0 durch "%S", sonst durch die Sekunden als Text ("00." und n Nullen;
     * ein Datum hat keine Sekunden). Weitere %OS sind gewöhnliches %S mit Modifikator O. Ziffern über 6
     * gelten als 6, ebenso digits_secs (Werte unter 0 als 0). */
    int64_t p = -1;
    for (int64_t j = 0; j + 2 < flen; j++)
        if (fmt[j] == '%' && fmt[j + 1] == 'O' && fmt[j + 2] == 'S') { p = j; break; }
    if (p < 0) {
        strf_(&o, z, fmt, flen);
    } else {
        int64_t q = p + 3, nd = digits_secs < 0 ? 0 : digits_secs > 6 ? 6 : digits_secs;
        if (q < flen && fmt[q] >= '0' && fmt[q] <= '9') {
            nd = fmt[q] - '0';
            if (nd > 6) nd = 6;
            q++;
        }
        char sec[10] = "%S";
        int64_t ls = 2;
        if (nd > 0) {
            memcpy(sec, "00.", 3);
            memset(sec + 3, '0', (size_t) nd);
            ls = 3 + nd;
        }
        const int64_t nf = p + ls + (flen - q);
        char small[512];
        char *f2 = nf <= (int64_t) sizeof small ? small : (char *) malloc((size_t) nf);
        if (!f2) return -3;
        memcpy(f2, fmt, (size_t) p);
        memcpy(f2 + p, sec, (size_t) ls);
        memcpy(f2 + p + ls, fmt + q, (size_t) (flen - q));
        strf_(&o, z, f2, nf);
        if (f2 != small) free(f2);
    }
    return o.len > SL_R_STRFTIME_MAX ? -2 : o.len;
}

static int get_num_(const char *s, int64_t len, int64_t *p, int lo, int hi, int nd, int *val)
{
    while (*p < len && s[*p] == ' ') (*p)++;
    if (*p >= len || s[*p] < '0' || s[*p] > '9') return 0;
    int v = 0, k = nd;
    do {
        v = v * 10 + (s[*p] - '0');
        (*p)++;
        k--;
    } while (k > 0 && *p < len && s[*p] >= '0' && s[*p] <= '9');
    if (v < lo || v > hi) return 0;
    *val = v;
    return 1;
}

int sl_r_strptime_ymd(const char *s, int64_t len, int sep, int64_t *z)
{
    static const int dim[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    int64_t p = 0;
    int y, m, d;
    if (!get_num_(s, len, &p, 0, 9999, 4, &y)) return 0;
    if (p >= len || s[p] != (char) sep) return 0;
    p++;
    if (!get_num_(s, len, &p, 1, 12, 2, &m)) return 0;
    if (p >= len || s[p] != (char) sep) return 0;
    p++;
    if (!get_num_(s, len, &p, 1, 31, 2, &d)) return 0;
    if (d > dim[m - 1] + (m == 2 && is_leap_(y))) return 0;
    *z = sl_r_days_from_civil(y, m, d);
    return 1;
}
