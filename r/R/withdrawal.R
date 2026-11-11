# =============================================================================
#  withdrawal.R  —  Entnahme-Simulationen (Ruhestand / Decumulation)
# -----------------------------------------------------------------------------
#  withdrawal_rule()        Regel-Objekt (wie asset_config()), 14 Regeln
#  withdrawal_cohorts()     historische rollierende Kohorten (Bengen/Trinity)
#  withdrawal_paths()       Perioden-Renditen aus bootstrap()-Pfaden, Listen von
#                           simulation()-Ergebnissen oder bootstrap_study()
#  result_index()           zeitgewichteter Wertindex eines simulation()-Ergebnisses
#  withdrawal_simulation()  schneller C++-Kern ueber viele Pfade, optional mit
#                           vereinfachter deutscher Besteuerung
#  withdrawal_perfect_rate() PWR nach Suarez, Suarez & Walz (2015)
#  withdrawal_max_rate()    maximale Anfangsrate fuer eine Ziel-Erfolgsquote
#
#  Die Entnahmephase ist bewusst von simulation() getrennt: Ein Ergebnis von
#  simulation() (z. B. per saveRDS() gespeichert) oder einer Bootstrap-Studie
#  liefert die Renditen, withdrawal_simulation() rechnet darauf die Entnahmen.
#
#  PROZENT-KONVENTION: rate, ceiling, floor, cut, raise, exp_return usw. in
#  Prozent (rate = 4 bedeutet 4 % p. a.), wie im restlichen Paket.
# =============================================================================

.wd_rules <- c(constant = 1L, percent = 2L, vanguard = 3L, guyton_klinger = 4L,
               floor_ceiling = 5L, clyatt = 6L, ratchet = 7L, endowment = 8L,
               one_over_n = 9L, vpw = 10L, abw = 11L, cape = 12L, sensible = 13L,
               hebeler = 14L)

.wd_labels <- c(constant = "Konstante reale Entnahme (Bengen/Trinity)",
                percent = "Fester Prozentsatz des Depots",
                vanguard = "Vanguard Dynamic Spending (Ceiling/Floor)",
                guyton_klinger = "Guyton-Klinger-Entscheidungsregeln",
                floor_ceiling = "Floor-and-Ceiling (Bengen 2001)",
                clyatt = "Clyatt 95-%-Regel",
                ratchet = "Kitces-Ratchet",
                endowment = "Endowment-/Yale-Regel (Tobin)",
                one_over_n = "1/N (Restlaufzeit)",
                vpw = "Variable Percentage Withdrawal (Bogleheads)",
                abw = "Amortisationsbasierte Entnahme (ABW)",
                cape = "CAPE-basierte Regel",
                sensible = "Sensible Withdrawals",
                hebeler = "Hebeler Autopilot II")

# --- Eingabepruefung Entnahme und Planung (seit 1.6.4, K42 E3; Hilfen in pruefen.R) ----------------------------
# Auswahl wie match.arg (Standardvektor oder NULL = erste Wahl, eindeutige Praefixe werden ergaenzt); alles andere
# (NA, Zahl, Vektor, unbekannter Text) mit der Meldung auswahl
.e3_choice <- function(x, choices, fn, arg) {
  if (is.null(x) || identical(x, choices)) return(choices[1L])
  chk_nofactor(x, fn, arg)
  if (is.character(x) && length(x) == 1L && !is.na(x)) {
    i <- pmatch(x, choices, nomatch = 0L, duplicates.ok = TRUE)
    if (i > 0L) return(choices[i])
  }
  chk_stop("auswahl", fn, arg, paste0("\"", choices, "\"", collapse = ", "))
}

# Datumsspalte kein Faktor (Entscheidung 15; bisher still in Text umgewandelt)
.e3_datecol <- function(data, fn) {
  if (is.factor(data[["date"]])) chk_stop("spalte_faktor", fn, "date")
  invisible(data)
}

# Zahlenspalte (kein Faktor, kein Text, kein Datum); eine Spalte nur aus NA gilt als Zahlenspalte (Entscheidung 14)
.e3_numcol <- function(data, col, fn) {
  v <- data[[col]]
  if (is.factor(v)) chk_stop("spalte_faktor", fn, col)              # Entscheidung 15
  if (!((is.numeric(v) && !is.factor(v)) || all(is.na(v)))) chk_stop("spalte_typ", fn, col, chk_msg("typ.numerisch"))
  invisible(data)
}

# Vektor nicht leerer Namen (Spalten), mindestens einer
.e3_names <- function(x, fn, arg) {
  chk_nofactor(x, fn, arg)
  if (!(is.character(x) && length(x) >= 1L && !anyNA(x) && all(nzchar(x)))) chk_stop("e3.namen", fn, arg)
  invisible(x)
}

# Spalte date: aufsteigend, ohne NA (Perioden ueber Kalendergrenzen setzen sortierte Daten voraus)
.e3_dates_sorted <- function(d, fn, land = NULL) {
  if (anyNA(d) || is.unsorted(d)) {
    if (is.null(land)) chk_stop("e3.datum", fn) else chk_stop("e3.datum_land", fn, land)
  }
  invisible(d)
}

