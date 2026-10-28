/* core/slc_opt.h – Optimierer und numerischer Gradient der C-Bibliothek slc (SimLev core, Etappe 9.3)
 *
 * Verfahren:  BFGS mit starker Wolfe-Liniensuche, projizierter BFGS für Schranken, Nelder-Mead,
 *             Gradient über zentrale Differenzen (einseitig an Schranken); Einzelheiten und
 *             Quellen im Kopf von core/slc_opt.c, Prüffunktionen in core/slc_opt_test.c.
 * Quellen:    Entwurf SPEZ-9, Abschnitte B.8 und B.9; Literatur in core/slc_opt.c.
 * Konstanten: keine (Verfahrensparameter in core/slc_opt.c).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 optim (nur Plausibilität, scratchpad/e93/).
 *
 * Zwei Wege (B.8):
 *
 *   1. Rückfrage an den Host (reverse communication), für Zielfunktionen in R, Python, Julia:
 *        ws = Feld mit sl_opt_wsize(method, n) double (vom Host angelegt; keine Zeiger darin)
 *        sl_opt_init(cx, method, n, x0, lo, hi, &ctrl, have_grad, ws);
 *        while (sl_opt_ask(cx, ws, x, &need) == SL_OK && need != SL_DONE) {
 *            if (need == SL_NEED_F) f = fn(x);  else  gr(x, g);      (Host rechnet selbst)
 *            if (sl_opt_tell(cx, ws, f, g) != SL_OK) break;            (Fehler: cx->msg)
 *        }
 *        sl_opt_result(ws, x, &f, &code, &iter, &nfev, &ngev);
 *      Zwischen ask und tell ist der Kern nicht aktiv; Fehler der Zielfunktion laufen als
 *      gewöhnliche Host-Fehler durch. Ohne Gradient (have_grad = 0) fragt der Kern nur
 *      Funktionswerte ab und bildet den Gradienten selbst (B.9).
 *
 *   2. Direkt in C (Zielfunktionen der Modelle, Etappe 9.4): sl_minimize mit Funktionszeigern.
 *      Er durchläuft dieselbe Schleife wie 1., die Ergebnisse sind also bitgleich.
 *
 * Steuerung (sl_opt_ctrl, Standardwerte mit sl_opt_ctrl_default):
 *   maxit    Iterationen (BFGS, PBFGS: angenommene Schritte; NM: Simplex-Schritte);
 *            0 = ohne Grenze. Standard 100 (BFGS, PBFGS) bzw. 0 (NM).
 *   maxfev   Auswertungen der Zielfunktion ohne die Differenzen des Gradienten; 0 = ohne
 *            Grenze. Standard 0 (BFGS, PBFGS) bzw. 500 (NM; so begrenzt optim mit maxit).
 *   reltol   relative Abnahme |f_k - f_k+1| <= reltol (|f_k| + reltol); NM: Spanne der
 *            Funktionswerte im Simplex. Standard sqrt(eps) = 1.490116e-8.
 *   gtol     ||P(x - g) - x||_inf <= gtol (ohne Schranken ||g||_inf), nur BFGS/PBFGS;
 *            Standard 1e-8; 0 = nur exakt null.
 *   xtol     Schritt ||s||_inf <= xtol (1 + ||x||_inf) (NM: Durchmesser des Simplex);
 *            Standard eps = 2^-52.
 *   fnscale  minimiert wird f / fnscale (negativ: Maximum); Standard 1.
 *   parscale NULL oder n Werte > 0: gerechnet wird in z = x / parscale; Standard NULL (= 1).
 *   trace    nur für die Hüllen (Mitschrift der Auswertungen), der Kern ignoriert es.
 *   Alle Toleranzen gelten in den skalierten Größen (z, f / fnscale).
 *
 * Ergebnis (code, wie optim$convergence):
 *   0 konvergiert (reltol, gtol oder xtol), 1 maxit bzw. maxfev erreicht, 2 Liniensuche ohne
 *   Fortschritt (bester Punkt), 3 Simplex entartet (NM). Kein Code erzeugt eine Warnung.
 *   sl_opt_message(reason) gibt den Text zum genauen Grund (sl_opt_info).
 * Fehler: SL_EARG (Argumente), SL_ENONFINITE ("<Verfahren>: Zielfunktion am Startwert nicht
 *   endlich", ebenso Startwert bzw. Gradient am Startwert), SL_EINTR (Benutzerabbruch, je
 *   Iteration geprüft). Ein nicht endlicher Wert während der Suche zählt als +Inf.
 */
#ifndef SLC_OPT_H
#define SLC_OPT_H

#include "slc.h"