#' Entnahmeregel definieren
#'
#' Erzeugt eine validierte Entnahmeregel fuer [withdrawal_simulation()] und
#' [withdrawal_max_rate()]. Die Jahresentnahme wird zu Beginn
#' jedes Planjahres festgelegt (Guyton & Klinger 2006; Suarez et al. 2015) und
#' bei unterjaehrigen Perioden gleichmaessig ausgezahlt (Jahresbetrag / Perioden
#' je Jahr). Alle Betraege sind Netto-Konsum; Steuern werden zusaetzlich aus dem
#' Depot verkauft. Alle Raten und Schranken werden in Prozent angegeben
#' (\code{rate = 4} bedeutet 4 % des Depots); welche Argumente eine Regel
#' nutzt, zeigt die Tabelle unter Details. Jedes Argument muss eine einzelne
#' Zahl ohne \code{NA} im zulaessigen Bereich sein (Prozentsaetze wie
#' \code{floor}, \code{cut}, \code{smoothing}, \code{floor95},
#' \code{extra}, \code{max_rate} 0 bis 100, \code{ceiling}, \code{raise},
#' \code{inflation_cap} >= 0, \code{min_real <= max_real}, bei \code{vpw}
#' \code{age < max_age} und \code{max_rate > 0}); sonst bricht die Funktion
#' mit einer Meldung ab. Schranken zwischen 0 und 0,2 loesen eine Warnung aus
#' (vermutlich Anteil statt Prozent).
#'
#' Bezeichnungen: \eqn{P} = nominaler Depotwert zu Beginn des Planjahres vor
#' der Entnahme, \eqn{P_1} = Startdepot, \eqn{W_{t-1}} = nominale Entnahme des
#' Vorjahres, \eqn{\pi} = Inflation des Vorjahres, Restjahre = verbleibende
#' Planjahre der Simulation einschliesslich des aktuellen Jahres,
#' \eqn{PMT(r, n)} = vorschuessige Annuitaet je Geldeinheit Kapital
#' (\eqn{r / ((1 - (1+r)^{-n})(1+r))}, bei \eqn{n \le 1} gleich 1).
#' Nach jeder Regel werden \code{min_real} und \code{max_real} angewendet.
#'
#' Genutzte Argumente je Regel (Standardwerte von \code{ceiling},
#' \code{floor} und \code{smoothing} in Klammern; \code{min_real} und
#' \code{max_real} gelten fuer alle Regeln):
#'
#' | Regel | genutzte Argumente |
#' |:---|:---|
#' | `constant` | `rate` |
#' | `percent` | `rate` |
#' | `vanguard` | `rate`, `ceiling` (5), `floor` (2.5) |
#' | `guyton_klinger` | `rate`, `ceiling` (20), `floor` (20), `cut`, `raise`, `cpr_years`, `inflation_cap`, `skip_inflation` |
#' | `floor_ceiling` | `rate`, `ceiling` (20), `floor` (15) |
#' | `clyatt` | `rate`, `floor95` |
#' | `ratchet` | `rate`, `raise`, `ratchet_threshold`, `ratchet_gap` |
#' | `endowment` | `rate`, `smoothing` (70) |
#' | `one_over_n` | keine (nur Restjahre) |
#' | `vpw` | `exp_return` bzw. `stock_share`, `age`, `max_age`, `max_rate` |
#' | `abw` | `exp_return` bzw. `stock_share`, `fv` (Restjahre) |
#' | `cape` | `cape_a`, `cape_b`; CAPE-Reihe in den Pfaden noetig |
#' | `sensible` | `rate`, `extra` |
#' | `hebeler` | `exp_return` bzw. `stock_share`, `smoothing` (75) (Restjahre) |
#'
#' Die Restjahre (\code{one_over_n}, \code{abw}, \code{hebeler} und die
#' Capital-Preservation-Rule von \code{guyton_klinger}) sind kein Argument der
#' Regel: Sie ergeben sich in [withdrawal_simulation()] aus der Zahl der
#' Planjahre (Pfadlaenge bzw. \code{years}). Eine zufaellige Laufzeit je Pfad
#' (\code{horizon} in [withdrawal_simulation()], Objekt aus [withdrawal_horizon()])
#' aendert nur die Auswertung (Erfolg, Konsum und Endvermoegen bis zum
#' Horizont); die Regel rechnet weiter mit den Restjahren der vollen
#' Pfadlaenge.
#'
#' @param type Regel (Zeichenkette, Standard \code{"constant"}):
#'   \describe{
#'     \item{"constant"}{Bengen (1994) / Trinity-Studie: \eqn{W_1 = rate \cdot P_1}, danach \eqn{W_{t-1}(1+\pi)} (real konstant).}
#'     \item{"percent"}{Fester Prozentsatz des aktuellen Depots: \eqn{rate \cdot P}.}
#'     \item{"vanguard"}{Vanguard Dynamic Spending: \eqn{rate \cdot P}, die Veraenderung gegenueber \eqn{W_{t-1}(1+\pi)} (also real) begrenzt auf +\code{ceiling} Prozent / -\code{floor} Prozent (Standard 5 / 2,5).}
#'     \item{"guyton_klinger"}{Guyton & Klinger (2006): Erstentnahme \eqn{rate \cdot P_1}, Anfangsrate \eqn{WR_0 = W_1 / P_1}. Danach \eqn{W_{t-1}} mit Inflationsausgleich (hoechstens \code{inflation_cap} Prozent). Withdrawal-Rule (\code{skip_inflation}): kein Inflationsausgleich, wenn die nominale Depotrendite des Vorjahres negativ war und die inflationierte Entnahme eine Rate ueber \eqn{WR_0} ergaebe. Capital-Preservation-Rule: Kuerzung um \code{cut} Prozent, wenn die aktuelle Rate \eqn{W / P} ueber \eqn{WR_0 (1 + ceiling/100)} liegt und noch mehr als \code{cpr_years} Restjahre bleiben. Prosperity-Rule: sonst Erhoehung um \code{raise} Prozent, wenn die Rate unter \eqn{WR_0 (1 - floor/100)} liegt. Standard 20 / 20 / 10 / 10, 15 Jahre.}
#'     \item{"floor_ceiling"}{Bengen (2001): \eqn{rate \cdot P}, begrenzt auf das (1 - \code{floor}/100)- bis (1 + \code{ceiling}/100)-fache der realen Erstentnahme in heutigen Preisen (Standard 15 / 20).}
#'     \item{"clyatt"}{Clyatt: \eqn{\max(rate \cdot P, floor95/100 \cdot W_{t-1})}, nominal (ohne Inflationsausgleich).}
#'     \item{"ratchet"}{Kitces: real konstant wie \code{"constant"}; Erhoehung um \code{raise} Prozent (10), wenn das reale Depot das \code{ratchet_threshold}-fache (1,5) des realen Startdepots uebersteigt, hoechstens alle \code{ratchet_gap} (3) Jahre (fruehestens im Jahr 1 + \code{ratchet_gap}).}
#'     \item{"endowment"}{Yale/Tobin: \eqn{\lambda W_{t-1}(1+\pi) + (1-\lambda) rate \cdot P} mit \eqn{\lambda} = \code{smoothing}/100 (Standard 70).}
#'     \item{"one_over_n"}{\eqn{P} / Restjahre; leert das Depot planmaessig bis zum Ende der Simulation.}
#'     \item{"vpw"}{Bogleheads VPW: \eqn{P \cdot PMT(r, n)} mit \eqn{n} = \code{max_age} - Alter im Planjahr (\code{age} im ersten Jahr) und r = \code{exp_return}/100, hoechstens \code{max_rate} Prozent des Depots; bei \eqn{n \le 1} das ganze Depot.}
#'     \item{"abw"}{Amortisation: reale vorschuessige Annuitaet \eqn{(P_{real} - fv / (1+r)^n) \cdot PMT(r, n)} ueber n = Restjahre mit r = \code{exp_return}/100 und Zielvermoegen \code{fv}; nicht negativ.}
#'     \item{"cape"}{\eqn{(cape_a/100 + cape_b / CAPE) \cdot P} mit dem CAPE zu Beginn des Planjahres (CAPE <= 0: nur \code{cape_a}). Standard \code{cape_a} = 1,75, \code{cape_b} = 0,5 (ERN); CAPE-Reihe noetig (Argument \code{cape} in [withdrawal_cohorts()] bzw. [withdrawal_paths()]).}
#'     \item{"sensible"}{Erstes Jahr \eqn{rate \cdot P_1}; danach diese Erstentnahme real (inflationiert) plus \code{extra} Prozent (10) des realen Depotzuwachses seit der Vorjahresentnahme (nur Zuwaechse).}
#'     \item{"hebeler"}{Autopilot II: \eqn{\lambda W_{t-1}(1+\pi) + (1-\lambda) PMT(r, n) \cdot P} mit \eqn{\lambda} = \code{smoothing}/100 (Standard 75), r = \code{exp_return}/100, n = Restjahre; im ersten Jahr nur die Annuitaet.}
#'   }
#' @param rate Entnahmerate in Prozent (4 = 4 % des Depots; Standard 4;
#'   zulaessig 0 bis 100): Anfangsrate (\code{constant}, \code{guyton_klinger},
#'   \code{ratchet}, \code{sensible}) bzw. laufende Rate auf das aktuelle Depot
#'   (\code{percent}, \code{vanguard}, \code{floor_ceiling}, \code{clyatt},
#'   \code{endowment}). Von \code{one_over_n}, \code{vpw}, \code{abw},
#'   \code{cape} und \code{hebeler} nicht genutzt. Werte zwischen 0 und 0,2
#'   loesen bei \code{constant}, \code{percent}, \code{vanguard} und
#'   \code{guyton_klinger} eine Warnung aus (vermutlich Anteil statt Prozent).
#' @param ceiling,floor Obere bzw. untere Schranke in Prozent (>= 0), Bedeutung
#'   je Regel: \code{vanguard} = maximale reale Erhoehung / Senkung gegenueber
#'   dem Vorjahr (Standard 5 / 2,5); \code{guyton_klinger} = Abstand der
#'   Leitplanken von der Anfangsrate (20 / 20); \code{floor_ceiling} = Korridor
#'   um die reale Erstentnahme (20 / 15). \code{NULL} = diese
#'   Regel-Standards; andere Regeln ignorieren die Werte (gespeichert als 0).
#' @param cut,raise Kuerzung bzw. Erhoehung der Entnahme in Prozent (>= 0,
#'   Standard 10 / 10): \code{cut} fuer \code{guyton_klinger}, \code{raise} fuer
#'   \code{guyton_klinger} und \code{ratchet}.
#' @param cpr_years Guyton-Klinger: Anzahl Jahre (Standard 15). Die
#'   Capital-Preservation-Rule greift nur, solange mehr als \code{cpr_years}
#'   Restjahre (einschliesslich des aktuellen) bleiben. Seit 1.6.4 hoechstens 100.
#' @param inflation_cap Guyton-Klinger: maximaler Inflationsausgleich je Jahr
#'   in Prozent (Standard \code{Inf} = unbegrenzt, wie in der Fassung von 2006).
#' @param skip_inflation Logisch, Guyton-Klinger: Withdrawal-Rule aktiv
#'   (Standard \code{TRUE}; siehe \code{type}).
#' @param smoothing Glaettungsgewicht der Vorjahresentnahme in Prozent
#'   (0 bis 100) fuer \code{endowment} und \code{hebeler}. \code{NULL} = 75 bei
#'   \code{hebeler}, sonst 70.
#' @param exp_return Erwartete reale Rendite in Prozent p. a. fuer
#'   \code{vpw}, \code{abw} und \code{hebeler}. \code{NULL} =
#'   5 x \code{stock_share}/100 + 1,9 x (1 - \code{stock_share}/100), beim
#'   Standard \code{stock_share = 60} also 3,76.
#' @param stock_share Aktienquote in Prozent (60 = 60 %, Standard 60); nur
#'   fuer den Standardwert von \code{exp_return} verwendet.
#' @param age,max_age Alter bei Rentenbeginn und Planungsalter in Jahren
#'   (Standard 65 / 100), nur \code{vpw}.
#' @param fv \code{abw}: reales Zielvermoegen am Ende als Geldbetrag in
#'   Kaufkraft des Startzeitpunkts (Standard 0 = Depot aufbrauchen).
#' @param cape_a,cape_b CAPE-Regel: Konstante in Prozent (Standard 1.75 =
#'   1,75 %) und Faktor auf 1 / CAPE als Anteil (Standard 0.5; bei CAPE 25
#'   also 0.5 / 25 = 0.02 = 2 %).
#' @param ratchet_threshold \code{ratchet}: Faktor auf das reale Startdepot
#'   (Standard 1.5 = 150 %), ab dem erhoeht wird.
#' @param ratchet_gap \code{ratchet}: Mindestabstand zwischen Erhoehungen in
#'   Jahren (Standard 3). Seit 1.6.4 hoechstens 100.
#' @param extra \code{sensible}: Anteil des realen Depotzuwachses in Prozent
#'   (Standard 10).
#' @param floor95 \code{clyatt}: Mindestanteil der Vorjahresentnahme in
#'   Prozent (Standard 95).
#' @param min_real,max_real Absolute Unter- bzw. Obergrenze der Jahresentnahme
#'   als Geldbetrag in Kaufkraft des Startzeitpunkts, fuer alle Regeln
#'   (Standard 0 und \code{Inf} = keine Grenze).
#' @param max_rate \code{vpw}: Hoechstsatz in Prozent des Depots (Standard 100).
#' @return Objekt der Klasse \code{withdrawal_rule} (Liste) mit
#'   \code{type} und allen Parametern in Prozent-Konvention, wobei
#'   \code{ceiling}, \code{floor}, \code{smoothing} und \code{exp_return}
#'   bereits mit den Standardwerten gefuellt sind (\code{stock_share} wird
#'   nicht gespeichert). Ausgabe mit \code{print()}.
#' @section Quellen und Abweichungen:
#' \describe{
#'   \item{\code{clyatt}}{Nach Clyatt (2005): jedes Jahr \code{rate} des
#'     aktuellen Depots, mindestens \code{floor95} Prozent der
#'     Vorjahresentnahme, nominal; Kuerzungen in Folgejahren verketten sich
#'     (95 % von 95 %). Keine Abweichung.}
#'   \item{\code{endowment}}{Angelehnt an die Yale-Regel (Swensen 2009,
#'     Kap. 3, mit Verweis auf Tobin 1974): Gewicht mal Vorjahresentnahme plus
#'     (1 - Gewicht) mal Zielrate mal Vermoegen; Yale frueher 70 %, heute
#'     80 %. Abweichend: Yale wendet die Zielrate auf den Wert zum Ende des
#'     vorigen Geschaeftsjahres an und schreibt die Summe beider Teile mit
#'     der Inflation fort; SimLev nimmt das Depot zu Beginn des Planjahres und
#'     inflationiert nur die Vorjahresentnahme.}
#'   \item{\code{one_over_n}}{Nach Bogleheads Wiki, Withdrawal methods
#'     (1/N): Depot geteilt durch die Restjahre. Abweichend: das Wiki
#'     empfiehlt 1/N eher als Hoechstbetrag; SimLev entnimmt genau 1/N.}
#'   \item{\code{abw}}{Angelehnt an die jaehrlich neu berechnete virtuelle
#'     Annuitaet (ARVA) von Waring & Siegel (2015): Rate einer
#'     vorschuessigen Annuitaet mit dem aktuellen Depot ueber die Restjahre.
#'     Abweichend: feste erwartete Realrendite \code{exp_return} statt der
#'     aktuellen Marktzinsen; reales Zielvermoegen \code{fv} als eigene
#'     Ergaenzung.}
#'   \item{\code{cape}}{Nach Jeske (2017): Rate = a + b / CAPE auf das
#'     aktuelle Depot; 1,75 % und 0,5 sind eine der dort gerechneten
#'     Varianten. Abweichend: dort monatlich mit den Werten vom Ende des
#'     Vormonats, in SimLev jaehrlich mit dem CAPE zu Beginn des
#'     Planjahres; CAPE <= 0 ergibt nur a (eigene Festlegung).}
#'   \item{\code{sensible}}{Angelehnt an Ponzo (o. J.), Sensible
#'     Withdrawals: Grundentnahme plus ein Anteil (dort Beispiele 10 und
#'     25 %) des Zuwachses, wenn das Depot nach der Grundentnahme staerker
#'     als die Inflation gewachsen ist. Abweichend bzw. dort offen: SimLev
#'     setzt die Grundentnahme als inflationierte Erstentnahme
#'     \eqn{rate \cdot P_1}, misst den Zuwachs als reales Depot vor der Entnahme minus
#'     reales Depot nach der Vorjahresentnahme und begrenzt den Zusatz nicht.}
#'   \item{\code{hebeler}}{Angelehnt an Hebelers Retirement Autopilot
#'     (Hebeler 2001); Gewichtung 75 % inflationierte Vorjahresentnahme plus
#'     25 % Annuitaet nach Steiner (2015). Abweichend: Hebeler rechnet die
#'     Annuitaet ueber die Lebenserwartung (IRS-Tabellen) mit einem niedrigen
#'     Realzins, SimLev ueber die Restjahre der Simulation mit
#'     \code{exp_return}.}
#' }
#' @references Bengen (1994, 2001); Cooley, Hubbard & Walz (1998);
#'   Guyton & Klinger (2006), Journal of Financial Planning 19(3);
#'   Vanguard (2021), Sustainable spending rates in turbulent markets;
#'   Bogleheads Wiki, Variable percentage withdrawal; Kitces (2015);
#'   Suarez, Suarez & Walz (2015), Financial Services Review 24;
#'   Clyatt, B. (2005), Work Less, Live More: The New Way to Retire Early,
#'   Nolo, Berkeley; Swensen, D. F. (2009), Pioneering Portfolio Management,
#'   Fully Revised and Updated, Free Press, Kap. 3; Tobin, J. (1974), What
#'   is permanent endowment income?, American Economic Review 64(2),
#'   427-432; Bogleheads Wiki, Withdrawal methods,
#'   \url{https://www.bogleheads.org/wiki/Withdrawal_methods}; Waring, M. B.
#'   & Siegel, L. B. (2015), The only spending rule article you will ever
#'   need, Financial Analysts Journal 71(1), 91-107,
#'   \doi{10.2469/faj.v71.n1.2}; Jeske, K. (2017), The ultimate guide to safe
#'   withdrawal rates - Part 18: Flexibility and the mechanics of CAPE-based
#'   rules, earlyretirementnow.com, 30.08.2017; Ponzo, P. (o. J.), Sensible
#'   withdrawals, gummy-stuff,
#'   \url{https://www.financialwisdomforum.org/gummy-stuff/sensible_withdrawals.htm};
#'   Hebeler, H. K. (2001), J.K. Lasser's Your Winning Retirement Plan,
#'   Wiley; Steiner, K. (2015), Bud Hebeler's Autopilot withdrawal rule,
#'   Blog How much can I afford to spend in retirement?, 22.01.2015.
#' @seealso [withdrawal_simulation()], [withdrawal_max_rate()], [withdrawal_horizon()]
#' @examples
#' withdrawal_rule("constant", rate = 4)
#' withdrawal_rule("guyton_klinger", rate = 5.2)
#' withdrawal_rule("vanguard", rate = 5, ceiling = 5, floor = 2.5)
#' @export
withdrawal_rule <- function(type = names(.wd_rules), rate = 4,
                            ceiling = NULL, floor = NULL, cut = 10, raise = 10,
                            cpr_years = 15, inflation_cap = Inf, skip_inflation = TRUE,
                            smoothing = NULL, exp_return = NULL, stock_share = 60,
                            age = 65, max_age = 100, fv = 0,
                            cape_a = 1.75, cape_b = 0.5, ratchet_threshold = 1.5,
                            ratchet_gap = 3, extra = 10, floor95 = 95,
                            min_real = 0, max_real = Inf, max_rate = 100) {
  .e3_choice(type, names(.wd_rules), "withdrawal_rule", "type")   # Pruefung (Meldung auswahl)
  type <- match.arg(type)
  # jede Zahl einzeln, endlich (bzw. Inf, wo erlaubt) und im zulaessigen Bereich; Meldungen ohne den Eingabewert
  # (seit 1.6.4, Entscheidung 8)
  chk <- function(x, arg, lo = -Inf, hi = Inf, what, inf_ok = FALSE, null_ok = FALSE) {
    if (is.null(x) && null_ok) return(invisible(NULL))
    if (!is.numeric(x) || length(x) != 1L || is.na(x) || (!inf_ok && !is.finite(x)) || x < lo || x > hi)
      stop(sprintf("withdrawal_rule: %s muss %s sein.", arg, what), call. = FALSE)
  }
  if (!is.numeric(rate) || length(rate) != 1L || !is.finite(rate) || rate < 0 || rate > 100)
    stop("withdrawal_rule: rate muss zwischen 0 und 100 Prozent liegen (z. B. 4).", call. = FALSE)
  if (rate > 0 && rate < 0.2 && type %in% c("constant", "percent", "vanguard", "guyton_klinger"))
    warning("rate wirkt wie eine Dezimalzahl. PROZENT-KONVENTION: 4 bedeutet 4 %.")
  chk(ceiling, "ceiling", 0, what = "NULL oder eine Zahl >= 0 in Prozent (z. B. 20)", null_ok = TRUE)
  chk(floor, "floor", 0, 100, what = "NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 20)", null_ok = TRUE)
  chk(cut, "cut", 0, 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
  chk(raise, "raise", 0, what = "eine Zahl >= 0 in Prozent (z. B. 10)")
  chk(cpr_years, "cpr_years", 0, what = "eine Zahl von Jahren >= 0 (z. B. 15)")
  chk_max(cpr_years, SL_MAX_JAHRE, "withdrawal_rule", "cpr_years")   # seit 1.6.4 (K43 T2-N2; Entscheidung 46 sinngemaess)
  chk(inflation_cap, "inflation_cap", 0, what = "eine Zahl >= 0 in Prozent oder Inf (unbegrenzt)", inf_ok = TRUE)
  if (!is.logical(skip_inflation) || length(skip_inflation) != 1L || is.na(skip_inflation))
    stop("withdrawal_rule: skip_inflation muss TRUE oder FALSE sein.", call. = FALSE)
  chk(smoothing, "smoothing", 0, 100, what = "NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 70)", null_ok = TRUE)
  chk(exp_return, "exp_return", -99.99, what = "NULL oder eine Zahl in Prozent p. a. \u00fcber -100 (z. B. 3.5)", null_ok = TRUE)
  chk(stock_share, "stock_share", 0, 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 60)")
  chk(age, "age", 0, what = "ein Alter in Jahren >= 0 (z. B. 65)")
  chk(max_age, "max_age", 0, what = "ein Alter in Jahren >= 0 (z. B. 100)")
  if (type == "vpw" && age >= max_age)
    chk_stop("ut2.vpw_alter", "withdrawal_rule('vpw')")
  chk(fv, "fv", 0, what = "ein Geldbetrag >= 0 (reales Zielverm\u00f6gen)")
  chk(cape_a, "cape_a", 0, 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 1.75)")
  chk(cape_b, "cape_b", 0, what = "eine Zahl >= 0 (Faktor auf 1 / CAPE, z. B. 0.5)")
  chk(ratchet_threshold, "ratchet_threshold", 0, what = "ein Faktor > 0 (z. B. 1.5 = 150 %)")
  chk(ratchet_gap, "ratchet_gap", 0, what = "eine Zahl von Jahren >= 0 (z. B. 3)")
  chk_max(ratchet_gap, SL_MAX_JAHRE, "withdrawal_rule", "ratchet_gap")   # seit 1.6.4 (K43 T2-N2)
  chk(extra, "extra", 0, 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
  chk(floor95, "floor95", 0, 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 95)")
  chk(min_real, "min_real", 0, what = "ein Geldbetrag >= 0")
  chk(max_real, "max_real", 0, what = "ein Geldbetrag >= 0 oder Inf", inf_ok = TRUE)
  if (min_real > max_real)
    stop("withdrawal_rule: min_real darf nicht gr\u00f6\u00dfer als max_real sein.", call. = FALSE)
  chk(max_rate, "max_rate", 0, 100, what = "eine Zahl von 0 bis 100 in Prozent (z. B. 100)")
  if (type == "vpw" && max_rate == 0)
    stop("withdrawal_rule('vpw'): max_rate = 0 erlaubt keine Entnahme; H\u00f6chstsatz in Prozent > 0 angeben (z. B. 100).", call. = FALSE)
  # Schranken in Prozent: Werte zwischen 0 und 0,2 sind vermutlich Anteile (0.05 statt 5)
  frac <- c(ceiling = ceiling %||% NA, floor = floor %||% NA, cut = cut, raise = raise, smoothing = smoothing %||% NA,
            inflation_cap = inflation_cap, extra = extra, floor95 = floor95, max_rate = max_rate)
  frac <- frac[!is.na(frac) & frac > 0 & frac < 0.2]
  if (length(frac))
    warning(sprintf("withdrawal_rule: %s wirkt wie ein Anteil; PROZENT-KONVENTION: 5 bedeutet 5 %% (gemeint vermutlich %s).",
                    paste(sprintf("%s = %s", names(frac), format(frac)), collapse = ", "),
                    paste(sprintf("%s = %s", names(frac), format(100 * frac)), collapse = ", ")), call. = FALSE)
  dflt <- switch(type,
    vanguard = list(ceiling = 5, floor = 2.5),
    guyton_klinger = list(ceiling = 20, floor = 20),
    floor_ceiling = list(ceiling = 20, floor = 15),
    list(ceiling = 0, floor = 0))
  ceiling <- ceiling %||% dflt$ceiling
  floor <- floor %||% dflt$floor
  smoothing <- smoothing %||% (if (type == "hebeler") 75 else 70)
  exp_return <- exp_return %||% (5.0 * stock_share / 100 + 1.9 * (1 - stock_share / 100))
  structure(list(type = type, rate = rate, ceiling = ceiling, floor = floor, cut = cut, raise = raise,
                 cpr_years = cpr_years, inflation_cap = inflation_cap, skip_inflation = skip_inflation,
                 smoothing = smoothing, exp_return = exp_return, age = age, max_age = max_age,
                 fv = fv, cape_a = cape_a, cape_b = cape_b,
                 ratchet_threshold = ratchet_threshold, ratchet_gap = ratchet_gap, extra = extra,
                 floor95 = floor95, min_real = min_real, max_real = max_real, max_rate = max_rate),
            class = c("withdrawal_rule", "list"))
}

#' @rdname SimLevWithdrawal-methods
#' @export
print.withdrawal_rule <- function(x, ...) {
  cat("Entnahmeregel\n-------------\n")
  cat(sprintf("  Typ:       %s (%s)\n", x$type, .wd_labels[[x$type]]))
  if (!x$type %in% c("one_over_n", "vpw", "abw", "cape", "hebeler")) cat(sprintf("  Rate:      %.2f %%\n", x$rate))
  extra <- switch(x$type,
    vanguard = sprintf("  Ceiling/Floor (real): +%.2f %% / -%.2f %%\n", x$ceiling, x$floor),
    guyton_klinger = sprintf("  Guardrails: +%.0f %% / -%.0f %%, K\u00fcrzung %.0f %%, Erh\u00f6hung %.0f %%, CPR bis %d J. vor Ende\n",
                             x$ceiling, x$floor, x$cut, x$raise, as.integer(x$cpr_years)),
    floor_ceiling = sprintf("  Korridor:  -%.0f %% / +%.0f %% um reale Erstentnahme\n", x$floor, x$ceiling),
    endowment = sprintf("  Gl\u00e4ttung:  %.0f %%\n", x$smoothing),
    hebeler = sprintf("  Gl\u00e4ttung:  %.0f %%, erwartete Realrendite %.2f %%\n", x$smoothing, x$exp_return),
    vpw = sprintf("  Alter %d bis %d, erwartete Realrendite %.2f %%\n", as.integer(x$age), as.integer(x$max_age), x$exp_return),
    abw = sprintf("  Erwartete Realrendite %.2f %%, Zielverm\u00f6gen %.0f\n", x$exp_return, x$fv),
    cape = sprintf("  Rate = %.2f %% + %.2f / CAPE\n", x$cape_a, x$cape_b),
    ratchet = sprintf("  +%.0f %% bei Depot > %.2f x Start, alle %d Jahre\n", x$raise, x$ratchet_threshold, as.integer(x$ratchet_gap)),
    sensible = sprintf("  Zusatz: %.0f %% des realen Vorjahresgewinns\n", x$extra),
    clyatt = sprintf("  Mindestens %.0f %% der Vorjahresentnahme\n", x$floor95), "")
  cat(extra)
  if (x$min_real > 0 || is.finite(x$max_real)) cat(sprintf("  Grenzen:   %.0f bis %s (real)\n", x$min_real, format(x$max_real)))
  invisible(x)
}

#' Parametervektor fuer den C++-Kern (Reihenfolge = enum P_* in core/withdrawal_core_impl.h)
#' @keywords internal
#' @noRd
.wd_param_vector <- function(rule) {
  r <- rule
  c(r$rate / 100, r$ceiling / 100, r$floor / 100, r$cut / 100, r$raise / 100, r$cpr_years,
    r$inflation_cap / 100, r$smoothing / 100, r$exp_return / 100,
    r$cape_a / 100, r$cape_b, r$ratchet_threshold, r$ratchet_gap, r$extra / 100,
    r$min_real, r$max_real, r$age, r$max_age, r$fv, r$floor95 / 100,
    as.numeric(isTRUE(r$skip_inflation)), r$max_rate / 100)
}

.wd_ppy <- function(frequency) switch(frequency, year = 1L, quarter = 4L, month = 12L,
                                      stop("frequency muss 'year', 'quarter' oder 'month' sein."))

#' Perioden-Kennzahl aus einer Tagesreihe ueber Kalendergrenzen
#' @keywords internal
#' @noRd
.period_ends <- function(dates, frequency) {
  key <- switch(frequency, year = format(dates, "%Y"),
                quarter = paste(format(dates, "%Y"), (as.integer(format(dates, "%m")) - 1L) %/% 3L),
                month = format(dates, "%Y-%m"))
  which(c(key[-1] != key[-length(key)], TRUE))
}


#' Historische Entnahme-Kohorten bilden
#'
#' Erzeugt rollierende Start-Kohorten (wie Bengen 1994 und die Trinity-Studie)
#' aus einer historischen Kursreihe: Fuer jeden Startmonat bzw. jedes Startjahr
#' entsteht ein Pfad ueber \code{years} Jahre. Eingabe ist ein data.frame mit
#' Spalte \code{date} und einer Kursspalte (Niveau, keine Renditen) oder ein
#' gespeichertes Ergebnis von [simulation()]. Die Reihe wird auf Monatsenden
#' verdichtet (letzter Wert je Kalendermonat, fehlende Werte fortgeschrieben);
#' die Monatsrenditen werden zur gewaehlten \code{frequency} aufmultipliziert.
#' Die Daten muessen jeden Kalendermonat zwischen erstem und letztem Datum
#' enthalten (Tages-, Wochen- oder Monatsdaten); sonst, etwa bei
#' Jahresdaten, bricht die Funktion ab.
#' Das Ergebnis geht direkt an [withdrawal_simulation()],
#' [withdrawal_max_rate()] oder [withdrawal_perfect_rate()].
#'
#' @param data data.frame mit Spalte \code{date} (Klasse Date oder
#'   umwandelbar) und der Kursspalte \code{price} (ggf. auch Spalten fuer
#'   \code{inflation}, \code{cape}, \code{base_rate}), oder ein
#'   \code{SimLevResult}: dann wird dessen zeitgewichteter Wertindex
#'   [result_index()] verwendet, \code{price} ignoriert, und nur \code{NULL}
#'   oder ein Prozentsatz fuer \code{inflation} ist erlaubt (keine
#'   \code{cape}- oder \code{base_rate}-Spalten).
#' @param price Name der Kursspalte des Portfolios (Total-Return-Niveau, nach
#'   Kosten), z. B. eine Backcast-Reihe. Standard \code{"value"}.
#' @param inflation \code{NULL} (Standard; keine Inflation), Zahl = konstante
#'   Inflation in Prozent p. a. (2 = 2 % p. a., tagesgenau ueber 365.25 Tage
#'   je Jahr umgerechnet) oder Zeichenkette = Name einer Preisindex-Spalte
#'   (CPI-Niveau, z. B. HVPI) bzw. einer Ratenspalte (siehe
#'   \code{inflation_type}).
#'   Eine Zahl muss endlich und > -100 sein. Genannte Spalten (auch \code{price}, \code{cape}, \code{base_rate}) muessen in \code{data} stehen und Zahlen enthalten (kein Text, kein Faktor; eine Spalte nur aus NA gilt als Zahlenspalte).
#' @param years Laenge jeder Kohorte in Jahren (Standard 30; intern
#'   12 x \code{years} Monate). Seit 1.6.4 eine ganze Zahl von 1 bis 100, auch bei
#'   \code{"quarter"} und \code{"month"} (vorher jede Zahl, die ganze
#'   Perioden ergab, z. B. 2.5).
#' @param frequency Periodenlaenge der Entnahme-Simulation: \code{"year"}
#'   (Standard), \code{"quarter"} oder \code{"month"}.
#' @param step Abstand der Kohortenstarts: \code{"month"} (Standard; jede
#'   Kohorte beginnt einen Monat spaeter) oder \code{"year"} (alle 12 Monate).
#' @param wrap Logisch (Standard \code{FALSE}). \code{TRUE}: Kohorten ueber das
#'   Datenende hinaus durch Fortsetzung am Datenanfang verlaengern (wie FI Calc,
#'   Option "loop"), so dass jeder Startzeitpunkt gemaess \code{step} eine
#'   Kohorte ergibt;
#'   \code{FALSE}: nur Kohorten, die vollstaendig in den Daten liegen.
#'   Nur \code{TRUE} oder \code{FALSE}.
#' @param cape Optional Name einer Spalte mit CAPE-Werten (fuer die Regel
#'   \code{"cape"} in [withdrawal_rule()]); verwendet wird der Wert zu Beginn
#'   jeder Periode.
#'   Seit 1.6.4 ohne NA: CAPE fuer jeden Tag angeben (vorher fortgeschrieben bzw. als fehlend gerechnet).
#' @param base_rate Optional Name einer Spalte mit dem Basiszins in Prozent
#'   (2.5 = 2,5 %) fuer die Vorabpauschale (Wert zu Beginn jeder Periode);
#'   sonst gilt \code{base_rate} aus [withdrawal_simulation()].
#'   Seit 1.6.4 ohne NA: Basiszins fuer jeden Tag angeben, Jahre ohne Basiszins als 0.
#' @param inflation_type Behandlung einer Spalte in \code{inflation}:
#'   \code{"level"} (Reihe ist ein Preisindex-Niveau; Inflation = Verhaeltnis
#'   der Monatsendwerte) oder \code{"rate_pa"} (Reihe ist eine Inflationsrate
#'   in Prozent pro Jahr, 2 = 2 % p. a., nicht je Datenperiode, kein Anteil;
#'   je Zeile ueber die Kalendertage seit der Vorzeile aufgezinst,
#'   \eqn{\prod (1 + r/100)^{Tage/365.25}}). Stammt \code{data} aus
#'   [bootstrap_data()] und ist die Spalte in [bootstrap_config()]
#'   ausdruecklich als \code{aux_type = "rate"} gekennzeichnet (Attribut
#'   \code{aux_type} des data.frames), ergibt sich \code{"rate_pa"} daraus;
#'   \code{inflation_type} kann dann entfallen und muss, wenn angegeben, dazu
#'   passen (sonst Fehler). Ohne Attribut gilt \code{inflation_type}
#'   (Standard \code{"level"}, bisheriges Verhalten). Das Attribut geht bei
#'   Umformungen wie \code{transform()}, \code{merge()}, \code{cbind()} oder
#'   Speichern als CSV verloren; dann \code{inflation_type = "rate_pa"}
#'   angeben. Bei Zahl oder \code{NULL} in \code{inflation} ohne Wirkung.
#' @return Objekt der Klasse \code{withdrawal_paths} (Liste) mit
#'   \code{returns} (Matrix Perioden x Kohorten der Brutto-Periodenrenditen),
#'   \code{inflation} (gleiche Form, Brutto-Inflation je Periode; ohne
#'   Inflation 1), \code{cape} und \code{base_rate} (Matrizen der Werte zu
#'   Periodenbeginn oder \code{NULL}), \code{frequency}, \code{start_dates}
#'   (Datum des Monatsendwerts, ab dem jede Kohorte laeuft), \code{historical =
#'   TRUE}, \code{wrap} und \code{source} (Name der Kursspalte).
#' @seealso [withdrawal_simulation()], [withdrawal_max_rate()],
#'   [result_index()], [withdrawal_paths()]
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("1990-01-01"), as.Date("2019-12-31"), by = "month"))
#' d$depot <- 100 * cumprod(exp(rnorm(nrow(d), 0.005, 0.04)))
#' coh <- withdrawal_cohorts(d, price = "depot", inflation = 2, years = 20, step = "year")
#' dim(coh$returns)          # 20 Jahre x 10 Kohorten
#' head(coh$start_dates)
#' ws <- withdrawal_simulation(coh, withdrawal_rule("constant", rate = 4))
#' summary(ws)$success_rate
#' @export
withdrawal_cohorts <- function(data, price = "value", inflation = NULL, years = 30,
                               frequency = c("year", "quarter", "month"),
                               step = c("month", "year"), wrap = FALSE,
                               cape = NULL, base_rate = NULL, inflation_type = c("level", "rate_pa")) {
  fn <- "withdrawal_cohorts"
  it_given <- !missing(inflation_type)
  .e3_choice(frequency, c("year", "quarter", "month"), fn, "frequency")   # Pruefung (Meldung auswahl)
  frequency <- match.arg(frequency)
  .e3_choice(step, c("month", "year"), fn, "step")   # Pruefung (Meldung auswahl)
  step <- match.arg(step)
  .e3_choice(inflation_type, c("level", "rate_pa"), fn, "inflation_type")   # Pruefung (Meldung auswahl)
  inflation_type <- match.arg(inflation_type)
  chk_bool1(wrap, fn, "wrap")
  if (inherits(data, "SimLevResult")) {
    if (is.character(inflation) || !is.null(cape) || !is.null(base_rate))
      chk_stop("rs.ergebnis_zusatz", fn)
    data <- result_index(data); price <- "value"
  }
  # Eingaben vor der Rechnung pruefen (seit 1.6.4): Tabelle, Namen, Inflation als Zahl > -100 oder Spaltenname,
  # genannte Spalten vorhanden und numerisch
  chk_df(data, fn, "data")
  for (a in c("price", "inflation", "cape", "base_rate")) chk_nofactor(get(a), fn, a)
  chk_name1(price, fn, "price")
  if (is.character(inflation)) chk_name1(inflation, fn, "inflation")
  else if (is.numeric(inflation)) chk_num1(inflation, fn, "inflation", lo = -100, lo_open = TRUE)
  else if (!is.null(inflation)) chk_stop("zahl_oder_spalte", fn, "inflation")
  chk_name1(cape, fn, "cape", null_ok = TRUE)
  chk_name1(base_rate, fn, "base_rate", null_ok = TRUE)
  if (!all(c("date", price) %in% names(data))) chk_stop("rs.date_kurs", fn)
  xcols <- c(if (is.character(inflation)) inflation, cape, base_rate)
  chk_cols(data, xcols, fn)
  .e3_datecol(data, fn)
  for (k in c(price, xcols)) .e3_numcol(data, k, fn)
  # seit 1.6.4 CAPE und Basiszins ohne NA (Entscheidung 17; bis 1.6.3 fortgeschrieben bzw. als 0 bzw. "nur cape_a")
  if (!is.null(cape)) chk_col_nona(data, cape, fn, chk_msg("hinweis.cape"))
  if (!is.null(base_rate)) chk_col_nona(data, base_rate, fn, chk_msg("hinweis.basiszins"))
  # Art der Inflationsspalte: Attribut aus bootstrap_data() (aux_type "rate"), sonst inflation_type;
  # ein ausdrueckliches inflation_type muss zum Attribut passen
  attr_rate <- is.character(inflation) && identical(unname((attr(data, "aux_type") %||% character(0))[inflation]), "rate")
  if (attr_rate && it_given && inflation_type != "rate_pa")
    stop(sprintf(paste0("inflation_type passt nicht zu aux_type['%s'] = 'rate' (Attribut aus bootstrap_data()); ",
                        "inflation_type weglassen oder 'rate_pa' angeben."), inflation))
  infl_rate <- is.character(inflation) && (attr_rate || inflation_type == "rate_pa")
  data$date <- .to_date(data$date, "withdrawal_cohorts: data$date")
  if (anyNA(data$date)) chk_stop("spalte_na", fn, "date", "")   # seit 1.6.4 (bisher R-Rohfehler)
  data <- data[order(data$date), , drop = FALSE]
  dates <- data$date
  px <- .fill_na(as.numeric(data[[price]]), "locf")
  ends <- .period_ends(dates, "month")                     # Monatsraster als Basis
  mdates <- dates[ends]; mpx <- px[ends]
  mi <- as.integer(format(mdates, "%Y")) * 12L + as.integer(format(mdates, "%m"))
  gap <- which(diff(mi) != 1L)
  if (length(gap))
    stop(sprintf(paste0("withdrawal_cohorts braucht l\u00fcckenlose Monatsdaten (mindestens ein Datum je Kalendermonat), ",
                        "aber nach %s folgt %s%s."), format(mdates[gap[1]]), format(mdates[gap[1] + 1L]),
                 if (stats::median(diff(mi)) >= 12) paste0(" (Jahresdaten? Dann Jahresrenditen als Matrix Jahre x Kohorten ",
                                                           "an withdrawal_simulation() \u00fcbergeben)") else ""))
  cpi <- if (is.null(inflation)) rep(1, length(ends))
         else if (infl_rate) {                             # Rate in Prozent p. a. ueber die Kalendertage
           v <- .fill_na(as.numeric(data[[inflation]]), "locf")
           lv <- cumprod(c(1, (1 + v[-1] / 100)^(as.numeric(diff(dates)) / 365.25)))[ends]
           f <- lv[-1] / lv[-length(lv)]
           if (any(!is.finite(f) | f <= 0))
             chk_stop("rs.rate_monat", fn, inflation)
           lv
         }
         else if (is.character(inflation)) .fill_na(as.numeric(data[[inflation]]), "locf")[ends]
         else (1 + inflation / 100)^(as.numeric(mdates - mdates[1]) / 365.25)
  capev <- if (!is.null(cape)) .fill_na(as.numeric(data[[cape]]), "locf")[ends] else NULL
  brv <- if (!is.null(base_rate)) .fill_na(as.numeric(data[[base_rate]]), "locf")[ends] else NULL
  mret <- mpx[-1] / mpx[-length(mpx)]; minf <- cpi[-1] / cpi[-length(cpi)]
  nm <- length(mret)
  ppy <- .wd_ppy(frequency); mpp <- 12L / ppy
  # seit 1.6.4 ganze Jahre von 1 bis 100, auch bei frequency "quarter"/"month" (Entscheidungen 46 und 47; bis 1.6.3
  # jede Zahl > 0, die ganze Perioden ergab, z. B. 2.5 bei Monaten)
  chk_jahre(years, fn, "years")
  len_m <- as.integer(round(years * 12))
  # seit 1.6.4 (K43 T2-N4) ohne volle Monatsrendite auch bei step = "year" die Meldung unten (bis dahin R-Rohfehler
  # "wrong sign in 'by' argument" von seq)
  starts <- if (step == "month") seq_len(nm) else if (nm >= 1L) seq(1L, nm, by = 12L) else integer(0)
  if (!wrap) starts <- starts[starts + len_m - 1L <= nm]
  if (!length(starts)) chk_stop("rs.kohorte_kurz", fn)
  take <- function(v, s) v[((s - 1L + seq_len(len_m) - 1L) %% nm) + 1L]
  agg <- function(m) {                                     # Monate -> Perioden (Produkt)
    if (mpp == 1L) return(m)
    .wd_annual_prod(m, mpp)   # seit 1.6.3 im Kern (sl_r_prod wie prod(): long double, Abschneiden); Form: matrix() unten
  }
  R <- agg(vapply(starts, function(s) take(mret, s), numeric(len_m)))
  I <- agg(vapply(starts, function(s) take(minf, s), numeric(len_m)))
  pick_start <- function(v) if (is.null(v)) NULL else {
    m <- vapply(starts, function(s) take(v[-length(v)], s), numeric(len_m))
    m[seq(1L, len_m, by = mpp), , drop = FALSE]            # Wert zu Periodenbeginn
  }
  structure(list(returns = matrix(R, ncol = length(starts)), inflation = matrix(I, ncol = length(starts)),
                 cape = pick_start(capev), base_rate = pick_start(brv),
                 frequency = frequency, start_dates = mdates[starts], historical = TRUE, wrap = wrap,
                 source = price), class = "withdrawal_paths")
}

#' Zeitgewichteter Wertindex eines Simulationsergebnisses
#'
#' Bildet aus einem \code{SimLevResult} den um Ein- und Auszahlungen bereinigten
#' Wertindex (Basis der TTWROR). Damit laesst sich jedes gespeicherte
#' Ergebnis von [simulation()] als Renditequelle fuer
#' [withdrawal_simulation()] verwenden. Verwendet wird der von
#' [simulation()] gespeicherte Index \code{twr_index}: an Tagen ohne
#' Zahlung \eqn{I_t = I_{t-1} W_t / W_{t-1}}; an Tagen mit Zahlung wird der
#' Vortagesbestand zum Schlusskurs vor der Zahlung bewertet (siehe
#' [simulation()], Abschnitt Kennzahlen), sodass die Zahlung die Rendite
#' nicht verzerrt. \eqn{W_t} ist der Depotwert. Fuer aeltere Ergebnisse
#' ohne \code{twr_index} gilt \eqn{I_t = I_{t-1} (W_t - F_t) / W_{t-1}}
#' mit \eqn{F_t} = Summe der Ein- und Auszahlungen aller Assets am Tag
#' \eqn{t}; nicht endliche Tagesfaktoren (z. B. bei Depotwert 0) werden
#' dabei als 1 gesetzt.
#'
#' @param x Objekt der Klasse \code{SimLevResult} (Ergebnis von
#'   [simulation()]).
#' @param base Startwert des Index (einzelne endliche Zahl > 0, Standard 100).
#' @return data.frame mit einer Zeile je Simulationstag und den Spalten
#'   \code{date} (Date), \code{value} (Index, beginnt bei \code{base}),
#'   \code{worth} (Depotwert) und \code{flows} (Summe der Ein-/Auszahlungen
#'   je Tag, Geldbetrag).
#' @seealso [withdrawal_cohorts()], [withdrawal_paths()],
#'   [withdrawal_simulation()]
#' @examples
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400),
#'                 ETF = 100 * cumprod(1 + rnorm(400, 3e-4, 0.01)))
#' res <- simulation(d, create_strategy(ETF = asset_config("etf", "bnh")), dca = dca_plan(value = 100, span = 1))
#' head(result_index(res))
#' @export
result_index <- function(x, base = 100) {
  if (!inherits(x, "SimLevResult")) chk_stop("klasse", "result_index", "x", "simulation()")
  chk_num1(base, "result_index", "base", lo = 0, lo_open = TRUE)   # Startwert des Index (seit 1.6.4 geprueft)
  w <- as.numeric(x$worth)
  fl <- vapply(x$report, function(a) as.numeric(a$flows), numeric(length(w)))
  fl <- if (is.matrix(fl)) rowSums(fl) else as.numeric(fl)
  if (length(x$twr_index) == length(w)) {
    idx <- as.numeric(x$twr_index)              # zeitgewichteter Index der Engine (bitgleich zu ttwror)
  } else {
    # aeltere Ergebnisse ohne twr_index: Zahlung zum Tagesende (ohne Kaufkosten exakt)
    g <- c(1, (w[-1] - fl[-1]) / w[-length(w)])
    g[!is.finite(g)] <- 1
    idx <- cumprod(g)
  }
  data.frame(date = as.Date(x$dates), value = base * idx, worth = w, flows = fl)
}

#' Periodenenden als Jahrestage ab Startdatum
#' @keywords internal
#' @noRd
.anniv_ends <- function(dates, frequency) {
  # Jahres-, Quartals- bzw. Monatstage ab dem Startdatum, je vom Start aus gezaehlt und auf das Monatsende
  # begrenzt (Start 31.01.: 29.02., 31.03., 30.04.; Start 29.02.: 28.02. des Folgejahres)
  step <- switch(frequency, year = 12L, quarter = 3L, month = 1L)
  d0 <- as.Date(dates[1]); d1 <- as.Date(dates[length(dates)])
  lt0 <- as.POSIXlt(d0); lt1 <- as.POSIXlt(d1)
  nm <- (lt1$year - lt0$year) * 12L + lt1$mon - lt0$mon
  tg <- .add_months(d0, seq(0L, nm %/% step * step, by = step))
  tg <- tg[tg <= d1]
  unique(findInterval(as.numeric(tg), as.numeric(dates)))
}

#' Pfade in Perioden-Renditen fuer Entnahmen umwandeln
#'
#' Wandelt fertige Simulationen in die Periodenmatrizen von
#' [withdrawal_simulation()] um, damit sich eine Entnahmephase auf bereits
#' gerechnete Pfade setzen laesst. Perioden beginnen am Startdatum der Pfade
#' und enden an den Jahrestagen (bzw. Quartals- oder Monatstagen) danach,
#' je vom Startdatum gezaehlt und auf das Monatsende begrenzt (Start 31.01.:
#' 29.02., 31.03., 30.04. ...); eine unvollstaendige letzte Periode entfaellt.
#'
#' Akzeptierte Eingaben \code{x}:
#' \describe{
#'   \item{\code{SimLevBootstrapStudy}}{Ergebnis von [bootstrap_study()], das
#'     mit \code{keep_returns = "year"}, \code{"quarter"} oder \code{"month"}
#'     gerechnet wurde. Verwendet die gespeicherten zeitgewichteten
#'     Periodenrenditen der Strategie \code{strategy} und deren Frequenz
#'     (\code{frequency} wird ignoriert); Pfade mit fehlenden Werten entfallen;
#'     die Pfadgewichte der Studie werden uebernommen.}
#'   \item{Liste von \code{SimLevResult}}{z. B. gespeicherte Laeufe von
#'     [simulation()] auf Bootstrap-Pfaden; je Element ein Pfad ueber dessen
#'     zeitgewichteten Wertindex ([result_index()]). Alle Ergebnisse muessen
#'     gleich viele Tage haben; der Kalender des ersten Ergebnisses gilt.}
#'   \item{\code{bootstrap_result}}{Ergebnis von [bootstrap()]; \code{column}
#'     waehlt die Kursspalte der Pfade, die Pfadgewichte werden uebernommen.}
#' }
#' Ein einzelnes \code{SimLevResult} wird hier nicht angenommen (dafuer
#' [withdrawal_cohorts()]). Bereits fertige \code{withdrawal_paths} (aus
#' [withdrawal_cohorts()] oder [bootstrap_pooled()]) und Renditematrizen
#' werden direkt an [withdrawal_simulation()] uebergeben;
#' \code{withdrawal_simulation()} ruft diese Funktion fuer Studien und
#' Ergebnislisten auch selbst auf.
#'
#' @param x \code{SimLevBootstrapStudy}, Liste von \code{SimLevResult} oder
#'   \code{bootstrap_result} (siehe oben).
#' @param column Nur bei \code{bootstrap_result} (dort Pflicht): Name der
#'   Kursspalte im Pfad (Index oder Hebelprodukt).
#' @param strategy Nur bei \code{SimLevBootstrapStudy}: Strategiename.
#'   \code{NULL} (Standard) = erste gespeicherte Strategie.
#' @param inflation \code{NULL} (Standard; keine Inflation, Faktor 1), Zahl =
#'   konstante Inflation in Prozent p. a. (2 = 2 % p. a., ueber die
#'   Kalendertage der Perioden umgerechnet) oder Zeichenkette = Name einer
#'   Zusatzreihe: bei \code{bootstrap_result} eine Spalte der Pfade (aus
#'   \code{aux} in [bootstrap_config()]; Behandlung nach \code{aux_type} bzw.
#'   \code{inflation_type}), bei Studien eine mit \code{keep_aux}
#'   gespeicherte Reihe (deren gespeicherte Periodenfaktoren werden direkt
#'   als Brutto-Inflation verwendet; nicht endliche Faktoren oder Werte <= 0
#'   sind ein Fehler). Eine Reihe mit \code{aux_type = "rate"} gilt dabei
#'   immer als Inflationsrate in Prozent pro Jahr (2 = 2 % p. a.; nicht je
#'   Datenperiode, kein Anteil), je Pfadzeile ueber die Kalendertage
#'   aufgezinst, \eqn{\prod (1 + r/100)^{Tage/365.25}}. Bei Ergebnislisten
#'   nur \code{NULL} oder eine Zahl.
#' @param inflation_type Behandlung einer Zusatzreihe in \code{inflation}:
#'   \code{"level"} (Reihe ist ein Preisindex-Niveau; Inflation = Verhaeltnis
#'   des kumulierten Niveaus an den Periodenenden, d. h. die historischen
#'   Zeilenverhaeltnisse der gezogenen Zeilen) oder \code{"rate_pa"} (Reihe
#'   ist eine Inflationsrate in Prozent pro Jahr, 2 = 2 % p. a., nicht je
#'   Datenperiode, kein Anteil; je Pfadzeile ueber die Kalendertage
#'   aufgezinst, \eqn{\prod (1 + r/100)^{Tage/365.25}}). Ist die Art der
#'   Reihe in [bootstrap_config()] mit \code{aux_type} ausdruecklich
#'   angegeben, ergibt sich die Behandlung daraus (\code{"level"} bzw.
#'   \code{"rate"} -> \code{"rate_pa"}); \code{inflation_type} kann dann
#'   entfallen und muss, wenn angegeben, dazu passen (sonst Fehler). Ohne
#'   Angabe in \code{aux_type} gilt das bisherige Verhalten: bei
#'   \code{bootstrap_result} entscheidet \code{inflation_type} (Standard
#'   \code{"level"}; verwendet wird die Niveau-Variante im Pfad, Attribut
#'   \code{aux_level} aus [bootstrap()]); bei Studien werden die mit
#'   \code{keep_aux} gespeicherten Faktoren (Niveau-Variante) unveraendert
#'   verwendet, ein ausdrueckliches \code{inflation_type = "rate_pa"} ist dort
#'   ein Fehler (die Rate laesst sich aus den gespeicherten Faktoren nicht
#'   gewinnen; \code{aux_type = c(<Name> = "rate")} angeben und die Studie
#'   neu rechnen).
#' @param frequency Periodenlaenge: \code{"year"} (Standard), \code{"quarter"}
#'   oder \code{"month"}. Bei Studien gilt stattdessen die gespeicherte
#'   Frequenz.
#' @param dates,start Nur bei \code{bootstrap_result}: Kalender der
#'   Pfadzeilen. \code{dates} = Date-Vektor (oder in Date umwandelbar) mit
#'   genau einem Datum je Pfadzeile, streng aufsteigend;
#'   \code{NULL} (Standard) = taegliche Kalenderdaten ab \code{start}
#'   (Standard \code{"2000-01-01"}), d. h. jede Pfadzeile zaehlt als ein
#'   Kalendertag. Fuer Pfade aus Handelstagen passende \code{dates} angeben
#'   (siehe [bootstrap_data()]).
#'   \code{start} ist ein einzelnes Datum (Date oder Text \code{"JJJJ-MM-TT"}, keine Zahl).
#' @param cape Nur bei \code{bootstrap_result}: optional Name einer im Pfad vorhandenen
#'   Pfadspalte mit CAPE-Werten (Wert zu Periodenbeginn) fuer die Regel
#'   \code{"cape"}.
#' @return Objekt der Klasse \code{withdrawal_paths} (Liste) mit
#'   \code{returns} (Matrix Perioden x Pfade der Brutto-Periodenrenditen),
#'   \code{inflation} (gleiche Form, Brutto-Inflation je Periode),
#'   \code{cape} (Matrix oder \code{NULL}), \code{base_rate = NULL},
#'   \code{frequency}, \code{start_dates = NULL}, \code{historical = FALSE},
#'   \code{weights} (Pfadgewichte oder \code{NULL}) und \code{source}
#'   (Spaltenname, \code{"study:"} mit angehaengtem Strategienamen oder
#'   \code{"results"}).
#' @seealso [withdrawal_simulation()], [bootstrap()], [bootstrap_study()],
#'   [withdrawal_cohorts()]
#' @examples
#' set.seed(2)
#' d <- data.frame(us = 1 + rnorm(1500, 3e-4, 0.01), infl = 2)
#' cfg <- bootstrap_config(c(us = "us"), aux = c(infl = "infl"))
#' b <- bootstrap(d, cfg, "stationary", n = 20, params = list(L = 50),
#'                path_length = 3653, seed = 1, progress = FALSE)
#' wp <- withdrawal_paths(b, column = "us", inflation = "infl", inflation_type = "rate_pa")
#' dim(wp$returns)           # 10 Jahre x 20 Pfade
#' range(wp$inflation)       # etwa 1.02 = 2 % p. a.
#' # Art der Reihen in der Konfiguration angeben: CPI als Niveau, Zins als Rate
#' d$cpi <- 100 * 1.02^((1:1500) / 365.25); d$zins <- 3
#' cfg2 <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi", zins = "zins"),
#'   aux_type = c(cpi = "level", zins = "rate"))
#' b2 <- bootstrap(d, cfg2, "stationary", n = 20, params = list(L = 50),
#'                 path_length = 3653, seed = 1, progress = FALSE)
#' range(withdrawal_paths(b2, column = "us", inflation = "cpi")$inflation)   # ohne inflation_type
#' ws <- withdrawal_simulation(wp, withdrawal_rule("percent", rate = 4))
#' head(ws$paths[, 1:4])
#' @export
withdrawal_paths <- function(x, column = NULL, strategy = NULL, inflation = NULL,
                             inflation_type = c("level", "rate_pa"),
                             frequency = c("year", "quarter", "month"), dates = NULL,
                             start = "2000-01-01", cape = NULL) {
  fn <- "withdrawal_paths"
  it_given <- !missing(inflation_type)
  .e3_choice(frequency, c("year", "quarter", "month"), fn, "frequency")   # Pruefung (Meldung auswahl)
  frequency <- match.arg(frequency)
  .e3_choice(inflation_type, c("level", "rate_pa"), fn, "inflation_type")   # Pruefung (Meldung auswahl)
  inflation_type <- match.arg(inflation_type)
  # Eingaben vor der Rechnung pruefen (seit 1.6.4): Namen, Startdatum (Date oder "JJJJ-MM-TT")
  for (a in c("column", "strategy", "cape", "inflation", "start", "dates")) chk_nofactor(get(a), fn, a)   # Entscheidung 15
  chk_name1(column, fn, "column", null_ok = TRUE)
  chk_name1(strategy, fn, "strategy", null_ok = TRUE)
  chk_name1(cape, fn, "cape", null_ok = TRUE)
  start <- chk_date1(start, fn, "start")
  # Art der Zusatzreihe aus bootstrap_config(aux_type = ...): bestimmt die Behandlung als Inflation;
  # ein ausdrueckliches inflation_type muss dazu passen
  aux_kind <- function(cfg) {
    if (!is.character(inflation) || !inflation %in% (cfg$aux_type_set %||% character(0))) return(NULL)
    k <- cfg$aux_type[[inflation]]; it <- if (k == "level") "level" else "rate_pa"
    if (it_given && inflation_type != it)
      chk_stop("rs.infl_typ", fn, inflation, k, it)
    k
  }
  if (!is.null(inflation) && (length(inflation) != 1L || !((is.character(inflation) && !is.na(inflation) && nzchar(inflation)) ||
                                                           (is.numeric(inflation) && is.finite(inflation)))))
    chk_stop("ut2.inflation_pfade", "withdrawal_paths")
  if (is.numeric(inflation)) chk_num1(inflation, fn, "inflation", lo = -100, lo_open = TRUE)
  infl_from <- function(n_per, n_paths, ends_dates) {
    if (is.null(inflation)) return(matrix(1, n_per, n_paths))
    if (!is.numeric(inflation)) return(NULL)
    matrix((1 + inflation / 100)^(as.numeric(diff(ends_dates)) / 365.25), n_per, n_paths)
  }
  # vapply(..., numeric(L)) als Matrix L x Pfade; bei L = 1 liefert vapply einen Vektor, den as.matrix bis 1.6.3 zu
  # einer Spalte machte (Pfade und Perioden vertauscht, A-002); seit 1.6.4 eine Zeile mit den Namen als Spaltennamen
  vmat <- function(v, L) if (is.matrix(v)) v else matrix(v, nrow = L, dimnames = list(NULL, names(v)))
  mk <- function(R, I, C, w, src) structure(list(returns = as.matrix(R), inflation = as.matrix(I),
    cape = if (!is.null(C)) as.matrix(C) else NULL, base_rate = NULL, frequency = frequency,
    start_dates = NULL, historical = FALSE, weights = w, source = src), class = "withdrawal_paths")

  # 1) Gespeicherte Bootstrap-Studie
  if (inherits(x, "SimLevBootstrapStudy")) {
    if (is.null(x$returns)) chk_stop("rs.studie_renditen", fn)
    strategy <- strategy %||% names(x$returns)[1]
    if (!strategy %in% names(x$returns)) chk_stop("rs.strategie", fn, strategy, paste(names(x$returns), collapse = ", "))
    frequency <- x$returns_frequency
    R <- x$returns[[strategy]]
    ok <- colSums(is.na(R)) == 0
    I <- if (is.character(inflation)) {
      if (is.null(x$aux_returns[[inflation]])) chk_stop("rs.aux_gespeichert", fn, inflation)
      kind <- aux_kind(x$config)
      # ohne aux_type sind die gespeicherten Faktoren die Niveau-Variante; eine Rate p. a. laesst sich daraus nicht gewinnen
      if (is.null(kind) && it_given && inflation_type == "rate_pa")
        stop(sprintf(paste0("inflation_type = 'rate_pa': die mit keep_aux gespeicherten Faktoren der Zusatzreihe '%s' sind die Niveau-Variante ",
                            "(Reihe nicht in aux_type genannt). F\u00fcr eine Rate in Prozent p. a. aux_type = c(%s = 'rate') in bootstrap_config() ",
                            "angeben und die Studie neu rechnen."), inflation, inflation))
      I0 <- x$aux_returns[[inflation]]; r <- I0[, ok, drop = FALSE]
      if (any(!is.finite(r) | r <= 0))
        stop(sprintf(if (identical(kind, "rate")) "Zusatzreihe '%s' (aux_type 'rate') ergibt nicht endliche oder nicht positive Periodenfaktoren."
                     else "Zusatzreihe '%s' ist kein positives Niveau (gespeicherte Periodenverh\u00e4ltnisse nicht endlich oder <= 0); f\u00fcr eine Rate in Prozent p. a. aux_type = c(<Name> = 'rate') in bootstrap_config() angeben.",
                     inflation))
      I0
    } else infl_from(nrow(R), ncol(R), x$returns_dates)
    w <- x$path_weights
    return(mk(R[, ok, drop = FALSE], I[, ok, drop = FALSE], NULL, w[ok], paste0("study:", strategy)))
  }
  # 2) Liste von simulation()-Ergebnissen
  if (is.list(x) && !inherits(x, "bootstrap_result") && length(x) && all(vapply(x, inherits, TRUE, "SimLevResult"))) {
    if (is.character(inflation)) chk_stop("rs.liste_infl", fn)
    idx <- lapply(x, result_index)
    ends <- .anniv_ends(idx[[1]]$date, frequency)
    if (length(ends) < 2) chk_stop("rs.ergebnisse_kurz", fn)
    R <- vapply(idx, function(d) {
      if (nrow(d) != nrow(idx[[1]])) chk_stop("rs.ergebnisse_laenge", fn)
      v <- d$value[ends]; v[-1] / v[-length(v)] }, numeric(length(ends) - 1L))
    R <- vmat(R, length(ends) - 1L)
    return(mk(R, infl_from(nrow(R), ncol(R), idx[[1]]$date[ends]), NULL, NULL, "results"))
  }
  # 3) bootstrap()-Pfade
  if (!inherits(x, "bootstrap_result")) chk_stop("ut2.pfade_x", "withdrawal_paths")
  if (is.null(column)) chk_stop("ut2.pfade_column", "withdrawal_paths")
  P1 <- x$paths[[1]]
  if (!column %in% colnames(P1)) chk_stop("rs.spalte_pfad", fn, column, paste(colnames(P1), collapse = ", "))
  if (!is.null(cape) && !cape %in% colnames(P1)) chk_stop("e3.pfadspalte", fn, cape, "cape", paste(colnames(P1), collapse = ", "))
  if (is.null(dates)) dates <- seq.Date(start, by = "day", length.out = nrow(P1))
  else {
    dates <- .to_date(dates, "dates")
    if (length(dates) != nrow(P1))
      chk_stop("rs.dates_pfade", fn, length(dates), nrow(P1))
    if (anyNA(dates) || is.unsorted(dates, strictly = TRUE)) chk_stop("ut2.dates_streng", "withdrawal_paths")
  }
  ends <- .anniv_ends(dates, frequency)
  if (length(ends) < 2) chk_stop("rs.pfade_kurz", fn)
  per <- function(v) v[ends[-1]] / v[ends[-length(ends)]]
  R <- vmat(vapply(x$paths, function(P) per(P[, column]), numeric(length(ends) - 1L)), length(ends) - 1L)
  I <- infl_from(nrow(R), ncol(R), dates[ends])
  if (is.null(I)) {
    if (!inflation %in% colnames(P1)) chk_stop("rs.aux_pfad", fn, inflation, paste(colnames(P1), collapse = ", "))
    kind <- aux_kind(x$config)
    if (!is.null(kind)) inflation_type <- if (kind == "level") "level" else "rate_pa"
    I <- vmat(vapply(x$paths, function(P) {
      if (inflation_type == "rate_pa") {
        v <- P[, inflation]
        r <- per(cumprod(c(1, (1 + v[-1] / 100)^(as.numeric(diff(dates)) / 365.25))))
        if (any(!is.finite(r) | r <= 0))
          chk_stop("rs.rate_periode", fn, inflation)
        return(r)
      }
      # Niveau: kumulierte Zeilenverhaeltnisse der gezogenen Zeilen (Originalwerte springen an Blockgrenzen);
      # bei aux_type "level" steht dieses Niveau bereits in der Pfadspalte
      lv <- attr(P, "aux_level")
      v <- if (identical(kind, "level")) P[, inflation]
           else if (!is.null(lv) && inflation %in% colnames(lv)) lv[, inflation]
           else if (x$method %in% c("wild", "reset")) P[, inflation]
           else stop(sprintf(paste0("inflation_type = 'level': Pfad ohne Niveau-Variante der Reihe '%s' (Attribut aux_level); ",
                                    "beim Verfahren '%s' springen die Originalwerte an Blockgrenzen. Pfade mit bootstrap() neu erzeugen."),
                             inflation, x$method))
      r <- per(v)
      if (any(!is.finite(r) | r <= 0))
        chk_stop("rs.niveau", fn, inflation)
      r
    }, numeric(length(ends) - 1L)), length(ends) - 1L)
  }
  C <- if (!is.null(cape)) vmat(vapply(x$paths, function(P) P[ends[-length(ends)], cape], numeric(length(ends) - 1L)),
                                length(ends) - 1L) else NULL
  mk(R, I, C, x$weights, column)
}