#ifdef __cplusplus
extern "C" {
#endif

enum { SL_OPT_BFGS = 1, SL_OPT_PBFGS = 2, SL_OPT_NM = 3 };

/* Anfrage an den Host (sl_opt_ask) */
enum { SL_DONE = 0, SL_NEED_F = 1, SL_NEED_G = 2 };

/* Ergebniscodes (wie optim$convergence) */
enum { SL_OPT_CONV = 0, SL_OPT_MAXIT = 1, SL_OPT_LSFAIL = 2, SL_OPT_DEGEN = 3 };

/* genauer Grund des Endes (sl_opt_info, sl_opt_message) */
enum { SL_WHY_NONE = 0, SL_WHY_RELTOL = 1, SL_WHY_GTOL = 2, SL_WHY_XTOL = 3, SL_WHY_MAXIT = 4,
       SL_WHY_MAXFEV = 5, SL_WHY_LSFAIL = 6, SL_WHY_DEGEN = 7, SL_WHY_ERROR = 8 };

typedef struct sl_opt_ctrl {
    int           maxit;      /* Iterationen, 0 = ohne Grenze */
    int           maxfev;     /* Funktionsauswertungen (ohne Differenzen), 0 = ohne Grenze */
    double        reltol;     /* relative Abnahme bzw. Spanne im Simplex */
    double        gtol;       /* projizierte Gradientennorm (BFGS, PBFGS) */
    double        xtol;       /* Schritt bzw. Durchmesser des Simplex, relativ zu 1 + ||x|| */
    double        fnscale;    /* f / fnscale wird minimiert */
    const double *parscale;   /* NULL oder n Werte > 0 (nur in sl_opt_init gelesen) */
    int           trace;      /* nur Hüllen */
} sl_opt_ctrl;

void        sl_opt_ctrl_default(sl_opt_ctrl *ctrl, int method);
int64_t     sl_opt_wsize(int method, int n);          /* Länge des Arbeitsfelds; -1 bei Fehler */
const char *sl_opt_method_name(int method);           /* "BFGS", "PBFGS", "Nelder-Mead" */

/* lo, hi: NULL oder n Werte (nur PBFGS; -Inf/+Inf erlaubt; BFGS und NM verlangen NULL) */
int sl_opt_init(sl_ctx *cx, int method, int n, const double *x0, const double *lo, const double *hi,
                const sl_opt_ctrl *ctrl, int have_grad, double *ws);
/* nächste Anfrage: need = SL_NEED_F (f(x) liefern), SL_NEED_G (Gradient an x liefern) oder SL_DONE */
int sl_opt_ask(sl_ctx *cx, const double *ws, double *x_eval, int *need);
/* Antwort: f bei SL_NEED_F (g wird nicht gelesen), g (n Werte) bei SL_NEED_G (f wird nicht gelesen) */
int sl_opt_tell(sl_ctx *cx, double *ws, double f, const double *g);
/* bester Punkt (x: n Werte, ungeskaliert), f (ungeskaliert), code, Iterationen,
 * Funktionsauswertungen (ohne Differenzen), Gradienten; Rückgabe: Status des Laufs */
int sl_opt_result(const double *ws, double *x, double *f, int *code, int *iter, int *nfev, int *ngev);
/* genauer Grund (SL_WHY_*) und alle Auswertungen der Zielfunktion (mit Differenzen) */
int sl_opt_info(const double *ws, int *reason, int *ntot);
int sl_opt_dim(const double *ws);                     /* n eines initialisierten Arbeitsfelds, sonst -1 */
const char *sl_opt_message(int reason);

/* Direkt in C (9.4: GARCH, GPD, DCC, MS-GARCH). f liefert den Wert (nicht endlich = +Inf),
 * g den Gradienten (NULL: zentrale Differenzen). x: Start und Ergebnis. */
typedef double (*sl_fn)(const double *x, void *data);
typedef void   (*sl_gr)(const double *x, double *g, void *data);
int sl_minimize(sl_ctx *cx, int method, int n, double *x, const double *lo, const double *hi,
                const sl_opt_ctrl *ctrl, sl_fn f, sl_gr g, void *data,
                double *fmin, int *code, int *iter, int *nfev);

/* Numerischer Gradient nach B.9 an x mit f(x) = fx (lo, hi: NULL oder n Werte); nfev: Zahl
 * der Auswertungen (darf NULL sein). Dieselbe Schrittweitenregel wie in den Optimierern. */
int sl_numgrad(sl_ctx *cx, int n, const double *x, const double *lo, const double *hi, double fx,
               sl_fn f, void *data, double *g, int *nfev);

/* Prüffunktionen (core/slc_opt_test.c; Plausibilität und Gleichlauf): Wert an x, Gradient nach
 * g (NULL: ohne). id: 1 Rosenbrock (verkettet, n >= 2), 2 Beale (n = 2), 3 Powell singulär
 * (n = 4), 4 Wood (n = 4), 5 schlecht skalierte Quadratik (n >= 2), 6 nicht glatt (Betrag),
 * 7 log-Schranke (NaN für x <= 0, n >= 1), 8 Quadratik mit Kopplung (Schrankentests).
 * Unbekannte id oder unpassendes n: NaN. */
double sl_opt_testfn(int id, int n, const double *x, double *g);
/* sl_minimize bzw. sl_numgrad mit der Prüffunktion id (ntot: alle Auswertungen) */
int sl_opt_test_minimize(sl_ctx *cx, int id, int method, int n, double *x, const double *lo, const double *hi,
                         const sl_opt_ctrl *ctrl, int use_grad, double *fmin, int *code, int *iter, int *nfev,
                         int *ntot);
int sl_opt_test_numgrad(sl_ctx *cx, int id, int n, const double *x, const double *lo, const double *hi,
                        double *g, int *nfev);

#ifdef __cplusplus
}
#endif

#endif /* SLC_OPT_H */