#' Perfect Withdrawal Rate (PWR)
#'
#' Exakte konstante reale Entnahmerate, die ein Depot bei gegebener Renditefolge
#' genau aufbraucht bzw. das Zielvermoegen hinterlaesst (Suarez, Suarez & Walz
#' 2015; Entnahme jeweils zu Jahresbeginn):
#' \deqn{PWR = (R_n - K_E/K_S) \cdot S_n, \quad R_n = \prod (1+r_i), \quad
#'       S_n = 1 / \sum_{i=1}^{n} \prod_{j=i}^{n} (1 + r_j)}
#'
#' Die PWR haengt nur von der realen Renditefolge ab (keine Steuern,
#' Verkaufskosten oder weiteren Einkommen).
#'
#' @param real_returns Numerische Matrix (Jahre x Pfade) realer
#'   Brutto-Jahresrenditen (z. B. 1.05 = +5 % real; ein Vektor gilt als ein
#'   Pfad) oder ein \code{withdrawal_paths}-Objekt: dann werden
#'   \code{returns / inflation} je Periode zu Jahren aufmultipliziert (ein
#'   unvollstaendiges letztes Jahr entfaellt).
#' @param legacy Reales Zielvermoegen am Ende als Anteil des Startvermoegens
#'   (\eqn{K_E / K_S}; 0 = aufbrauchen (Standard), 0.5 = 50 % erhalten; >= 0).
#'   Renditen muessen Brutto-Renditen sein (1.05, nicht 0.05); eine Matrix
#'   mit Median unter 0.5, negativen oder nicht endlichen Werten ist ein
#'   Fehler.
#' @return Numerischer Vektor der PWR je Pfad in Prozent des Startvermoegens
#'   (4 = 4 % je Jahr).
#' @seealso [withdrawal_simulation()] (Spalte \code{pwr} in \code{paths}),
#'   [withdrawal_max_rate()], [withdrawal_cohorts()]
#' @examples
#' set.seed(1)
#' R <- matrix(exp(rnorm(30 * 5, 0.03, 0.12)), 30)   # 30 Jahre, 5 Pfade, real
#' withdrawal_perfect_rate(R)
#' withdrawal_perfect_rate(R, legacy = 0.5)
#' @export
withdrawal_perfect_rate <- function(real_returns, legacy = 0) {
  if (inherits(real_returns, "withdrawal_paths")) real_returns <- .annual_real(real_returns)
  R <- as.matrix(real_returns)
  msg_a <- "withdrawal_perfect_rate: real_returns muss eine Matrix endlicher realer Brutto-Jahresrenditen sein (1.05 = +5 %)."
  # Feld mit mehr als zwei Dimensionen: seit 1.6.4 abgelehnt (bisher von as.matrix still zu einer Spalte gemacht)
  if (!is.numeric(R) || !length(R) || length(dim(real_returns)) > 2L) stop(msg_a)
  lg_ok <- is.numeric(legacy) && length(legacy) == 1L && is.finite(legacy) && legacy >= 0
  # Pruefungen (nicht endlich, Median, negativ) und PWR je Spalte im Kern (core/withdrawal_core_impl.h, wd_pwr)
  core <- .wd_pwr(R, if (lg_ok) legacy else 0)
  if (core$status == 1L) stop(msg_a)
  if (core$status == 2L)
    stop(sprintf(paste0("withdrawal_perfect_rate: real_returns sieht nicht wie Brutto-Renditen aus (Median %s); erwartet z. B. 1.05 ",
                        "f\u00fcr +5 %%, nicht 0.05 (Nettorendite: 1 + r \u00fcbergeben)."), format(stats::median(R), digits = 4)))
  if (core$status == 3L) stop("withdrawal_perfect_rate: Brutto-Renditen in real_returns m\u00fcssen >= 0 sein (0 = Totalverlust).")
  if (!lg_ok)
    stop("withdrawal_perfect_rate: legacy muss ein Anteil >= 0 sein (0.5 = 50 % des Startverm\u00f6gens).")
  stats::setNames(core$pwr, colnames(R))                  # wie apply(R, 2, ...): Namen der Spalten
}

#' Reale Jahresrenditen aus Perioden-Matrizen
#' @keywords internal
#' @noRd
.annual_real <- function(wp) {
  ppy <- .wd_ppy(wp$frequency)
  real <- wp$returns / wp$inflation
  if (ppy == 1L) return(real)
  np <- nrow(real); ny <- np %/% ppy
  if (!is.matrix(real) || ny < 1L || !ncol(real))
    return(apply(real[seq_len(ny * ppy), , drop = FALSE], 2, function(col) apply(matrix(col, nrow = ppy), 2, prod)))
  # Produkt je Jahr im Kern (wd_annual_prod); immer eine Matrix Jahre x Pfade mit den Spaltennamen (seit 1.6.4, A-003:
  # bis 1.6.3 bei einem Jahr ein Vektor wie apply(), den withdrawal_perfect_rate() als einen Pfad las)
  A <- .wd_annual_prod(real, ppy)
  dn <- dimnames(real)[2L]
  if (!is.null(names(dn)) || !is.null(dn[[1L]])) dimnames(A) <- c(list(NULL), dn)
  A
}


#' Offene Lots der Ansparphase als FIFO-Bestand fuer den Entnahme-Kern
#'
#' Einheit = Depotanteil im Wert von 1 EUR am Start (Summe = Startwert
#' \code{sv}). Je Asset (Gruppe, FIFO-Reihenfolge wie in \code{open_lots})
#' erhaelt Lot i den Anteil units_i / Summe units am Endwert des Assets
#' (\code{report$<asset>$worth}), Anschaffungskosten units_i x price_i und
#' die anzurechnende Vorabpauschale vp_i. Der Rest Startwert minus
#' Assetwerte (Cash) bildet eine eigene Gruppe mit Basis = Betrag; ein negativer
#' Rest (seit 1.6.4) mindert stattdessen den aeltesten Lot des wertgroessten Assets. Assets
#' mit Endwert <= \code{tol} x \code{sv} (z. B. Fliesskommarest von Stueck
#' nach Rebalancing auf Gewicht 0) und ein Cash-Rest mit |Betrag| <=
#' \code{tol} x \code{sv} entfallen (siehe [.wd_held()]).
#' @keywords internal
#' @noRd
.wd_lots <- function(ol, report, sv, tol = 1e-12) {
  n <- basis <- vp <- numeric(0); group <- integer(0); g <- 0L; assets <- 0; wvs <- numeric(0)
  for (nm in .wd_held(ol, report, sv, tol)) {
    L <- ol[[nm]]$lots; U <- sum(L$units)
    keep <- L$units > 0; L <- L[keep, , drop = FALSE]
    wv <- utils::tail(as.numeric(report[[nm]]$worth), 1)
    n <- c(n, L$units / U * wv); basis <- c(basis, L$units * L$price); vp <- c(vp, L$vp)
    group <- c(group, rep(g, nrow(L))); g <- g + 1L; assets <- assets + wv; wvs <- c(wvs, wv)
  }
  cash <- sv - assets
  if (cash > tol * sv) { n <- c(n, cash); basis <- c(basis, cash); vp <- c(vp, 0); group <- c(group, g) }
  else if (-cash > tol * sv) {
    # Negativer Geldbestand (Rundungsrest oder ungedeckte Steuer der Ansparphase): seit 1.6.4 kein negativer
    # Cash-Lot mehr (A-062, Entscheidungen 87 und 104), sondern vom ersten Verkauf abgezogen: der aelteste Lot des
    # wertgroessten Assets wird um den Fehlbetrag gemindert (reicht er nicht, die naechsten Lots dieses Assets),
    # Basis und Vorabpauschale anteilig; auf diesen Rest wird keine Steuer gerechnet
    keep <- rep(TRUE, length(n)); rest <- -cash
    for (j in which(group == which.max(wvs) - 1L)) {
      if (!(rest > 0)) break
      take <- min(n[j], rest); f <- (n[j] - take) / n[j]
      n[j] <- n[j] - take; basis[j] <- basis[j] * f; vp[j] <- vp[j] * f; rest <- rest - take
      if (!(n[j] > 0)) keep[j] <- FALSE
    }
    n <- n[keep]; basis <- basis[keep]; vp <- vp[keep]; group <- group[keep]
  }
  list(n = n, basis = basis, vp = vp, group = group)
}

#' Am Ende der Ansparphase gehaltene Assets
#'
#' Namen der Assets aus \code{open_lots} mit Stueck > 0 und Endwert
#' (\code{report$<asset>$worth}) > \code{tol} x \code{sv}. Die relative
#' Toleranz 1e-12 des Depotwerts liegt weit ueber Rundungsresten der Engine
#' (Stueckreste um 1e-14 nach Verkauf auf Gewicht 0, Wert 0 oder um 1e-12
#' EUR) und weit unter jedem wirtschaftlich relevanten Betrag (1e-6 EUR bei
#' 1 Mio. EUR). Wertlose Restpositionen (Wert 0, z. B. nach Knockout) haben
#' in der Entnahmephase keinen Anteil und werden nie verkauft.
#' @keywords internal
#' @noRd
.wd_held <- function(ol, report, sv, tol = 1e-12) {
  Filter(function(nm) {
    L <- ol[[nm]]$lots; wv <- utils::tail(as.numeric(report[[nm]]$worth), 1)
    nrow(L) > 0 && sum(L$units) > 0 && length(wv) == 1L && is.finite(wv) && wv > tol * sv
  }, names(ol))
}

#' Ist eine Ordergebuehr gesetzt (Zahl oder list(fixed, percent, min, max))?
#' @keywords internal
#' @noRd
.wd_fee_set <- function(f) {
  if (is.null(f)) return(FALSE)
  v <- if (is.list(f)) unlist(f[intersect(names(f), c("fixed", "percent", "min"))]) else f
  v <- suppressWarnings(as.numeric(v))
  any(is.finite(v) & v != 0)
}

#' Entnahme-Simulation ueber viele Pfade
#'
#' Simuliert eine Entnahmeregel auf historischen Kohorten ([withdrawal_cohorts()]),
#' Bootstrap-Pfaden ([withdrawal_paths()], [bootstrap_pooled()]), gespeicherten
#' Ergebnissen von [simulation()] bzw. [bootstrap_study()] oder einer
#' beliebigen Renditematrix. Je Pfad entstehen Erfolg, Erschoepfungsjahr,
#' reales Endvermoegen, Konsumkennzahlen, Steuern und die Perfect Withdrawal
#' Rate. Der Rechenkern ist in C++ implementiert.
#'
#' Ablauf je Planjahr: Zu Beginn legt die Regel den Jahresbetrag fest; er wird
#' gleichmaessig auf die Perioden des Jahres verteilt und je nach
#' \code{timing} zu Beginn oder Ende jeder Periode als Netto-Betrag entnommen
#' (abzueglich \code{income}). Ein Pfad scheitert, sobald eine geplante
#' Entnahme nicht mehr voll bezahlt werden kann. Ausnahme Verzehrregeln
#' (\code{one_over_n}, \code{vpw}, \code{abw}, \code{hebeler}): Sie leeren
#' das Depot planmaessig im letzten Planjahr bzw. in dem Jahr, fuer das sie
#' das ganze Depot vorsehen (Jahresbetrag >= Depotwert zu Jahresbeginn, z. B.
#' \code{vpw} bei Erreichen von \code{max_age}). Wird das Depot in einem
#' solchen Jahr vollstaendig verkauft und faellt die Entnahme dabei kleiner
#' aus (Steuern und Kosten aus dem Erloes bezahlt, bei unterjaehrigen
#' Perioden auch Kursverluste im Jahr), ist das kein Fehlschlag, sofern der
#' Jahresbetrag das Depot zu Jahresbeginn nicht uebersteigt (sonst, z. B. bei
#' \code{hebeler} durch die Glaettung, bleibt es ein Fehlschlag). Bei allen
#' anderen Regeln zaehlt jede nicht voll bezahlte Entnahme als Fehlschlag. Alle "realen" Groessen sind
#' durch die aufgelaufene Inflation geteilt, also in Kaufkraft des
#' Startzeitpunkts.
#'
#' Besteuerung (\code{tax = tax_profile()}): vereinfachtes Modell eines
#' einzelnen thesaurierenden Fondsbestands nach heutiger Rechtslage
#' (Modellphilosophie des Pakets): Verkaufsgewinne mit Teilfreistellung,
#' Verlustverrechnung vor Sparer-Pauschbetrag, Abgeltungsteuer;
#' Vorabpauschale zum Jahresende festgesetzt; sie gilt nach § 18 Abs. 3
#' InvStG am ersten Werktag des Folgejahres als zugeflossen und wird daher
#' wie in [simulation()] mit Verlusttopf und Sparer-Pauschbetrag des
#' Folgejahres versteuert, durch Anteilsverkauf beglichen und beim
#' spaeteren Verkauf angerechnet. Die Vorabpauschale des letzten Planjahres
#' wird am Pfadende abgerechnet wie in [simulation()] bei Datenende am 31.12.:
#' die Steuer auf die VP wird vorab mit den Toepfen des Folgejahres (neuer
#' Pauschbetrag, Verlusttopf am Jahresende) bestimmt und per Zwangsverkauf
#' noch im ablaufenden Jahr bezahlt (Gewinn mit dessen Pauschbetrag und
#' Verlusttopf); danach wird die VP-Steuer mit dem Verlusttopf nach diesem
#' Verkauf endgueltig berechnet und die Differenz ausgeglichen (Nachzahlung
#' per Verkauf im Folgejahr, Erstattung als Geld ins Depot). Alle diese
#' Steuern mindern das Endvermoegen und zaehlen in \code{taxes}; ebenso beim
#' Endvermoegen am Horizont (\code{horizon}). Waehrend des Pfades wird die VP-Steuer dagegen zusammen mit
#' der ersten Entnahme des Folgejahres verkauft (Toepfe des Folgejahres). Ohne
#' Lots einer Ansparphase rechnet der Kern mit Durchschnittskosten
#' (\code{cost_basis}); bei einer Einmalanlage ohne Zukaeufe ist das identisch
#' mit FIFO. Das Planjahr wird als Steuerjahr behandelt; der Sparer-Pauschbetrag
#' steht in jedem Planjahr neu und nominal unveraendert zur Verfuegung.
#'
#' FIFO mit den Lots einer Ansparphase: Ist \code{start_value} ein
#' \code{SimLevResult} mit \code{open_lots} (gerechnet mit \code{tax =
#' tax_profile()}), \code{cost_basis} nicht angegeben und \code{tax =
#' tax_profile()}, uebernimmt die Entnahmephase die einzelnen Lots: je Asset in
#' FIFO-Reihenfolge mit Anschaffungskosten (\code{units} x \code{price}) und
#' anzurechnender Vorabpauschale (\code{vp}); der Wert eines Lots ist sein
#' Stueckanteil am Endwert des Assets. Ein Verkauf nimmt jedem Asset seinen
#' Wertanteil am Depot (die Entnahmephase hat nur eine Renditereihe, die
#' Anteile bleiben daher konstant) und innerhalb des Assets die aeltesten
#' Lots zuerst; Gewinn je Lot = Erloes x (1 - \code{sale_cost} / 100) minus
#' Anschaffungskosten minus anteilige Vorabpauschale (§ 19 InvStG), die
#' Gewinne aller verkauften Lots werden summiert und mit Teilfreistellung
#' \code{partial_exemption}, Verlusttopf, Sparer-Pauschbetrag und Steuersatz \code{rate}
#' besteuert (wie [simulation()] je Verkauf, siehe dort \code{open_lots}).
#' Cash am Ende der Ansparphase ist eine eigene Position mit Basis = Betrag,
#' die wie bisher mit der Depotrendite waechst und anteilig verkauft wird.
#' Neue Vorabpauschalen sind je Anteil fuer alle Lots gleich: es gibt keine
#' Zukaeufe, jedes Lot wird ganzjaehrig gehalten, und alle Assets haben
#' dieselbe Rendite (in [simulation()] haengt die VP je Stueck nur vom
#' Kursverlauf des Jahres und der Haltedauer ab). Einkommen mindern nur die
#' Entnahme, Umschichtungen gibt es in der Entnahmephase nicht; die Lots
#' werden also nur durch Verkaeufe und Vorabpauschalen fortgeschrieben.
#'
#' Tarifweg (\code{tax = tax_profile(income = income_tariff())}): Verkaeufe und
#' Vorabpauschalen werden unterjaehrig mit der Abgeltungsteuer belastet. Nach
#' jedem Planjahr folgt je Pfad eine Veranlagung wie der Jahresabschluss von
#' [simulation()] mit einem festen Tarif aus [tax_tariff()]:
#' Kapitalertraege K = mit Abgeltungsteuer belastete Bemessungsgrundlage des
#' Planjahres (nach Teilfreistellung, Verlusttopf und Sparer-Pauschbetrag; die
#' Vorabpauschale zaehlt im Jahr ihres Zuflusses), Kirchensteuer als
#' Sonderausgabe im Zahlungsjahr (Saldo des Bescheids des Vorjahres; im ersten
#' Planjahr 0), mit \code{guenstigerpruefung = TRUE} der Vergleich mit dem
#' Tarif auf zvE + K. Der Saldo (Nachzahlung bzw. Erstattung) wird mit der
#' ersten Entnahme des Folgejahres gezahlt bzw. mindert sie (wie die Steuer auf
#' die Vorabpauschale); eine Erstattung ueber diese Entnahme hinaus fliesst als
#' Geld ins Depot. Am Pfadende und am Horizont wird das letzte Planjahr sofort
#' veranlagt und abgerechnet wie in \code{simulation()} am letzten Tag (der
#' Zwangsverkauf fuer die Vorabpauschale zaehlt zu diesem Jahr); mit
#' Guenstigerpruefung wird die Vorabpauschale des letzten Planjahres (Zufluss im
#' Folgejahr) zusaetzlich fuer das Folgejahr veranlagt, sofern dafuer ein zvE
#' vorliegt (eine Zahl fuer alle Jahre bzw. ein benannter Wert fuer dieses
#' Kalenderjahr). Nachzahlungen werden per Verkauf, Erstattungen als Geld ins
#' Depot abgerechnet; alle Salden zaehlen in \code{taxes}. Ohne Kirchensteuer
#' und ohne Guenstigerpruefung ist der Saldo stets 0. Die Jahreszeilen stehen
#' im Ergebnis unter \code{tariff_years}.
#'
#' Kalender: Die Entnahmephase kennt keine Kalenderjahre; ihr erstes Planjahr
#' gilt als das Jahr nach dem letzten Datentag der Ansparphase
#' (\code{tax_report$next_year$year}), jedes weitere Planjahr als ein neues
#' Steuerjahr. Was [simulation()] diesem Jahr schon zugerechnet hat (endet
#' die Ansparphase am 31.12.: die dort festgesetzte und im Folgejahr
#' verrechnete Vorabpauschale), geht ein: im ersten Planjahr steht nur
#' \code{sparer_pauschbetrag} minus \code{next_year$sparer_pauschbetrag_used}
#' zur Verfuegung, der Verlusttopf beginnt mit
#' \code{next_year$loss_carryforward_capital}.
#'
#' Grenzen gegenueber [simulation()]: (1) Verluste: Die Entnahmephase
#' saldiert Gewinne und Verluste der Lots eines Verkaufs sofort und traegt
#' einen verbleibenden Verlust in den Topf vor; eine Erstattung bereits
#' versteuerter Ertraege desselben Jahres gibt es nicht. [simulation()]
#' besteuert jeden Verkauf eines Assets einzeln und erstattet zum Jahresende
#' Steuer auf im Jahr versteuerte Ertraege, wenn spaeter im Jahr Verluste
#' entstehen (unterjaehrige Verlustverrechnung, mit Freigabe des
#' Pauschbetrags). Gleich sind beide, solange in einem Planjahr alle Verkaeufe
#' Gewinne ergeben. (2) Steuersatz: die Entnahmephase rechnet mit einem festen
#' Satz aus \code{tax_profile()} (\code{rate} bzw. mit \code{church_tax} der
#' Satz nach § 32d Abs. 1 EStG, mit \code{guenstigerpruefung} und
#' \code{income_rate()} gegebenenfalls der persoenliche Satz). Kirchensteuer und
#' Guenstigerpruefung der Ansparphase werden nicht uebernommen; sie sind in
#' \code{tax} ausdruecklich anzugeben. Mit dem Tarifweg (\code{income_tariff()})
#' gilt unterjaehrig die Abgeltungsteuer und je Planjahr eine Veranlagung (siehe
#' Tarifweg); das zvE gilt fuer alle Pfade gleich, wird nicht mit der Inflation
#' fortgeschrieben, und \code{income} zaehlt nicht dazu. (3) Ordergebuehren beim Verkauf bildet die Entnahmephase nicht
#' ab (Warnung, wenn sie in der Ansparphase gesetzt waren). (4) Verschiedene
#' Teilfreistellungen, Regime \code{"capital_gains"} neben Fonds und
#' \code{"private_sale"} (§ 23 EStG) werden nicht getrennt besteuert
#' (Warnung); Teilfreistellung und Vorabpauschale gelten fuer den ganzen
#' Bestand. (5) Positionen ohne Wert (Endwert <= 1e-12 x Depotwert, etwa nach
#' Knockout) entfallen; ein Verlust aus ihrem Verkauf entsteht in der
#' Entnahmephase nicht.
#'
#' Renditequellen: Die Entnahmephase ist bewusst von [simulation()] getrennt.
#' Ein gespeichertes Ergebnis von [simulation()] (etwa per \code{saveRDS()})
#' liefert ueber seinen zeitgewichteten Wertindex ([result_index()]) die
#' Renditen; bei einem Einzelergebnis werden daraus historische Kohorten
#' gebildet (wie [withdrawal_cohorts()] mit monatlichen Starts), eine Liste
#' von Ergebnissen (z. B. je Bootstrap-Pfad) oder eine [bootstrap_study()] mit
#' \code{keep_returns} liefert je Element einen Pfad (ueber
#' [withdrawal_paths()]). Ein \code{bootstrap_result} aus [bootstrap()] zuerst
#' mit [withdrawal_paths()] umwandeln.
#' Wurde das Quellergebnis bereits mit Steuern (\code{tax = tax_profile()}) gerechnet,
#' enthaelt der Index schon Vorabpauschalen; dann hier \code{vorabpauschale =
#' FALSE} setzen oder die Quelle ohne Steuern rechnen (bei Ergebnissen und
#' Ergebnislisten erscheint dazu eine Warnung).
#'
#' @param x Renditequelle, eine der folgenden:
#'   \describe{
#'   \item{\code{withdrawal_paths}}{aus \code{\link[=withdrawal_cohorts]{withdrawal_cohorts()}},
#'   \code{\link[=withdrawal_paths]{withdrawal_paths()}} oder \code{\link[=bootstrap_pooled]{bootstrap_pooled()}}; Inflation und
#'   Frequenz stammen aus dem Objekt (\code{inflation} und
#'   \code{frequency} werden ignoriert).}
#'   \item{Matrix}{(Perioden x Pfade) von Brutto-Periodenrenditen nach
#'   Produktkosten (1.05 = +5 Prozent); keine negativen Werte, Median >= 0.5.}
#'   \item{\code{SimLevResult}}{historische Kohorten ueber dessen Verlauf,
#'   Laenge \code{years} (Standard 30 Jahre).}
#'   \item{\code{SimLevWrapperNav}}{Anteilswert eines Fonds-Wrappers aus
#'   \code{\link[=wrapper_nav]{wrapper_nav()}}: historische Kohorten ueber die Spalte \code{nav}
#'   wie \code{withdrawal_cohorts(x, price = "nav")}, Laenge \code{years} (Standard 30 Jahre).
#'   Nur das ganze Objekt: Ein Ausschnitt (\code{x[i, ]}, \code{head()},
#'   \code{subset()}) ist ein gewoehnlicher \code{data.frame}; Tabellen mit
#'   Spalte \code{date} ergeben einen Fehler mit Hinweis auf
#'   \code{withdrawal_cohorts(x, price = "nav")}.}
#'   \item{Liste von \code{SimLevResult} oder \code{SimLevBootstrapStudy}}{
#'   (mit \code{keep_returns}; Strategie ueber \code{strategy}) je
#'   Element bzw. Studienpfad ein Pfad.}
#'   }
#' @param rule Objekt aus [withdrawal_rule()] (Standard: konstante reale
#'   Entnahme mit 4 %).
#' @param start_value Startvermoegen als Geldbetrag > 0 (Standard 1e6) oder ein
#'   \code{SimLevResult} der Ansparphase: dann gilt dessen letzter Depotwert
#'   (Stueck x Schlusskurs ohne Spread plus Cash) als Startvermoegen (ein
#'   Endwert <= 0, etwa durch eine offene Steuerschuld
#'   \code{tax_report$open_tax_debt}, ist ein Fehler) und,
#'   sofern \code{cost_basis} nicht angegeben ist, wird \code{cost_basis}
#'   daraus abgeleitet (siehe dort). Mit Steuern (\code{tax = tax_profile()}) wird
#'   gewarnt, wenn die am Ende gehaltenen Assets eine andere Teilfreistellung
#'   als \code{partial_exemption} haben (Regime \code{"capital_gains"} zaehlt als
#'   0 %) oder das Regime \code{"private_sale"} (§ 23 EStG) haben, das die
#'   Entnahmephase nicht abbildet. Mit Steuern werden
#'   ausserdem die Lots (FIFO, siehe Details) und nicht angegebene
#'   \code{partial_exemption}, \code{loss_carryforward} und \code{sale_cost} aus
#'   dem Ergebnis uebernommen (siehe dort); was uebernommen wurde, meldet
#'   ein Hinweis (\code{message()}) und steht im Ergebnis unter
#'   \code{adopted}. Ausdrueckliche Angaben haben immer Vorrang.
#' @param inflation Inflation fuer Eingaben ohne eigene Inflationsreihe:
#'   Zahl = konstante Inflation in Prozent p. a. (Standard 0; 2 = 2 % p. a.)
#'   bei Matrix-, Ergebnis-, Ergebnislisten- und Studien-Eingabe; bei
#'   Matrix-Eingabe auch eine Matrix gleicher Dimension mit
#'   Brutto-Periodeninflation (z. B. 1.002 je Monat); bei Studien auch der Name
#'   einer mit \code{keep_aux} gespeicherten Zusatzreihe (Behandlung wie in
#'   [withdrawal_paths()] ohne \code{inflation_type}: eine Reihe mit
#'   \code{aux_type = "rate"} in [bootstrap_config()] gilt als Inflationsrate
#'   in Prozent pro Jahr, 2 = 2 % p. a., nicht je Datenperiode, kein Anteil,
#'   ueber die Kalendertage aufgezinst; ohne Angabe in \code{aux_type} wie
#'   bisher die gespeicherte Niveau-Variante). \code{NULL} wie 0.
#'   Bei \code{withdrawal_paths} ohne Wirkung.
#'   Eine Inflationsmatrix muss endliche Zahlen > 0 enthalten.
#' @param frequency Periodenlaenge der Zeilen bei Matrix-Eingabe bzw. der
#'   erzeugten Perioden bei Ergebnis- und Ergebnislisten-Eingabe:
#'   \code{"year"} (Standard), \code{"quarter"} oder \code{"month"}. Bei
#'   \code{withdrawal_paths} und Studien gilt die gespeicherte Frequenz.
#' @param strategy Bei \code{SimLevBootstrapStudy}: Name der Strategie
#'   (\code{NULL} = erste gespeicherte).
#' @param years Optional Anzahl Jahre (seit 1.6.4 eine ganze Zahl von 1 bis 100,
#'   auch bei unterjaehriger frequency): Kuerzung auf die ersten \code{years}
#'   Jahre (\code{years} x Perioden je Jahr Zeilen). Bei einem
#'   \code{SimLevResult} zugleich die Kohortenlaenge (\code{NULL} = 30).
#'   \code{NULL} (Standard) = volle Pfadlaenge.
#' @param timing Zeitpunkt der Entnahme innerhalb jeder Periode:
#'   \code{"start"} (Standard; vor der Rendite) oder \code{"end"} (nach der
#'   Rendite).
#' @param income Optional weitere Einkommen (z. B. gesetzliche Rente): Liste
#'   von Listen \code{list(start = Jahr, end = Jahr, amount = Betrag)}; ein
#'   einzelnes \code{list(start, end, amount)} wird automatisch verpackt.
#'   \code{start}/\code{end} sind Planjahre (Standard 1 bzw. letztes Jahr,
#'   \code{start <= end}; Jahre nach dem Pfadende entfallen), \code{amount} ist ein realer
#'   Jahresbetrag in Kaufkraft des Startzeitpunkts. Einkommen mindern die
#'   Depotentnahme (Entnahme = max(0, Regelbetrag - Einkommen)) und zaehlen im
#'   Konsum (\code{spending}) mit.
#'   Seit 1.6.4 sind start und end ganze Planjahre (end auch Inf); vorher wurden gebrochene Werte gerundet.
#'   Seit 1.6.4 ist start ein ganzes Planjahr >= 1; wer kein Einkommen hat, laesst den Eintrag weg (vorher lief start
#'   = Inf als nie und start <= 0 als Planjahr 1).
#' @param tax Steuerdaten der Person: \code{NULL} (Standard; keine Steuern)
#'   oder ein Objekt aus \code{\link[=tax_profile]{tax_profile()}} (vereinfachte deutsche Besteuerung,
#'   siehe Details). Ausgewertet werden \code{rate} (Abgeltungsteuer inkl.
#'   Solidaritaetszuschlag in Prozent, Standard 26.375), \code{church_tax}
#'   (Kirchensteuer in Prozent; der Satz der Abgeltungsteuer folgt dann
#'   § 32d Abs. 1 EStG wie in \code{\link[=simulation]{simulation()}}),
#'   \code{guenstigerpruefung} mit \code{income = \link[=income_rate]{income_rate()}}
#'   (Guenstigerpruefung wie in \code{\link[=simulation]{simulation()}}: einmal je
#'   Lauf; ist der Grenzsteuersatz einschliesslich Soli und Kirchensteuer
#'   niedriger als die Abgeltungsteuer, gilt er fuer alle Verkaeufe und
#'   Vorabpauschalen aller Pfade und Planjahre; ohne \code{income} Warnung und
#'   Abgeltungsteuer; \code{income_rate()} ohne \code{guenstigerpruefung = TRUE}
#'   wirkt nicht) und
#'   \code{sparer_pauschbetrag} (Sparer-Pauschbetrag je Planjahr als nominaler
#'   Geldbetrag, Standard 1000; 2000 bei Zusammenveranlagung; 0 = ohne). Bei
#'   \code{start_value} = \code{SimLevResult} mit \code{tax_report$next_year}
#'   steht im ersten Planjahr nur dieser Betrag minus
#'   \code{next_year$sparer_pauschbetrag_used} zur Verfuegung (siehe Details,
#'   Kalender; bei gleichem Pauschbetrag wie in der Ansparphase
#'   \code{next_year$sparer_pauschbetrag_remaining}). Angaben, die die
#'   Entnahmephase nicht abbildet (\code{private_sale_threshold} ungleich 1000,
#'   \code{base_rate}, \code{harvest}), ergeben einen Fehler; der Basiszins kommt
#'   aus \code{base_rate} dieser Funktion. Mit
#'   \code{income = \link[=income_tariff]{income_tariff(taxable_income, tariff)}}
#'   rechnet die Entnahmephase den Tarifweg wie \code{\link[=simulation]{simulation()}}:
#'   unterjaehrig Abgeltungsteuer, nach jedem Planjahr je Pfad eine Veranlagung
#'   (siehe Details, Tarifweg). \code{taxable_income} ist das zu versteuernde
#'   Einkommen ohne die Ertraege der Entnahme, nominal in EUR genau wie angegeben
#'   (ohne Fortschreibung mit der Inflation): eine Zahl gilt fuer alle Planjahre,
#'   ein Vektor ohne Namen braucht einen Wert je Planjahr; nach Kalenderjahren
#'   benannt (Vektor oder data.frame wie in \code{simulation()}) nur mit einem
#'   \code{SimLevResult} als \code{start_value} (Planjahr 1 =
#'   \code{tax_report$next_year$year}), sonst Fehler. \code{income} dieser Funktion
#'   zaehlt nicht zum zvE; einen steuerpflichtigen Teil (etwa einer Rente) selbst
#'   in \code{taxable_income} einrechnen. Kirchensteuer und Guenstigerpruefung
#'   werden nicht aus der Ansparphase (\code{start_value} = \code{SimLevResult})
#'   uebernommen, sondern hier ausdruecklich in \code{tax_profile()} angegeben.
#'   Die Bestandsmerkmale (\code{partial_exemption}, \code{vorabpauschale},
#'   \code{cost_basis}, \code{loss_carryforward}, \code{sale_cost}) sind eigene
#'   Argumente. Wie in \code{\link[=simulation]{simulation()}} sind \code{partial_exemption},
#'   \code{sale_cost}, \code{cost_basis}, \code{loss_carryforward} und
#'   \code{gamma} einzelne endliche Zahlen im zulaessigen Bereich (sonst Fehler);
#'   Werte zwischen 0 und 1 bei \code{partial_exemption} und \code{cost_basis}
#'   sowie zwischen 0 und 0,05 bei \code{inflation} (Zahl) und \code{base_rate}
#'   (Zahl) loesen eine Warnung aus (vermutlich Anteil statt Prozent).
#' @param partial_exemption Teilfreistellung in Prozent (Standard 30 fuer
#'   Aktienfonds; 15 fuer Mischfonds). Nicht angegeben und \code{start_value}
#'   ein \code{SimLevResult} mit \code{open_lots}: die gemeinsame
#'   Teilfreistellung der am Ende gehaltenen Assets (Regime
#'   \code{"capital_gains"} = 0), sofern alle denselben Wert haben und keines
#'   das Regime \code{"private_sale"} hat und keine Fonds neben anderen
#'   Regimen gehalten werden; sonst 30 mit Warnung. Als gehalten gelten Assets
#'   mit Endwert > 1e-12 x Depotwert (Stueckreste ohne Wert zaehlen nicht).
#' @param base_rate Basiszins fuer die Vorabpauschale in Prozent (Standard
#'   3.20 fuer 2026; negative Werte zaehlen als 0): Skalar oder Matrix
#'   (Perioden x Pfade, gleiche Dimension wie die Renditen vor einer Kuerzung
#'   mit \code{years}), massgeblich ist der Wert der letzten Periode jedes
#'   Planjahres. Enthaelt \code{x} eine Basiszins-Reihe (Argument
#'   \code{base_rate} in [withdrawal_cohorts()]), wird diese verwendet.
#'   Seit 1.6.4 ohne NA (auch in einer Reihe aus withdrawal_cohorts()); Jahre ohne Basiszins als 0 angeben.
#' @param vorabpauschale Logisch: Vorabpauschale beruecksichtigen (Standard
#'   \code{TRUE}; nur mit \code{tax = tax_profile()} wirksam). Nicht angegeben
#'   und \code{start_value} ein \code{SimLevResult} mit \code{open_lots}, in
#'   dem kein gehaltenes Asset das Regime \code{"investment_fund"} hat (nur
#'   ETN/Zertifikate, \code{"capital_gains"}, bzw. \code{"private_sale"}):
#'   \code{FALSE}, da \code{\link[=simulation]{simulation()}} dort keine Vorabpauschale erhebt. Bei
#'   Fonds neben anderen Regimen Warnung, keine Uebernahme.
#' @param sale_cost Verkaufskosten in Prozent des Verkaufsbetrags (Standard 0;
#'   z. B. halber Spread). Nicht angegeben und \code{start_value} ein
#'   \code{SimLevResult} mit \code{open_lots}: der halbe Spread
#'   (\code{spread}) der am Ende gehaltenen Assets, sofern alle
#'   denselben Spread haben (sonst 0 mit Warnung; ohne Spread-Angabe im
#'   Ergebnis 0). Ordergebuehren bildet die Entnahmephase nicht ab; waren sie
#'   in der Ansparphase gesetzt, warnt die Funktion.
#' @param cost_basis Anschaffungskosten in Prozent des Startwerts (Standard
#'   100 = frisch gekauft; kleiner bei Altbestand mit stillen Reserven),
#'   einschliesslich bereits versteuerter Vorabpauschalen, die beim Verkauf
#'   nach § 19 InvStG angerechnet werden. Mit \code{cost_basis} rechnet die
#'   Entnahmephase mit Durchschnittskosten: jede Entnahme verbraucht den
#'   Anteil Entnahme / Depotwert der Basis. Ein ausdruecklich angegebener Wert
#'   gilt immer (auch bei einem \code{SimLevResult}; dann ohne FIFO-Lots). Ist
#'   \code{start_value} ein \code{SimLevResult} und \code{cost_basis} nicht
#'   angegeben:
#'   \describe{
#'   \item{nur Cash am letzten Tag}{(z. B. \code{liquidate = TRUE}): 100,
#'   alle Gewinne sind bereits versteuert.}
#'   \item{mit offenen Lots}{(Element \code{open_lots}, nur Ergebnisse mit
#'   \code{simulation(tax = tax_profile())}): mit \code{tax = tax_profile()} die Lots
#'   selbst (FIFO, siehe Details); ihre Summe entspricht 100 x
#'   (Anschaffungskosten \code{units} x \code{price} plus anzurechnende
#'   Vorabpauschalen \code{vp} aller Assets plus Cash) / Endwert. Ein
#'   Verkauf ergibt dieselbe Steuer wie in \code{\link[=simulation]{simulation()}} beim Verkauf
#'   derselben Stueckzahl, wenn \code{sale_cost} dem halben Spread
#'   entspricht, keine Ordergebuehr anfaellt, alle Assets die
#'   Teilfreistellung \code{partial_exemption} haben und Topf und
#'   Sparer-Pauschbetrag gleich stehen.}
#'   \item{sonst}{(Ergebnis ohne Steuern oder aelter):
#'   die Naeherung 100 x (Startwert brutto + Summe der Einzahlungen) /
#'   Endwert, mit Warnung bei \code{tax = tax_profile()}. Sie behandelt
#'   bereits realisierte (und versteuerte) Gewinne, Vorabpauschalen und Cash
#'   wie stille Reserven und ueberschaetzt die spaetere Steuer dann.}
#'   }
#' @param loss_carryforward Anfangsbestand des Verlusttopfs als nominaler
#'   Geldbetrag (Standard 0; Betrag nach Teilfreistellung wie in
#'   [simulation()]). Nicht angegeben und \code{start_value} ein
#'   \code{SimLevResult} mit \code{open_lots}: der allgemeine Verlusttopf
#'   (Topf fuer Fonds und sonstige Kapitalertraege) zu Beginn des ersten
#'   Planjahres, \code{tax_report$next_year$loss_carryforward_capital}
#'   (aeltere Ergebnisse ohne \code{next_year}:
#'   \code{tax_report$loss_carryforward_capital}); der Verlustvortrag fuer
#'   private Veraeusserungsgeschaefte wird nicht uebernommen.
#' @param gamma Relative Risikoaversion (CRRA, Zahl, Standard 2) fuer das
#'   Sicherheitsaequivalent der realen jaehrlichen Konsumreihe
#'   (\code{gamma = 1}: geometrisches Mittel).
#' @param keep_paths Vermoegensmatrix \code{wealth} zurueckgeben: \code{TRUE}
#'   (Standard) = alle Pfade, \code{FALSE} oder 0 = keine, ganze Zahl k >= 1 =
#'   die ersten k Pfade (Spalten; k groesser als die Pfadzahl: alle). Gerechnet
#'   werden immer alle Pfade; \code{plot()} zeichnet den Vermoegensfaecher dann
#'   nur aus den behaltenen Pfaden (Titel mit \dQuote{erste k von n Pfaden}).
#'   Bei historischen Kohorten sind das die fruehesten Starts.
#' @param horizon Optional Laufzeit je Pfad: Objekt aus [withdrawal_horizon()]
#'   (zufaellige Laufzeit in Jahren je Pfad) oder eine Zahl > 0 = feste Laufzeit in
#'   Jahren. \code{NULL} (Standard) = volle Pfadlaenge. Dann gilt ein Pfad als
#'   erfolgreich, wenn das Vermoegen bis zu seinem Horizont reicht;
#'   reales Endvermoegen, Steuern, Konsumkennzahlen und PWR (diese nur bei
#'   Jahresperioden, sonst \code{NA}) beziehen sich auf den
#'   jeweiligen Horizont; Endvermoegen und Steuern enthalten dabei die
#'   Abrechnung der Vorabpauschale des Horizontjahres wie am Pfadende (ein
#'   Pfad mit H Jahren und Horizont H auf laengeren Pfaden ergeben dasselbe) (\code{paths$horizon}, Erfolg ueber die volle
#'   Pfadlaenge in \code{paths$success_full}). Horizonte ueber der Pfadlaenge
#'   werden mit Warnung gekuerzt. Die Regel selbst rechnet weiter mit den
#'   Restjahren der vollen Pfadlaenge. Nicht zu verwechseln mit \code{horizon}
#'   in [planning_goal()] (Perioden).
#'   Seit 1.6.4 als Zahl eine ganze Zahl von Jahren von 1 bis 100.
#'
#' @return Objekt der Klasse \code{SimLevWithdrawal} (Liste):
#'   \describe{
#'   \item{\code{paths}}{data.frame mit einer Zeile je Pfad:
#'   \code{success} (logisch: alle geplanten Entnahmen voll bezahlt bzw.
#'   planmaessig vollstaendig geleert, siehe Details),
#'   \code{depletion_year} (Planjahr der ersten Unterdeckung, sonst
#'   \code{NA}), \code{terminal_real} (reales Endvermoegen),
#'   \code{terminal_nominal} (nominales Endvermoegen am Pfadende),
#'   \code{first_withdrawal} (realer Konsum im ersten Planjahr),
#'   \code{mean_spending}, \code{min_spending}, \code{total_spending}
#'   (Mittel, Minimum, Summe des realen Jahreskonsums),
#'   \code{spending_drawdown} (groesster Rueckgang des realen Konsums
#'   gegenueber dem bisherigen Hoechststand, als Anteil 0 bis 1),
#'   \code{ce_spending} (Sicherheitsaequivalent nach \code{gamma});
#'   Mittel, Minimum, Rueckgang und Sicherheitsaequivalent nur ueber volle
#'   Planjahre (ein unvollstaendiges letztes Planjahr zaehlt nur in
#'   \code{total_spending}; ohne volles Jahr \code{NA}),
#'   \code{taxes} (Summe der Steuern, real) und \code{pwr} (Perfect
#'   Withdrawal Rate in Prozent); bei Kohorten zusaetzlich \code{start}
#'   (Startdatum), mit \code{horizon} zusaetzlich \code{horizon} (Jahre) und
#'   \code{success_full}.}
#'   \item{\code{spending}}{Matrix Planjahre x Pfade: realer Konsum
#'   (Netto-Entnahme plus \code{income}).}
#'   \item{\code{planned}}{Matrix Planjahre x Pfade: von der Regel geplante
#'   Jahresentnahme (real, vor Abzug von \code{income}).}
#'   \item{\code{wealth}}{Matrix (Planjahre + 1) x Pfade: reales Vermoegen zu
#'   Beginn jedes Planjahres, letzte Zeile am Ende; mit \code{keep_paths = k}
#'   nur die ersten k Spalten, \code{NULL} bei \code{keep_paths = FALSE}.}
#'   \item{\code{rule}, \code{start_value}, \code{frequency}, \code{horizon},
#'   \code{tax_mode} (\code{"person"} mit \code{tax}, sonst \code{"none"}), \code{gamma}, \code{timing}}{Eingaben.}
#'   \item{\code{years}, \code{full_years}}{Anzahl Planjahre (einschliesslich
#'   eines unvollstaendigen letzten Jahres) bzw. voller Planjahre.}
#'   \item{\code{historical}}{\code{TRUE} bei historischen Kohorten.}
#'   \item{\code{adopted}}{Nur bei \code{start_value} = \code{SimLevResult}
#'   und \code{tax = tax_profile()}: benannte Liste der aus der
#'   Ansparphase uebernommenen Werte (\code{lots} = Anzahl FIFO-Lots
#'   einschliesslich Cash-Position, \code{cost_basis} bei
#'   Durchschnittskosten, \code{partial_exemption}, \code{loss_carryforward},
#'   \code{sale_cost}, \code{sparer_pauschbetrag_used_year1} = im ersten
#'   Planjahr bereits verbrauchter Pauschbetrag, \code{vorabpauschale} =
#'   \code{FALSE} ohne gehaltene Fonds); sonst \code{NULL}.}
#'   \item{\code{weights}}{Pfadgewichte (Standard 1 je Pfad).}
#'   \item{\code{source}}{Herkunft der Renditen.}
#'   \item{\code{elapsed}}{Rechenzeit in Sekunden (ab Start des Kerns).}
#'   \item{\code{tariff_years}}{Nur mit dem Tarifweg (\code{income_tariff()}):
#'   data.frame mit einer Zeile je Pfad und veranlagtem Planjahr, nach Pfad und
#'   Jahr: \code{path}, \code{year} (Planjahr; Planjahre + 1 = Folgejahr am
#'   Pfadende) und dieselben Spalten wie \code{tax_report$tariff_years} in
#'   \code{\link[=simulation]{simulation()}} (zvE, Kirchensteuer-Sonderausgaben und ihre Wirkung,
#'   § 23-Spalten, in der Entnahme 0, \code{capital_income} = K, Abgeltungsteuer,
#'   Tarif auf K, Belastung ohne und mit Guenstigerpruefung, \code{guenstiger},
#'   \code{settlement} > 0 Nachzahlung bzw. < 0 Erstattung, \code{refund},
#'   \code{church_tax_settlement_next_year}); Betraege nominal in EUR.}
#'   }
#'   Auswertung mit \code{print()}, \code{summary()} und \code{plot()}
#'   (siehe \link{SimLevWithdrawal-methods}).
#' @examples
#' set.seed(1)
#' R <- matrix(exp(rnorm(30 * 500, 0.05, 0.15)), 30)    # 30 Jahre, 500 Pfade
#' ws <- withdrawal_simulation(R, withdrawal_rule("guyton_klinger", rate = 5),
#'                             start_value = 1e6, inflation = 2)
#' ws
#' # Ansparphase mit simulation(), speichern, dann Entnahmephase:
#' set.seed(2)
#' d <- data.frame(date = seq.Date(as.Date("1980-01-01"), as.Date("2019-12-31"), by = "day"))
#' d$ETF <- 100 * cumprod(1 + rnorm(nrow(d), 3e-4, 0.01))
#' res <- simulation(d, create_strategy(ETF = asset_config("etf", "bnh")), start_value = 1e5)
#' # saveRDS(res, "ansparphase.rds"); res <- readRDS("ansparphase.rds")
#' wr <- withdrawal_simulation(res, withdrawal_rule("vanguard", rate = 4),
#'                             years = 25, inflation = 2, start_value = 1e6)
#' summary(wr)
#' @seealso [withdrawal_rule()], [withdrawal_cohorts()], [withdrawal_paths()],
#'   [result_index()], [withdrawal_max_rate()], [simulation()], [bootstrap_study()]
#' @export
withdrawal_simulation <- function(x, rule = withdrawal_rule("constant"), start_value = 1e6,
                                  inflation = 0, frequency = c("year", "quarter", "month"),
                                  strategy = NULL,
                                  years = NULL, timing = c("start", "end"), income = NULL, tax = NULL,
                                  partial_exemption = 30, base_rate = 3.20,
                                  vorabpauschale = TRUE, sale_cost = 0, cost_basis = 100,
                                  loss_carryforward = 0, gamma = 2, keep_paths = TRUE, horizon = NULL) {
  fn <- "withdrawal_simulation"
  .e3_choice(timing, c("start", "end"), fn, "timing")   # Pruefung (Meldung auswahl)
  timing <- match.arg(timing)
  .e3_choice(frequency, c("year", "quarter", "month"), fn, "frequency")   # Pruefung (Meldung auswahl)
  frequency <- match.arg(frequency)
  chk_nofactor(strategy, fn, "strategy")
  chk_name1(strategy, fn, "strategy", null_ok = TRUE)
  # Steuerdaten der Person aus tax_profile() (rate, church_tax, sparer_pauschbetrag,
  # guenstigerpruefung, income_rate()); NULL = ohne Steuern. Die Bestandsmerkmale (partial_exemption,
  # vorabpauschale, cost_basis, loss_carryforward, sale_cost) und der Basiszins (base_rate, auch Matrix) bleiben
  # eigene Argumente.
  tax_mode <- .wd_tax_mode(tax)
  # Satz wie in simulation() (.tax_rates: Kirchensteuer, Guenstigerpruefung einmal je Lauf); die Angaben
  # stehen ausdruecklich in tax_profile(), aus der Ansparphase wird nichts uebernommen
  # Tarifweg (income_tariff()): unterjaehrig Abgeltungsteuer, Veranlagung je Planjahr und Pfad im Kern
  tariff_on <- !is.null(tax) && inherits(tax$income, "SimLevIncomeTariff")
  tax_rate <- if (is.null(tax)) 26.375 / 100 else {
    ti <- tax$income
    ir <- inherits(ti, "SimLevIncomeRate")
    .tax_rates(tax$rate, tax$church_tax, tax$guenstigerpruefung, if (ir) ti$marginal_rate, ir && ti$soli_rate != 0,
               if (ir) ti$soli_rate else 5.5, who = "withdrawal_simulation", tariff_on = tariff_on)$effective_tax_rate
  }
  sparer_pauschbetrag <- if (is.null(tax)) 1000 else tax$sparer_pauschbetrag
  if (!is.null(horizon) && !inherits(horizon, "SimLevHorizon")) {
    if (!is.numeric(horizon) || length(horizon) != 1L || !is.finite(horizon) || horizon <= 0)
      stop("withdrawal_simulation: 'horizon' muss NULL, ein Objekt aus withdrawal_horizon() oder eine Zahl von Jahren > 0 sein.",
           call. = FALSE)
    chk_jahre(horizon, fn, "horizon")     # seit 1.6.4 ganze Jahre bis 100 (Entscheidungen 19 und 46; bis 1.6.3 still abgeschnitten)
    horizon <- withdrawal_horizon("fixed", years = horizon)
  }
  if (!inherits(rule, "withdrawal_rule")) chk_stop("klasse", "withdrawal_simulation", "rule", "withdrawal_rule()")
  if (is.null(inflation)) inflation <- 0                    # NULL = keine Inflation (wie 0)
  # Steuer- und Prozentargumente wie in simulation() pruefen (einzelne endliche Zahl im Bereich)
  .chk <- function(x, arg, what, lo = 0, hi = Inf) {
    if (!is.numeric(x) || length(x) != 1L || !is.finite(x) || x < lo || x > hi)
      stop(sprintf("withdrawal_simulation: '%s' muss %s sein.", arg, what), call. = FALSE)
  }
  .frac <- function(x, arg, hi = 1, unit = "%") {
    if (is.numeric(x) && length(x) == 1L && is.finite(x) && x > 0 && x < hi)
      warning(sprintf("withdrawal_simulation: %s = %s wird als %s %s gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                      arg, format(x), format(x), unit, format(x * 100)), call. = FALSE)
  }
  .chk(partial_exemption, "partial_exemption", "eine Zahl von 0 bis 100 in Prozent (z. B. 30)", 0, 100); .frac(partial_exemption, "partial_exemption")
  .chk(sale_cost, "sale_cost", "eine Zahl von 0 bis unter 100 in Prozent (z. B. 0.1)", 0, 99.999)
  .chk(cost_basis, "cost_basis", "eine Zahl >= 0 in Prozent des Startwerts (z. B. 100)"); .frac(cost_basis, "cost_basis")
  .chk(loss_carryforward, "loss_carryforward", "eine Zahl >= 0 (EUR)")
  .chk(gamma, "gamma", "eine Zahl >= 0 (relative Risikoaversion, z. B. 2)")
  if (!is.logical(vorabpauschale) || length(vorabpauschale) != 1L || is.na(vorabpauschale))
    stop("withdrawal_simulation: 'vorabpauschale' muss TRUE oder FALSE sein.", call. = FALSE)
  kp <- .keep_count(keep_paths, Inf, "withdrawal_simulation")   # Anzahl behaltener Pfade, begrenzt nach ncol(R)
  if (is.numeric(inflation) && !is.matrix(inflation) && length(inflation) == 1L) {
    .chk(inflation, "inflation", "eine Zahl in Prozent p. a. \u00fcber -100 (z. B. 2) oder eine Matrix", -99.999)
    .frac(inflation, "inflation", hi = 0.05, unit = "% p. a.")
  }
  if (!is.matrix(base_rate)) .frac(base_rate, "base_rate", hi = 0.05)
  # seit 1.6.4 ganze Jahre von 1 bis 100, auch bei frequency "quarter"/"month" (Entscheidungen 46 und 47; bis 1.6.3
  # jede Zahl > 0, die ganze Perioden ergab)
  chk_jahre(years, fn, "years", null_ok = TRUE)
  if (if (is.matrix(base_rate)) !is.numeric(base_rate) else (!is.numeric(base_rate) || length(base_rate) != 1L || !is.finite(base_rate)))
    chk_stop("ut2.base_rate", "withdrawal_simulation")
  # einzelnes Einkommen list(start, end, amount) automatisch in eine Liste verpacken
  if (is.list(income) && !is.null(income$amount) && !is.list(income$amount)) income <- list(income)
  if (!is.null(income) && (!is.list(income) || !all(vapply(income, function(e) is.list(e) && is.numeric(e$amount) &&
                                                           length(e$amount) == 1L && is.finite(e$amount), TRUE))))
    chk_stop("ut2.income", "withdrawal_simulation")
  # Startvermoegen aus einer Ansparphase uebernehmen
  lots <- NULL; adopted <- list(); spb_used1 <- 0; year1 <- NULL
  if (inherits(start_value, "SimLevResult")) {
    y1 <- start_value$tax_report$next_year$year             # Kalenderjahr des ersten Planjahres (Tarifweg)
    if (is.numeric(y1) && length(y1) == 1L && is.finite(y1)) year1 <- as.integer(y1)
    acc <- result_index(start_value)
    sv <- utils::tail(acc$worth, 1)
    if (!is.finite(sv) || sv <= 0) {
      debt <- start_value$tax_report$open_tax_debt %||% 0
      stop(sprintf("start_value: Endwert der Ansparphase (SimLevResult) ist %s EUR; withdrawal_simulation() braucht ein positives Startverm\u00f6gen%s.",
                   sprintf("%.2f", sv), if (is.finite(debt) && debt > 0)
                     sprintf(" (offene, nicht gedeckte Steuerschuld der Ansparphase: %s EUR, tax_report$open_tax_debt)", sprintf("%.2f", debt)) else ""))
    }
    # offene Lots am letzten Tag (nur Ergebnisse mit tax_mode = "person"; aeltere Ergebnisse ohne)
    ol <- start_value$open_lots
    has_lots <- length(ol) > 0L && all(vapply(ol, function(a) is.data.frame(a$lots) &&
                                                all(c("units", "price", "vp") %in% names(a$lots)) && is.numeric(a$cash), TRUE))
    cb_given <- !missing(cost_basis)
    if (!cb_given) {
      held <- vapply(start_value$report, function(a) utils::tail(as.numeric(a$worth), 1), numeric(1))
      if (length(held) && all(is.finite(held)) && all(held == 0)) {
        # am letzten Tag kein Bestand mehr (nur Cash, z. B. liquidate = TRUE): alle Gewinne
        # sind bereits realisiert und versteuert -> Anschaffungskosten = Startwert
        cost_basis <- 100
      } else if (has_lots) {
        # exakt: Anschaffungskosten der offenen Lots (Briefkurs inkl. Ordergebuehr, wie in der
        # FIFO-Rechnung der Engine) plus bereits versteuerte, nach § 19 InvStG anzurechnende
        # Vorabpauschalen plus Cash (Basis = Betrag), bezogen auf den Endwert
        basis <- sum(vapply(ol, function(a) sum(a$lots$units * a$lots$price) + sum(a$lots$vp) + a$cash, numeric(1)))
        cost_basis <- 100 * basis / sv
        # FIFO: die Lots selbst gehen in die Entnahmephase (nur mit Steuern wirksam)
        if (tax_mode == "person") lots <- .wd_lots(ol, start_value$report, sv)
      } else {
        if (tax_mode == "person")
          warning("cost_basis: N\u00e4herung 100 x (Startwert brutto + Einzahlungen) / Endwert, da das Ansparergebnis keine offenen Lots ",
                  "enth\u00e4lt (simulation() ohne tax = tax_profile() oder \u00e4lteres Ergebnis); realisierte Gewinne und Cash z\u00e4hlen dabei ",
                  "als stille Reserven. F\u00fcr genaue Werte die Ansparphase mit tax = tax_profile() rechnen oder cost_basis angeben.")
        # Naeherung: Startbetrag brutto (vor Kaufkosten des Starttags) wie x$invested der Engine
        # plus Einzahlungen, bezogen auf den Endwert (realisierte, versteuerte Gewinne und Cash
        # werden dabei nicht abgezogen)
        start_gross <- if (length(start_value$invested)) start_value$invested[1] else acc$worth[1]
        invested <- start_gross + sum(pmax(acc$flows[-1], 0))
        cost_basis <- 100 * invested / sv
      }
    }
    # Die Entnahmephase kennt nur einen Bestand mit einer Teilfreistellung (partial_exemption) und
    # Abgeltungsteuer: einheitliche Werte der gehaltenen Assets uebernehmen, sonst melden
    if (tax_mode == "person" && has_lots) {
      hold <- ol[.wd_held(ol, start_value$report, sv)]            # gehalten = Endwert > 0 (nicht nur Stueckreste)
      reg <- vapply(hold, function(a) as.character(a$regime %||% "investment_fund"), "")
      # Vorabpauschale gibt es nur bei Investmentfonds: ohne Fonds keine; gemischt nicht abbildbar
      fund <- reg == "investment_fund"
      mixed <- any(fund) && any(!fund)
      if (length(hold) && !any(fund) && missing(vorabpauschale)) { vorabpauschale <- FALSE; adopted$vorabpauschale <- FALSE }
      if (mixed)
        warning(sprintf(paste0("Am Ende gehaltene Assets mit verschiedenen Regimen (Investmentfonds: %s; andere: %s): ",
                               "withdrawal_simulation() wendet Vorabpauschale (vorabpauschale = %s) und Teilfreistellung ",
                               "(partial_exemption = %g %%) auf den ganzen Bestand an; beide werden nicht \u00fcbernommen."),
                        paste(names(hold)[fund], collapse = ", "), paste(names(hold)[!fund], collapse = ", "),
                        isTRUE(vorabpauschale), partial_exemption))
      if (any(reg == "private_sale"))
        warning(sprintf(paste0("Assets mit Regime 'private_sale' (Paragraf 23 EStG: %s) am Ende der Ansparphase: Spekulationsfrist und ",
                               "Freigrenze bildet withdrawal_simulation() nicht ab; deren Gewinne werden wie Fondsgewinne mit ",
                               "Teilfreistellung partial_exemption = %g %% besteuert."), paste(names(hold)[reg == "private_sale"], collapse = ", "),
                        partial_exemption))
      fs <- reg != "private_sale"
      tfs <- ifelse(reg == "investment_fund", vapply(hold, function(a) as.numeric(a$partial_exemption %||% 0), 0), 0)[fs]
      if (missing(partial_exemption) && !mixed && length(tfs) && all(fs) && all(abs(tfs - tfs[1]) < 1e-9)) {
        partial_exemption <- unname(tfs[1]); adopted$partial_exemption <- partial_exemption
      } else if (!mixed && length(tfs) && any(abs(tfs - partial_exemption) > 1e-9))
        warning(sprintf(paste0("partial_exemption = %g %%, aber die am Ende gehaltenen Assets haben die Teilfreistellung %s; ",
                               "withdrawal_simulation() rechnet mit einer Teilfreistellung f\u00fcr den ganzen Bestand ",
                               "(partial_exemption passend angeben; bei verschiedenen Werten keine exakte Abbildung)."),
                        partial_exemption, paste(sprintf("%s %g %%", names(hold)[fs], tfs), collapse = ", ")))
      # Steuerzustand des Jahres nach dem letzten Datentag (= erstes Planjahr): was die Engine diesem Jahr
      # schon zugerechnet hat (am 31.12. festgesetzte Vorabpauschale: Pauschbetrag und Verlusttopf)
      ny <- start_value$tax_report$next_year
      num1 <- function(v) is.numeric(v) && length(v) == 1L && is.finite(v) && v >= 0
      # Verlusttopf (Paragraf 20, nach Teilfreistellung): zu Beginn des ersten Planjahres, sonst am Ende der Ansparphase
      lc <- if (is.list(ny) && num1(ny$loss_carryforward_capital)) ny$loss_carryforward_capital
            else start_value$tax_report$loss_carryforward_capital
      if (missing(loss_carryforward) && num1(lc)) {
        loss_carryforward <- lc; adopted$loss_carryforward <- lc
      }
      if (is.list(ny) && num1(ny$sparer_pauschbetrag_used)) spb_used1 <- ny$sparer_pauschbetrag_used
      # Verkaufskosten = halber Spread, wenn alle gehaltenen Assets denselben Spread haben (Feld spread)
      spr <- vapply(hold, function(a) if (is.numeric(a$spread) && length(a$spread) == 1L) a$spread else NA_real_, 0)
      if (missing(sale_cost) && length(spr) && !anyNA(spr)) {
        if (all(abs(spr - spr[1]) < 1e-12)) { sale_cost <- unname(spr[1]) / 2; adopted$sale_cost <- sale_cost }
        else warning(sprintf(paste0("sale_cost nicht \u00fcbernommen: die gehaltenen Assets haben verschiedene Spreads (%s); ",
                                    "withdrawal_simulation() rechnet mit einem Verkaufskostensatz f\u00fcr den ganzen Bestand (sale_cost angeben)."),
                             paste(sprintf("%s %g %%", names(hold), spr), collapse = ", ")))
      }
      fee_set <- vapply(hold, function(a) .wd_fee_set(a$order_fee), TRUE)
      if (any(fee_set))
        warning(sprintf(paste0("Ordergeb\u00fchren der Ansparphase (%s) bildet withdrawal_simulation() beim Verkauf nicht ab; ",
                               "gegebenenfalls in sale_cost (Prozent des Verkaufsbetrags) ber\u00fccksichtigen."),
                        paste(names(hold)[fee_set], collapse = ", ")))
    }
    if (spb_used1 > 0) adopted$sparer_pauschbetrag_used_year1 <- spb_used1
    if (!is.null(lots)) adopted$lots <- length(lots$n)
    else if (!cb_given && tax_mode == "person") adopted$cost_basis <- cost_basis
    if (length(adopted))
      message("Hinweis: aus der Ansparphase \u00fcbernommen: ",
              paste(vapply(names(adopted), function(k) switch(k, lots = sprintf("%d Lots (FIFO)", adopted[[k]]),
                                                              sprintf("%s = %s", k, if (is.logical(adopted[[k]])) adopted[[k]]
                                                                      else format(signif(adopted[[k]], 8)))), ""),
                    collapse = ", "), ".")
    start_value <- sv
  }
  if (!is.numeric(start_value) || length(start_value) != 1L || !is.finite(start_value) || start_value <= 0)
    chk_stop("ut2.start_value", "withdrawal_simulation")
  # Renditequellen aus simulation()/bootstrap_study()
  src_taxed <- FALSE
  if (inherits(x, "SimLevResult")) {
    src_taxed <- isTRUE(x$tax_report$total_taxes_paid > 0)
    if (!is.numeric(inflation) || length(inflation) != 1L) chk_stop("rs.infl_prozent", "withdrawal_simulation", "SimLevResult")
    x <- withdrawal_cohorts(x, inflation = inflation, years = years %||% 30, frequency = frequency)
  } else if (inherits(x, "SimLevWrapperNav")) {   # Anteilswert eines Fonds-Wrappers (wrapper_nav()) als Kursreihe
    if (!is.numeric(inflation) || length(inflation) != 1L) chk_stop("rs.infl_prozent", "withdrawal_simulation", "SimLevWrapperNav")
    x <- withdrawal_cohorts(x, price = "nav", inflation = inflation, years = years %||% 30, frequency = frequency)
  } else if (is.data.frame(x) && "date" %in% names(x)) {   # Kurstabelle, z. B. Ausschnitt aus wrapper_nav()
    stop(paste0("x ist eine Tabelle mit Spalte 'date' (z. B. ein Ausschnitt aus wrapper_nav(), der eine gew\u00f6hnliche ",
                "Tabelle ist); Kurse zuerst mit withdrawal_cohorts(x, price = \"<Kursspalte>\") in Renditen umwandeln ",
                "oder das ganze Ergebnis von wrapper_nav() \u00fcbergeben."))
  } else if (inherits(x, "SimLevBootstrapStudy") || (is.list(x) && length(x) && all(vapply(x, inherits, TRUE, "SimLevResult")))) {
    if (is.list(x) && !inherits(x, "SimLevBootstrapStudy"))
      src_taxed <- any(vapply(x, function(r) isTRUE(r$tax_report$total_taxes_paid > 0), TRUE))
    x <- withdrawal_paths(x, strategy = strategy, inflation = inflation, frequency = frequency)
  }
  if (src_taxed && tax_mode == "person" && isTRUE(vorabpauschale))
    warning("Das Quellergebnis wurde mit Steuern gerechnet (Vorabpauschale im Index enthalten); ",
            "vorabpauschale = FALSE oder eine Quelle ohne Steuern (simulation(tax = NULL)) vermeidet Doppelz\u00e4hlung.")
  if (!inherits(x, "withdrawal_paths")) {
    R <- if (is.null(x)) NULL else as.matrix(x)                  # NULL: seit 1.6.4 Meldung (bisher R-Rohfehler)
    # Feld mit mehr als zwei Dimensionen: seit 1.6.4 abgelehnt (bisher von as.matrix still zu einer Spalte gemacht)
    if (is.null(R) || !is.numeric(R) || !length(R) || length(dim(x)) > 2L)
      chk_stop("ut2.wd_x", "withdrawal_simulation")
    if (any(R < 0, na.rm = TRUE)) chk_stop("ut2.wd_brutto", "withdrawal_simulation")
    if (anyNA(R)) chk_stop("rs.na", "withdrawal_simulation")              # seit 1.6.4 vor dem Median (bisher R-Rohfehler)
    if (stats::median(R) < 0.5) chk_stop("ut2.wd_brutto", "withdrawal_simulation")
    if (is.matrix(inflation) && !identical(dim(inflation), dim(R)))
      chk_stop("rs.infl_dim", "withdrawal_simulation", nrow(R), ncol(R), nrow(inflation), ncol(inflation))
    if (if (is.matrix(inflation)) !is.numeric(inflation) else (!is.numeric(inflation) || length(inflation) != 1L || !is.finite(inflation)))
      chk_stop("ut2.wd_inflation", "withdrawal_simulation")
    I <- if (is.matrix(inflation)) inflation else matrix((1 + inflation / 100)^(1 / .wd_ppy(frequency)), nrow(R), ncol(R))
    x <- structure(list(returns = R, inflation = I, cape = NULL, base_rate = NULL, frequency = frequency,
                        historical = FALSE, start_dates = NULL, weights = NULL, source = "matrix"),
                   class = "withdrawal_paths")
  }
  if (isTRUE(.wd_reuse$on)) .wd_reuse$x <- x   # withdrawal_max_rate: aufbereitete Quelle fuer die weiteren Suchschritte
  ppy <- .wd_ppy(x$frequency)
  R <- x$returns; I <- x$inflation
  if (!is.matrix(R) || !nrow(R) || !ncol(R)) chk_stop("rs.keine_renditen", "withdrawal_simulation")
  if (anyNA(R) || anyNA(I)) chk_stop("rs.na", "withdrawal_simulation")
  if (!identical(dim(I), dim(R))) chk_stop("rs.infl_passt", "withdrawal_simulation", nrow(I), ncol(I), nrow(R), ncol(R))
  if (is.matrix(base_rate) && is.null(x$base_rate) && !identical(dim(base_rate), dim(R)))
    chk_stop("rs.base_dim", "withdrawal_simulation", nrow(R), ncol(R), nrow(base_rate), ncol(base_rate))
  if (!is.null(years)) {                                     # ganze Jahre (oben geprueft): ganze Zahl von Perioden
    keep_rows <- seq_len(min(nrow(R), round(years * ppy)))
    R <- R[keep_rows, , drop = FALSE]; I <- I[keep_rows, , drop = FALSE]
    if (!is.null(x$cape)) x$cape <- x$cape[keep_rows, , drop = FALSE]
    if (!is.null(x$base_rate)) x$base_rate <- x$base_rate[keep_rows, , drop = FALSE]
    if (is.matrix(base_rate)) base_rate <- base_rate[keep_rows, , drop = FALSE]
  }
  if (nrow(R) %% ppy != 0) warning("Periodenzahl ist kein Vielfaches eines Jahres; letztes Planjahr unvollst\u00e4ndig.")
  ny <- ceiling(nrow(R) / ppy)
  nfy <- nrow(R) %/% ppy                                    # volle Planjahre (ohne Rumpfjahr)
  if (rule$type == "cape" && is.null(x$cape)) chk_stop("rs.cape", "withdrawal_simulation")
  CAPE <- if (!is.null(x$cape)) as.matrix(x$cape) else matrix(0, nrow(R), 0)
  BASE <- if (!is.null(x$base_rate)) as.matrix(x$base_rate)
          else if (is.matrix(base_rate)) base_rate else matrix(base_rate, nrow(R), ncol(R))
  # Werte der Reihen (seit 1.6.4): Renditen endlich, Inflation als Brutto-Faktor endlich und > 0, CAPE und Basiszins
  # ohne NA (Entscheidung 17; bis 1.6.3 rechnete der Kern NA als 0 bzw. "nur cape_a")
  chk_nona(CAPE, fn, "cape", chk_msg("hinweis.cape"))
  chk_nona(BASE, fn, "base_rate", chk_msg("hinweis.basiszins"))
  if (any(!is.finite(R))) chk_stop("e3.werte", fn, "x (Renditen)")
  if (any(!is.finite(I) | I <= 0)) chk_stop("e3.werte_bereich", fn, "inflation (Brutto-Faktoren je Periode)", chk_msg("bereich.gt", "0"))
  inc <- rep(0, ny)
  for (e in income) {
    s0 <- e$start %||% 1; e0 <- e$end %||% Inf                # ohne end: bis zum Pfadende
    # seit 1.6.4 start ein ganzes Planjahr >= 1 (Entscheidung 44; bis 1.6.3 lief start = Inf als "nie" und start <= 0 als
    # Planjahr 1; kein Einkommen: Eintrag weglassen)
    if (!(is.numeric(s0) && length(s0) == 1L && is.finite(s0) && s0 == trunc(s0) && s0 >= 1))
      chk_stop("n2.einkommen_start", fn)
    # seit 1.6.4 ganze Planjahre (Entscheidung 19; bis 1.6.3 start auf- und end abgerundet), end auch Inf
    # (start ist nach der ersten Pruefung ein ganzes Planjahr >= 1; seit 1.6.4 K43 T2-N8 prueft die zweite nur end)
    if (!is.numeric(e0) || length(e0) != 1L || is.na(e0) || e0 < s0 || (is.finite(e0) && e0 != trunc(e0)))
      stop("income: start und end m\u00fcssen Planjahre mit start <= end sein.")
    s1 <- max(1, ceiling(s0)); e1 <- min(ny, floor(e0))
    if (s1 <= e1) inc[s1:e1] <- inc[s1:e1] + e$amount      # Einkommen nach Pfadende wirkt nicht
  }
  rp <- .wd_param_vector(rule)
  kp <- min(kp, ncol(R))
  # Tarifweg: zvE je Planjahr (nominal wie angegeben; income zaehlt nicht dazu) und Tarif wie in simulation()
  tariff_par <- zve <- numeric(0)
  if (tariff_on) {
    zve <- .wd_zve(tax$income$taxable_income, ny, year1)
    tt <- tax$income$tariff %||% tax_tariff()
    ck <- if (!is.null(tax$church_tax) && tax$church_tax > 0) tax$church_tax / 100 else 0
    tariff_par <- .wd_tariff_par(tt, ck, tax$guenstigerpruefung)
  }
  t0 <- Sys.time()
  core <- .wd_simulate(R, I, CAPE, BASE, as.integer(ppy), .wd_rules[[rule$type]], rp, timing == "start",
                       start_value, inc, tax_mode == "person", tax_rate, partial_exemption / 100,
                       sparer_pauschbetrag, isTRUE(vorabpauschale), sale_cost / 100, cost_basis / 100,
                       loss_carryforward, kp > 0 || !is.null(horizon),
                       lots$n %||% numeric(0), lots$basis %||% numeric(0), lots$vp %||% numeric(0), lots$group %||% integer(0),
                       if (spb_used1 > 0) max(0, sparer_pauschbetrag - spb_used1) else -1, !is.null(horizon),
                       tariff_par, zve)
  sp <- core$spending
  w0 <- sp[1, ]
  # Konsumkennzahlen je Pfad im Kern (wd_metrics): je Jahr nur ueber volle Planjahre (ein Rumpfjahr zaehlt nicht
  # als volles Jahr); Mittel, Minimum, Drawdown der Entnahmen max(1 - c / cummax(c)), Sicherheitsaequivalent mit
  # pmax(c, 1e-9 start_value) (gamma = 1: geometrisches Mittel), Summe
  # seit 1.6.4 (A-092) mit horizon nicht fuer den vollen Zeitraum (die fuenf Spalten werden unten mit den Kennzahlen bis
  # zum Horizont ersetzt; bis 1.6.3 hier gerechnet und verworfen); die volle PWR bleibt (Pruefung, Fehler wie bisher)
  mt <- if (is.null(horizon)) .wd_metrics(sp, nfy, NULL, gamma, start_value) else {
    na_ <- rep(NA_real_, ncol(sp))
    list(mean_spending = na_, min_spending = na_, spending_drawdown = na_, ce_spending = na_, total_spending = na_)
  }
  pwr <- if (ppy == 1L || nrow(R) >= ppy) withdrawal_perfect_rate(.annual_real(list(returns = R, inflation = I, frequency = x$frequency))) else NA
  paths <- data.frame(
    success = core$failed == 0,
    depletion_year = ceiling(core$depletion_period / ppy),
    terminal_real = core$terminal_real,
    terminal_nominal = core$terminal_nominal,
    first_withdrawal = w0,
    mean_spending = mt$mean_spending,
    min_spending = mt$min_spending,
    spending_drawdown = mt$spending_drawdown,
    ce_spending = mt$ce_spending,
    total_spending = mt$total_spending,
    taxes = core$taxes_real,
    pwr = pwr)
  if (!is.null(x$start_dates)) paths$start <- x$start_dates
  if (!is.null(horizon)) {
    H <- .draw_horizon(horizon, ncol(R))
    if (max(H) > ny) {
      warning(sprintf("Horizont bis %d Jahre, Pfade nur %d Jahre: l\u00e4ngere Horizonte werden auf %d gek\u00fcrzt.", max(H), ny, ny))
      H <- pmin(H, ny)
    }
    dy <- ceiling(core$depletion_period / ppy)
    paths$success_full <- paths$success
    paths$horizon <- H
    paths$success <- is.na(dy) | dy > H
    paths$depletion_year <- ifelse(!is.na(dy) & dy <= H, dy, NA)
    # Endvermoegen und Steuern beim Horizont einschliesslich der Abrechnung der Vorabpauschale des Jahres H
    # (wie am Pfadende): ein H-jaehriger Pfad und Horizont H auf laengeren Pfaden ergeben dasselbe
    paths$terminal_real <- core$wealth_end[cbind(H + 1L, seq_along(H))]
    paths$taxes <- core$taxes_end[cbind(H + 1L, seq_along(H))]
    mt <- .wd_metrics(sp, nfy, H, gamma, start_value)
    paths$mean_spending <- mt$mean_spending; paths$min_spending <- mt$min_spending
    paths$total_spending <- mt$total_spending
    paths$spending_drawdown <- mt$spending_drawdown; paths$ce_spending <- mt$ce_spending
    if (ppy == 1L) {
      AR <- .annual_real(list(returns = R, inflation = I, frequency = x$frequency))
      pc <- .wd_pwr(AR, 0, H)                             # PWR je Pfad bis zum Horizont (Pruefung je Pfad)
      if (pc$status) {                                    # erster ungueltige Pfad: Fehler wie bisher
        i <- pc$path
        withdrawal_perfect_rate(AR[seq_len(H[i]), i, drop = FALSE])
      }
      paths$pwr <- pc$pwr
    } else paths$pwr <- NA_real_
    if (kp == 0) core$wealth <- NULL
  }
  w <- x$weights %||% rep(1, ncol(R))
  out <- list(paths = paths, spending = sp, planned = core$planned,
              wealth = if (kp == 0) NULL else if (kp < ncol(core$wealth)) core$wealth[, seq_len(kp), drop = FALSE] else core$wealth,
              rule = rule, start_value = start_value, frequency = x$frequency, years = ny, full_years = nfy, horizon = horizon,
              historical = isTRUE(x$historical), weights = w, tax_mode = tax_mode, gamma = gamma,
              timing = timing, source = x$source, adopted = if (length(adopted)) adopted else NULL,
              elapsed = as.numeric(difftime(Sys.time(), t0, units = "secs")))
  if (tariff_on) out$tariff_years <- .wd_tariff_years(core$tariff_years, ny)
  class(out) <- "SimLevWithdrawal"
  out
}

# withdrawal_max_rate: Merker fuer die aufbereitete Renditequelle des ersten Suchschritts (seit 1.6.3)
.wd_reuse <- new.env(parent = emptyenv())

#' Maximale Anfangsrate fuer eine Ziel-Erfolgsquote
#'
#' Bestimmt per Bisektion die hoechste Entnahmerate (\code{rate} der Regel),
#' bei der der (mit den Pfadgewichten gewichtete) Anteil erfolgreicher Pfade
#' mindestens \code{success} betraegt. Fuer die konstante Regel ohne Steuern
#' und Einkommen entspricht das dem Quantil der Perfect Withdrawal Rate
#' (historisch: Minimum ueber alle Kohorten = SWR). Jeder Suchschritt ruft
#' [withdrawal_simulation()] mit \code{keep_paths = FALSE} auf.
#'
#' @param x Renditequelle wie in [withdrawal_simulation()]:
#'   \code{withdrawal_paths} (z. B. aus [withdrawal_cohorts()],
#'   [withdrawal_paths()], [bootstrap_pooled()]), Renditematrix,
#'   \code{SimLevResult}, Liste von \code{SimLevResult} oder
#'   \code{SimLevBootstrapStudy}.
#' @param rule Objekt aus [withdrawal_rule()]; dessen \code{rate} wird
#'   variiert (Standard: \code{withdrawal_rule("constant")}). Nur fuer
#'   Regeln, die \code{rate} nutzen; bei \code{one_over_n}, \code{vpw},
#'   \code{abw}, \code{cape} und \code{hebeler} bricht die Funktion ab.
#' @param success Ziel-Erfolgsquote als Anteil (0.95 = 95 % der Pfade,
#'   Standard); 1 = historische SWR. Zulaessig 0 < success <= 1 (95 statt
#'   0.95 ist ein Fehler).
#' @param lower,upper Suchintervall fuer \code{rate} in Prozent (Standard 0.5
#'   und 20).
#' @param tol Genauigkeit in Prozentpunkten (Standard 0.005; > 0). Es muss
#'   0 <= lower < upper <= 100 gelten.
#' @param ... weitere Argumente fuer [withdrawal_simulation()] (z. B.
#'   \code{inflation}, \code{tax}, \code{horizon}). Ein \code{horizon} aus
#'   [withdrawal_horizon()] mit \code{seed = NULL} wird einmal zu einem Startwert aufgeloest
#'   (ein Zug aus dem Zufallszustand von SimLev, [simlev_seed()]); alle Suchschritte vergleichen
#'   damit dieselben Laufzeiten.
#'   Seit 1.6.4 meldet ein unbekanntes Argument oder keep_paths (setzt die Funktion selbst) einen Fehler vor der
#'   Suche.
#' @return Rate in Prozent (Zahl; 4 = 4 %) mit Attribut \code{"success"}
#'   (erreichte Erfolgsquote als Anteil). \code{NA}, wenn schon \code{lower}
#'   die Zielquote verfehlt; \code{upper}, wenn selbst \code{upper} sie
#'   erreicht.
#' @seealso [withdrawal_simulation()], [withdrawal_perfect_rate()],
#'   [withdrawal_rule()]
#' @examples
#' set.seed(1)
#' R <- matrix(exp(rnorm(30 * 200, 0.05, 0.15)), 30)    # 30 Jahre, 200 Pfade
#' withdrawal_max_rate(R, withdrawal_rule("constant"), success = 0.9, inflation = 2)
#' @export
withdrawal_max_rate <- function(x, rule = withdrawal_rule("constant"), success = 0.95,
                                lower = 0.5, upper = 20, tol = 0.005, ...) {
  # seit 1.6.4 (Entscheidung 21): Argumente in ... vor der Suche pruefen (bis 1.6.3 Meldung des R-Interpreters, in
  # Python TypeError, in Julia MethodError); keep_paths setzt withdrawal_max_rate() selbst
  chk_dots(names(list(...)) %||% character(0), .wmr_args, "withdrawal_max_rate", taken = "keep_paths")
  if (!inherits(rule, "withdrawal_rule")) chk_stop("klasse", "withdrawal_max_rate", "rule", "withdrawal_rule()")
  if (rule$type %in% c("one_over_n", "vpw", "abw", "cape", "hebeler"))
    stop(sprintf("withdrawal_max_rate: Die Regel '%s' nutzt rate nicht; eine Suche \u00fcber rate ist daf\u00fcr nicht m\u00f6glich.", rule$type))
  num1 <- function(v) is.numeric(v) && length(v) == 1L && is.finite(v)
  if (!num1(success) || success <= 0 || success > 1)
    stop(sprintf("withdrawal_max_rate: success muss ein Anteil mit 0 < success <= 1 sein (0.95 = 95 %%)%s.",
                 if (num1(success) && success > 1 && success <= 100) "; Prozentangaben durch 100 teilen" else ""))
  if (!num1(lower) || !num1(upper) || lower < 0 || upper > 100 || lower >= upper)
    stop("withdrawal_max_rate: lower und upper m\u00fcssen Raten in Prozent mit 0 <= lower < upper <= 100 sein.")
  if (!num1(tol) || tol <= 0)
    stop("withdrawal_max_rate: tol muss eine Zahl > 0 in Prozentpunkten sein (z. B. 0.005).")
  # Ein Horizont mit seed = NULL wird einmal zu k aufgeloest; alle
  # Suchschritte ziehen damit dieselben Laufzeiten
  hz <- list(...)[["horizon"]]
  sim <- if (inherits(hz, "SimLevHorizon") && is.null(hz$seed) && !identical(hz$type, "fixed")) {
    hz$seed <- .sl_next_seed()
    function(x, rl, horizon, ...) withdrawal_simulation(x, rl, keep_paths = FALSE, horizon = hz, ...)
  } else function(x, rl, ...) withdrawal_simulation(x, rl, keep_paths = FALSE, ...)
  # Seit 1.6.3 bereitet nur der erste Suchschritt die Renditequelle auf (withdrawal_paths/withdrawal_cohorts aus einer
  # Studie bzw. einem Ergebnis); die weiteren rechnen mit dieser Aufbereitung (gleiche Renditen, Inflation, Gewichte)
  on.exit({ .wd_reuse$on <- FALSE; .wd_reuse$x <- NULL }, add = TRUE)
  first <- TRUE   # Hinweise und Warnungen (gleiche Eingaben) nur beim ersten Suchschritt
  f <- function(rate) {
    rl <- rule; rl$rate <- rate
    s <- if (first) {
      .wd_reuse$on <- TRUE; .wd_reuse$x <- NULL
      s1 <- sim(x, rl, ...)
      .wd_reuse$on <- FALSE
      if (!is.null(.wd_reuse$x)) x <<- .wd_reuse$x
      .wd_reuse$x <- NULL
      s1
    } else suppressWarnings(suppressMessages(sim(x, rl, ...)))
    first <<- FALSE
    stats::weighted.mean(s$paths$success, s$weights)
  }
  s_lo <- f(lower)                                  # jede Rate nur einmal simulieren
  if (s_lo < success) return(structure(NA_real_, success = s_lo))
  s_up <- f(upper)
  if (s_up >= success) return(structure(upper, success = s_up))
  while (upper - lower > tol) {
    mid <- (lower + upper) / 2
    # seit 1.6.4 (A-007): Ende, wenn die Mitte keine neue Zahl mehr ist (tol unter dem Abstand benachbarter Zahlen,
    # z. B. 1e-15); bis 1.6.3 lief die Suche dann endlos
    if (mid <= lower || mid >= upper) break
    s_mid <- f(mid)
    if (s_mid >= success) { lower <- mid; s_lo <- s_mid } else upper <- mid
  }
  structure(lower, success = s_lo)
}

#' Methoden fuer Entnahme-Objekte
#'
#' Ausgabe-, Zusammenfassungs- und Grafikmethoden fuer Entnahmeregeln
#' ([withdrawal_rule()]), Laufzeitmodelle ([withdrawal_horizon()]) und Ergebnisse
#' von [withdrawal_simulation()].
#'
#' \code{print()} einer Regel zeigt Typ und die von ihr genutzten Parameter; \code{print()}
#' eines \code{SimLevHorizon} fasst 20000 gezogene Laufzeiten zusammen (Mittel,
#' Median, 90-%-Quantil, Bereich). \code{summary()} eines Ergebnisses
#' berechnet (mit den Pfadgewichten gewichtet) Erfolgsquote, Anteil mit realem
#' Kapitalerhalt, Quantile von Endvermoegen, Konsum, Konsumrueckgang, Steuern
#' und PWR sowie die SWR (historisch: minimale PWR, sonst 5-%-Quantil der
#' PWR); \code{print()} eines Ergebnisses gibt diese Zusammenfassung aus.
#' \code{plot()} zeichnet Faecher des realen Vermoegens (falls gespeichert)
#' und des realen Jahreskonsums in Tausend (Startkaufkraft). Hat
#' \code{withdrawal_simulation(keep_paths = k)} nur die ersten k von n Pfaden
#' behalten, zeigt der Vermoegensfaecher diese k Pfade mit ihren Gewichten
#' (Titel \dQuote{Reales Vermoegen (erste k von n Pfaden)}); der Konsumfaecher
#' nutzt immer alle Pfade.
#'
#' @param x Ein \code{withdrawal_rule}-, \code{SimLevHorizon}-,
#'   \code{SimLevWithdrawal}- oder \code{summary.SimLevWithdrawal}-Objekt.
#' @param object Ein \code{SimLevWithdrawal}-Objekt.
#' @param probs Wahrscheinlichkeiten als Anteile (Standard
#'   \code{c(0.05, 0.25, 0.5, 0.75, 0.95)}): bei \code{summary()} die
#'   ausgewiesenen Quantile, bei \code{plot()} die Quantile der Faecher
#'   (Baender zwischen symmetrischen Quantilen, mittleres Quantil als Linie;
#'   seit 1.6.4 mindestens ein Wert, sonst Fehler).
#' @param ... Bei \code{plot()} weitere Argumente fuer [graphics::plot()];
#'   bei \code{print.SimLevWithdrawal()} an \code{summary()} weitergereicht;
#'   sonst ohne Wirkung.
#' @return \code{print()} und \code{plot()}: das Objekt (unsichtbar).
#'   \code{summary()}: Objekt der Klasse \code{summary.SimLevWithdrawal}
#'   (Liste) mit u. a. \code{success_rate} und \code{preserve_rate} (Anteile),
#'   \code{swr} (Prozent), Quantilvektoren (\code{terminal_real},
#'   \code{first_withdrawal}, \code{mean_spending}, \code{min_spending},
#'   \code{spending_drawdown} (Anteil), \code{ce_spending}, \code{taxes},
#'   \code{pwr} (Prozent), \code{depletion} (Jahre, nur gescheiterte Pfade)),
#'   \code{depletion_median} (seit 1.6.4: gewichteter Median der
#'   Erschoepfungsjahre als 0,5-Quantil, unabhaengig von \code{probs})
#'   und \code{spending_by_year} (Konsumquantile in Jahr 1, 10, 20, 30; je
#'   Jahr nur ueber Pfade, deren Horizont dieses Jahr einschliesst, und nur
#'   fuer volle Planjahre, sonst \code{NA}).
#' @name SimLevWithdrawal-methods
#' @keywords internal
NULL

#' @rdname SimLevWithdrawal-methods
#' @export
summary.SimLevWithdrawal <- function(object, probs = c(0.05, 0.25, 0.5, 0.75, 0.95), ...) {
  p <- object$paths; w <- object$weights
  wq <- function(v) .wquantile(v, w, probs)
  wm <- function(v) stats::weighted.mean(v, w, na.rm = TRUE)
  yrs <- object$years
  H <- p$horizon; nfy <- object$full_years %||% yrs
  pick <- function(y) {                                   # nur Pfade, deren Horizont Jahr y enthaelt; nur volle Jahre
    j <- if (is.null(H)) seq_len(ncol(object$spending)) else which(H >= y)
    if (y > nfy || !length(j)) rep(NA_real_, length(probs)) else .wquantile(object$spending[y, j], w[j], probs)
  }
  out <- list(
    rule = object$rule, n_paths = nrow(p), years = yrs, historical = object$historical,
    success_rate = wm(p$success),
    depletion = if (any(!p$success)) .wquantile(p$depletion_year[!p$success], w[!p$success], probs) else NULL,
    terminal_real = wq(p$terminal_real),
    preserve_rate = wm(p$terminal_real >= object$start_value),
    first_withdrawal = wq(p$first_withdrawal),
    mean_spending = wq(p$mean_spending), min_spending = wq(p$min_spending),
    spending_drawdown = wq(p$spending_drawdown), ce_spending = wq(p$ce_spending),
    spending_by_year = rbind(`Jahr 1` = pick(1), `Jahr 10` = pick(10), `Jahr 20` = pick(20), `Jahr 30` = pick(30)),
    taxes = wq(p$taxes), pwr = wq(p$pwr),
    swr = if (object$historical) min(p$pwr, na.rm = TRUE) else .wquantile(p$pwr, w, 0.05),
    probs = probs, start_value = object$start_value, tax_mode = object$tax_mode, gamma = object$gamma,
    # Median der Erschoepfungsjahre als 0,5-Quantil (seit 1.6.4, A-004; bis 1.6.3 das mittlere Element von probs)
    depletion_median = if (any(!p$success)) .wquantile(p$depletion_year[!p$success], w[!p$success], 0.5) else NULL)
  class(out) <- "summary.SimLevWithdrawal"
  out
}

#' @rdname SimLevWithdrawal-methods
#' @export
print.summary.SimLevWithdrawal <- function(x, ...) {
  # Fehlwert als Gedankenstrich, rechtsbuendig auf 10 Zeichen; nicht mit sprintf("%10s"), das bei %s
  # Bytes zaehlt (der Gedankenstrich hat in UTF-8 drei)
  q <- function(v, pct = FALSE) paste(vapply(v, function(z) if (is.na(z)) paste0(strrep(" ", 9L), "\u2013")
                                             else if (pct) sprintf("%9.2f%%", z) else sprintf("%10.0f", z), ""), collapse = "")
  hdr <- paste(sprintf("%10s", sprintf("q%02d", round(100 * x$probs))), collapse = "")
  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat("                 SimLev Entnahme-Simulation                    \n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n\n")
  cat(sprintf("  Regel:            %s\n", .wd_labels[[x$rule$type]]))
  cat(sprintf("  Pfade:            %d %s \u00fcber %d Jahre, Startverm\u00f6gen %.0f\n", x$n_paths,
              if (x$historical) "historische Kohorten" else "Pfade", x$years, x$start_value))
  cat(sprintf("  Steuern:          %s\n\n", if (x$tax_mode == "person") "deutsche Privatperson (vereinfacht)" else "keine"))
  cat(sprintf("  Erfolgsquote:     %.1f %% (Depot reicht f\u00fcr alle geplanten Entnahmen)\n", 100 * x$success_rate))
  cat(sprintf("  Kapitalerhalt:    %.1f %% (reales Endverm\u00f6gen >= Start)\n", 100 * x$preserve_rate))
  if (!is.null(x$depletion)) cat(sprintf("  Ersch\u00f6pfung:      Median im Jahr %.0f (bei gescheiterten Pfaden)\n", x$depletion_median))
  cat(sprintf("  %s: %.2f %% der Startsumme\n",
              if (x$historical) "SWR historisch (min. PWR)" else "SWR (5-%-Quantil PWR)", x$swr))
  cat(sprintf("\n  %s%s\n", format("real, in Startkaufkraft", width = 28), hdr))
  cat(sprintf("  %s%s\n", format("Endverm\u00f6gen", width = 28), q(x$terminal_real)))
  cat(sprintf("  %s%s\n", format("Entnahme Jahr 1", width = 28), q(x$first_withdrawal)))
  for (r in rownames(x$spending_by_year)) cat(sprintf("  %s%s\n", format(paste("Konsum", r), width = 28), q(x$spending_by_year[r, ])))
  cat(sprintf("  %s%s\n", format("Konsum Durchschnitt", width = 28), q(x$mean_spending)))
  cat(sprintf("  %s%s\n", format("Konsum Minimum", width = 28), q(x$min_spending)))
  cat(sprintf("  %s%s\n", format(sprintf("Sicherheits\u00e4quiv. (g=%g)", x$gamma), width = 28), q(x$ce_spending)))
  cat(sprintf("  %s%s\n", format("Max. Konsumr\u00fcckgang", width = 28), q(100 * x$spending_drawdown, TRUE)))
  cat(sprintf("  %s%s\n", format("PWR", width = 28), q(x$pwr, TRUE)))
  if (x$tax_mode == "person") cat(sprintf("  %s%s\n", format("Steuern gesamt", width = 28), q(x$taxes)))
  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  invisible(x)
}

#' @rdname SimLevWithdrawal-methods
#' @export
print.SimLevWithdrawal <- function(x, ...) { print(summary(x, ...)); invisible(x) }

#' @rdname SimLevWithdrawal-methods
#' @export
plot.SimLevWithdrawal <- function(x, probs = c(0.05, 0.25, 0.5, 0.75, 0.95), ...) {
  if (!length(probs)) chk_stop("fa.probs_leer", "plot")      # seit 1.6.4 (A-032; bis 1.6.3 R-Rohfehler)
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mfrow = c(1, if (is.null(x$wealth)) 1 else 2), mar = c(4, 4.6, 2.5, 1),
                mgp = c(2.9, 0.7, 0), las = 1)
  # keep_paths = k < Pfade: Vermoegensfaecher mit den Gewichten der behaltenen Spalten, Konsum mit allen
  fan <- function(M, main, xs, w = x$weights) {
    # Quantile x Jahre; bei einem Quantil liefert apply einen Vektor (seit 1.6.4 Matrix mit einer Zeile, A-032)
    Q <- matrix(apply(M, 1, function(r) .wquantile(r, w, probs)), nrow = length(probs)) / 1000
    plot(range(xs), range(Q, finite = TRUE), type = "n", xlab = "Jahr",
         ylab = "Tsd. (Startkaufkraft)", main = main, ...)
    k <- length(probs)
    cols <- grDevices::adjustcolor("#2C6E9B", alpha.f = 0.18)
    for (i in seq_len(floor(k / 2))) graphics::polygon(c(xs, rev(xs)), c(Q[i, ], rev(Q[k + 1 - i, ])), col = cols, border = NA)
    graphics::lines(xs, Q[ceiling(k / 2), ], col = "#2C6E9B", lwd = 2)
  }
  if (!is.null(x$wealth)) {
    k <- ncol(x$wealth); n <- ncol(x$spending)
    fan(x$wealth, if (k < n) sprintf("Reales Verm\u00f6gen (erste %d von %d Pfaden)", k, n) else "Reales Verm\u00f6gen",
        0:(nrow(x$wealth) - 1), x$weights[seq_len(k)])
  }
  fan(x$spending, "Realer Konsum je Jahr", seq_len(nrow(x$spending)))
  invisible(x)
}

#' Laufzeit der Entnahmephase nach eigenen Annahmen
#'
#' Beschreibt, wie lange die Entnahmephase dauern soll - fest oder als
#' Verteilung nach eigenen Vorgaben. Jeder Pfad von [withdrawal_simulation()]
#' erhaelt eine eigene Laufzeit, gezogen mit festem Startwert (gleiche
#' Laufzeiten bei wiederholten Aufrufen; mit \code{seed = NULL} je Aufruf
#' andere, ausser innerhalb von [withdrawal_max_rate()]).
#'
#' \describe{
#'   \item{fixed}{\code{years}: feste Laufzeit.}
#'   \item{uniform}{\code{min}, \code{max}: ganzzahlig gleichverteilt.}
#'   \item{discrete}{\code{years}, \code{prob}: eigene Wahrscheinlichkeiten je
#'     Laufzeit, z. B. \code{years = c(25, 30, 35, 40), prob = c(.3, .4, .2, .1)}.}
#'   \item{normal}{\code{mean}, \code{sd}, \code{min}, \code{max}: gerundet und
#'     auf \code{[min, max]} begrenzt.}
#'   \item{triangular}{\code{min}, \code{mode}, \code{max} mit
#'     \code{min <= mode <= max}.}
#'   \item{sample}{\code{years}: eigene Stichprobe von Laufzeiten, aus der mit
#'     Zuruecklegen gezogen wird.}
#' }
#'
#' Gezogene Laufzeiten sind ganze Jahre (bei \code{normal} und
#' \code{triangular} gerundet) und sind mindestens 1 Jahr. Laufzeiten ueber
#' der Pfadlaenge kuerzt [withdrawal_simulation()] mit Warnung. Die
#' Laufzeit-Parameter \code{years}, \code{min}, \code{max}, \code{mean} und
#' \code{mode} muessen > 0 sein (sonst Fehler); seit 1.6.4 sind \code{years}, \code{min}
#' und \code{max} ganze Zahlen von 1 bis 100 (vorher abgeschnitten).
#'
#' @param type Verteilung: \code{"fixed"} (Standard), \code{"uniform"},
#'   \code{"discrete"}, \code{"normal"}, \code{"triangular"} oder
#'   \code{"sample"} (siehe oben). Fehlende Pflichtparameter fuehren zu einem
#'   Fehler.
#' @param years Laufzeit(en) in Jahren: feste Laufzeit (\code{fixed}), moegliche
#'   Laufzeiten (\code{discrete}) bzw. Stichprobe (\code{sample}). Bei
#'   \code{discrete} und \code{sample} ist auch ein einzelner Wert erlaubt
#'   (dann immer diese Laufzeit).
#'   Seit 1.6.4 ganze Zahlen von 1 bis 100 (vorher wurden gebrochene Laufzeiten abgeschnitten).
#' @param prob \code{discrete}: Wahrscheinlichkeiten je Eintrag von
#'   \code{years} (gleiche Laenge, >= 0, Summe > 0; werden normiert).
#' @param min,max Untere und obere Grenze in Jahren (\code{uniform},
#'   \code{normal}, \code{triangular}); \code{min <= max}.
#'   Seit 1.6.4 ganze Zahlen von 1 bis 100.
#' @param mean,sd \code{normal}: Mittelwert und Standardabweichung in Jahren.
#' @param mode \code{triangular}: haeufigster Wert in Jahren.
#' @param seed Startwert fuer die Ziehung der Laufzeiten (Standard 1; ganze Zahl mit
#'   \eqn{|seed| < 2^{53}}); der Zufallszustand von SimLev bleibt dann unveraendert.
#'   \code{NULL} = bei jeder Ziehung wird genau einmal ein Startwert aus dem Zufallszustand von
#'   SimLev gezogen (siehe [simlev_seed()]), jede Ziehung ist anders; [withdrawal_max_rate()]
#'   loest \code{NULL} einmal auf und nutzt in allen Suchschritten dieselben Laufzeiten.
#'   \code{set.seed()} wirkt nicht.
#' @return Objekt der Klasse \code{SimLevHorizon} (Liste mit \code{type},
#'   \code{seed} und den benoetigten Parametern) zur Uebergabe an das
#'   Argument \code{horizon} von [withdrawal_simulation()] bzw.
#'   [withdrawal_max_rate()]. Ausgabe mit \code{print()} (siehe
#'   [SimLevWithdrawal-methods]).
#' @seealso [withdrawal_simulation()], [withdrawal_max_rate()]
#' @examples
#' h <- withdrawal_horizon("discrete", years = c(25, 30, 35, 40), prob = c(0.3, 0.4, 0.2, 0.1))
#' h
#' R <- matrix(exp(rnorm(40 * 500, 0.05, 0.15)), 40)
#' withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), inflation = 2, horizon = h)
#' @export
withdrawal_horizon <- function(type = c("fixed", "uniform", "discrete", "normal", "triangular", "sample"),
                          years = NULL, prob = NULL, min = NULL, max = NULL, mean = NULL, sd = NULL, mode = NULL,
                          seed = 1L) {
  .e3_choice(type, c("fixed", "uniform", "discrete", "normal", "triangular", "sample"), "withdrawal_horizon",
             "type")   # Pruefung (Meldung auswahl)
  type <- match.arg(type)
  need <- switch(type, fixed = "years", uniform = c("min", "max"), discrete = c("years", "prob"),
                 normal = c("mean", "sd", "min", "max"), triangular = c("min", "mode", "max"), sample = "years")
  given <- list(years = years, prob = prob, min = min, max = max, mean = mean, sd = sd, mode = mode)
  miss <- need[vapply(need, function(k) is.null(given[[k]]), TRUE)]
  if (length(miss)) stop(sprintf("withdrawal_horizon('%s') braucht: %s", type, paste(miss, collapse = ", ")))
  for (k in need) {
    v <- given[[k]]; multi <- k %in% c("prob") || (k == "years" && type %in% c("discrete", "sample"))
    if (!is.numeric(v) || !length(v) || any(!is.finite(v)) || (!multi && length(v) != 1L))
      chk_stop(if (multi) "e2.zahlen_endlich" else "zahl", sprintf("withdrawal_horizon('%s')", type), k)
  }
  # Laufzeiten in Jahren muessen positiv sein (0 oder negativ wurde still zu 1 Jahr)
  for (k in intersect(need, c("years", "min", "max", "mean", "mode"))) if (any(given[[k]] <= 0))
    chk_stop("ut2.laufzeit_pos", sprintf("withdrawal_horizon('%s')", type), k)
  # seit 1.6.4: Laufzeiten in ganzen Jahren (Entscheidung 19; bis 1.6.3 still abgeschnitten, 2.5 -> 2) und hoechstens
  # 100 Jahre (Entscheidung 46)
  fnt <- sprintf("withdrawal_horizon('%s')", type)
  for (k in intersect(need, c("years", "min", "max"))) {
    if (k == "years" && type %in% c("discrete", "sample")) chk_intvec(years, fnt, k) else chk_int1(given[[k]], fnt, k)
    chk_max(given[[k]], SL_MAX_JAHRE, fnt, k)
  }
  if (type == "discrete" && (length(years) != length(prob) || any(prob < 0) || sum(prob) <= 0))
    stop("withdrawal_horizon('discrete'): years und prob gleich lang, prob >= 0 mit Summe > 0.")
  if (!is.null(min) && !is.null(max) && min > max) chk_stop("rs.min_max", fnt)
  if (type == "triangular" && (mode < min || mode > max))
    chk_stop("ut2.mode", "withdrawal_horizon('triangular')")
  if (type == "normal" && sd < 0) chk_stop("ut2.sd", "withdrawal_horizon('normal')")
  if (!is.null(seed)) .sl_check_seed(seed, "withdrawal_horizon")                     # ganze Zahl, |seed| < 2^53
  structure(c(list(type = type, seed = seed), given[need]), class = "SimLevHorizon")
}

#' Laufzeiten ziehen
#' @keywords internal
#' @noRd
.draw_horizon <- function(h, n) {
  # Hauptstrom aus h$seed; "fixed" zieht nicht
  rs <- if (identical(h$type, "fixed")) NULL else .sl_main_stream(h$seed, "withdrawal_horizon")
  pick <- function(x, prob = NULL) x[.sl_sample(length(x), n, replace = TRUE, prob = prob, stream = rs)]   # auch bei Laenge 1 aus x
  out <- switch(h$type,
    fixed = rep(h$years, n),
    uniform = pick(seq(h$min, h$max)),
    discrete = pick(h$years, h$prob),
    normal = pmin(h$max, pmax(h$min, round(.sl_rnorm(n, h$mean, h$sd, stream = rs)))),
    triangular = { u <- .sl_runif(n, stream = rs); a <- h$min; b <- h$max; c <- h$mode
                   if (b == a) rep(a, n) else { f <- (c - a) / (b - a)
                   round(ifelse(u < f, a + sqrt(u * (b - a) * (c - a)), b - sqrt((1 - u) * (b - a) * (b - c)))) } },
    sample = pick(h$years))
  as.integer(pmax(1, out))
}

#' @rdname SimLevWithdrawal-methods
#' @export
print.SimLevHorizon <- function(x, ...) {
  d <- .draw_horizon(x, 20000)
  cat(sprintf("Laufzeit der Entnahmephase (%s): Mittel %.1f Jahre, Median %g, 90 %%-Quantil %g, Bereich %g bis %g\n",
              x$type, mean(d), stats::median(d), stats::quantile(d, 0.9, names = FALSE), min(d), max(d)))
  invisible(x)
}

#' Steuerangaben der Person fuer withdrawal_simulation() pruefen
#'
#' Zweck: tax = NULL (ohne Steuern) oder tax_profile(); die Entnahmephase wertet daraus rate, church_tax,
#' sparer_pauschbetrag, guenstigerpruefung und income = income_rate() (Satz ueber .tax_rates) bzw.
#' income_tariff() (Tarifweg: Veranlagung je Planjahr und Pfad im Kern) aus. Angaben, die sie nicht
#' abbildet (private_sale_threshold, base_rate, harvest), ergeben einen Fehler.
#' Ausgabe: "none" oder "person".
#' @keywords internal
#' @noRd
.wd_tax_mode <- function(tax) {
  if (is.null(tax)) return("none")
  if (!inherits(tax, "SimLevTaxProfile"))
    stop("withdrawal_simulation: tax muss NULL oder ein Objekt aus tax_profile() sein.", call. = FALSE)
  un <- c(private_sale_threshold = !identical(as.numeric(tax$private_sale_threshold), 1000),
          base_rate = !is.null(tax$base_rate), harvest = !is.null(tax$harvest))
  if (any(un))
    stop(sprintf("withdrawal_simulation: tax_profile(%s) bildet die Entnahmephase nicht ab; ausgewertet werden rate, church_tax, sparer_pauschbetrag, guenstigerpruefung und income = income_rate() oder income_tariff() (Basiszins \u00fcber base_rate von withdrawal_simulation()).",
                 paste(names(un)[un], collapse = ", ")), call. = FALSE)
  "person"
}

#' Jahreszeilen des Tarifwegs aus dem Kern als data.frame
#'
#' Eingabe: M (Matrix 25 x (ny + 1) Pfade: Zeilen wie die Spalten von tax_report$tariff_years in simulation(); Spalte
#' (Pfad - 1) (ny + 1) + Planjahr, Jahr NA = keine Veranlagung), ny.
#' Ausgabe: data.frame mit path, year (Planjahr) und den Spalten von tax_report$tariff_years, nach Pfad und Jahr.
#' @keywords internal
#' @noRd
.wd_tariff_years <- function(M, ny) {
  cols <- .TARIFF_YEAR_COLS
  C <- .wd_tariff_compact(M, ny)                          # Spalten mit Jahr NA entfallen (Kern)
  # seit 1.6.1 als Liste mit einem Aufbau (wie data.frame() und Spalte für Spalte, ohne dessen Kopien je Spalte)
  d <- c(list(path = as.integer(C[, 1L])), lapply(seq_along(cols), function(j) C[, j + 1L]))
  names(d) <- c("path", cols)
  d$year <- as.integer(d$year); d$guenstiger <- d$guenstiger != 0
  structure(d, row.names = .set_row_names(nrow(C)), class = "data.frame")
}

#' Tarifparameter fuer den Kern (core/tariff_core_impl.h)
#'
#' Eingabe: tt (Objekt aus tax_tariff()), church_k (church_tax / 100), use_gp (Guenstigerpruefung).
#' Ausgabe: Zahlenvektor use_gp, church_k, KapESt-Satz 0.25 / (1 + 0.25 k) (wie simulation()), Soli-Freigrenze,
#' -Satz, -Milderung, Zahl der Zonen, dann je Zone ab, bezug, teiler, a, b, c.
#' @keywords internal
#' @noRd
.wd_tariff_par <- function(tt, church_k, use_gp) {
  z <- tt$zones; s <- tt$soli
  c(as.numeric(isTRUE(use_gp)), church_k, 0.25 / (1 + 0.25 * church_k), s$freigrenze, s$satz, s$milderung,
    nrow(z), z$ab, z$bezug, z$teiler, z$a, z$b, z$c)
}

#' zvE je Planjahr fuer den Tarifweg der Entnahme
#'
#' Eingabe: x (taxable_income aus income_tariff()), ny (Planjahre), year1 (Kalenderjahr des ersten Planjahres
#' aus tax_report$next_year$year eines SimLevResult als start_value, sonst NULL).
#' Formen: eine Zahl gilt fuer alle Planjahre, ein Vektor ohne Namen braucht die Laenge ny; nach Kalenderjahren
#' benannt (Vektor, data.frame) nur mit year1 (Planjahr i = year1 + i - 1). Nominal wie angegeben.
#' Ausgabe: Zahlenvektor der Laenge ny + 1 (Planjahre und Folgejahr fuer die Abrechnung am Pfadende; NA = kein
#' zvE fuer das Folgejahr, dort dann keine Veranlagung, wie simulation()).
#' @keywords internal
#' @noRd
.wd_zve <- function(x, ny, year1 = NULL) {
  who <- "withdrawal_simulation"
  form <- sprintf("eine Zahl (zvE in EUR f\u00fcr alle Planjahre), ein Vektor ohne Namen mit einem Wert je Planjahr (L\u00e4nge %d)%s",
                  ny, if (is.null(year1)) "" else
                    sprintf(" oder nach Kalenderjahren benannt (Vektor bzw. data.frame mit den Spalten year und taxable_income; Planjahr 1 = %d)", year1))
  if (is.numeric(x) && !is.data.frame(x) && is.null(names(x))) {
    if (length(x) == 1L) return(rep(as.numeric(x), ny + 1L))
    if (length(x) == ny) return(c(as.numeric(x), NA_real_))
    stop(sprintf("%s: taxable_income (income_tariff()) hat %d Werte, die Entnahme %d Planjahre; erwartet wird %s.",
                 who, length(x), ny, form), call. = FALSE)
  }
  if (is.null(year1))
    stop(sprintf("%s: taxable_income (income_tariff()) nach Kalenderjahren l\u00e4sst sich nur mit einem SimLevResult als start_value auf Planjahre abbilden (Planjahr 1 = tax_report$next_year$year); erwartet wird %s.",
                 who, form), call. = FALSE)
  zv <- .check_taxable_income(x, seq.int(year1, length.out = ny), who = who)
  unname(zv$by_year[as.character(seq.int(year1, length.out = ny + 1L))])
}

# Argumente, die withdrawal_max_rate() in ... annimmt (seit 1.6.4, Entscheidung 21): die von withdrawal_simulation()
# ohne x, rule und keep_paths; beim Bau des Pakets festgelegt (wie _WMR_ARGS in Python und Julia)
.wmr_args <- setdiff(names(formals(withdrawal_simulation)), c("x", "rule", "keep_paths"))
