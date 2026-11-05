// core/engine_core_impl.h
// Tagesengine von simulation() als gemeinsamer C++-Kern: eigener Zustand, Ereignisprotokoll und
// Tagesschleife mit Abschluss des letzten Jahres: Batch- und Marktupdate, Aktivierung, Sparplan,
// Handel, Rebalancing und Liquidation; Steuerphasen (Jahreswechsel mit § 23, § 20-Erstattung und
// Tarif-Veranlagung samt Guenstigerpruefung ueber tariff_core_impl.h, Vorabpauschale mit Festsetzung am 31.12.
// und Zufluss im Folgejahr, § 23-Zahlung, Zahlungen mit Zwangsverkauf), Splits, Freibetrag (Harvest) und der
// Abschluss des letzten Jahres mit Probelauf; details-Ausgaben als Ereignisse mit Werten (DT_*). Der Kern
// rechnet alle Laeufe (R: .sim_engine_run in r/R/sim_engine.R, Python: simlev/_sim_engine.py, Julia:
// src/sim_engine.jl; die bis 1.3.0 eigenen Engines der Sprachen und ihre Engine-Kerne sind entfallen). Die
// Vorbereitung (Termine, Tagesflags, Startgewichte) rechnet prepare_core_impl.h vor dem Lauf (setup_prepared).
//
// Herkunft:           uebersetzt aus SimLev 1.3.0, r/R/sim_loop.R (.sim_run_days, .sim_day_activate,
//                     .sim_day_split, .sim_day_dca, .sim_day_trade, .sim_day_rebalance, .sim_day_harvest,
//                     .sim_day_assess_vp, .sim_day_liquidate, .sim_close_years), r/R/sim_actions.R
//                     (.buy_with_fee, .sell_count_net, .pay_one, .pay_tax, .pay_vp, .settle_p23, .settle_gp,
//                     .vp_taxes, .settle_vp), r/R/sim_base.R (.calculate_buy_signal, .calculate_sell_signal,
//                     .perform_trade_buy, .perform_trade_sell, .calculate_sell_count, .calculate_flat_rate,
//                     .handle_year_change, .tariff_close, .tariff_book, .book_tax_due, .perform_asset_split,
//                     .forward_asset_split, .reverse_asset_split, .perform_gain_harvest, .apply_spread,
//                     .fee_amount, .fee_volume) und core/simulation_core_impl.h, core/fifo_core_impl.h,
//                     core/tax_core_impl.h (Kerne mit Host-Objekten, hier auf eigenen Strukturen);
//                     Vorlage der Uebersetzung war der typisierte Julia-Port (julia/src/sim_loop.jl,
//                     engine.jl)
// Rechte:             SimLev (eigener Code)
// Lizenz der Vorlage: GPL-3 (SimLev)
// Aenderungen:        Zustand als C++-Strukturen statt benannter Listen (Assets als Index); Warnungen,
//                     Fehler und details-Ausgaben (cat) als Ereigniscodes mit Werten (Texte setzt der Host,
//                     in derselben Reihenfolge); Rechenfolge wie R.
//
// GEMEINSAME QUELLE FUER R, PYTHON UND JULIA: reine Rechnung ohne Host-Objekte (wie
// tariff_core_impl.h). R bindet sie ueber r/src/engine_core.cpp ein, Python ueber
// python/src/_ext_engine.cpp, Julia ueber core/simlev_cabi.cpp (simlev_c_engine_*). Alle drei fuellen
// dieselbe flache Eingabe (struct Input, Felder unten) und lesen die Ergebnisse ueber die Methoden *_out.
// Kanonisch in core/; R, Python und Julia bauen aus Byte-fuer-Byte-Kopien (core/sync.py --write/--check).
//
// Regeln (wie die uebrigen Engine-Kerne, simlev_core.h):
//   - Gleitkomma: kein fast-math, kein fma (-ffp-contract=off bzw. Pragma unten); Rechenreihenfolge wie
//     in R. Operationen, deren beide Operanden aus Eingaben stammen, ueber simlev_add/_sub/_mul/_div
//     (NA vor NaN).
//   - sum() rechnet R in long double: hier ueber sl_r_sum (core/slc_rbase.cpp) als bewusste, dokumentierte
//     Ausnahme von der Regel "kein long double" (gleich in allen drei Sprachen).
//   - Bedingungen mit NA: R bricht in if () mit "missing value where TRUE/FALSE needed" ab. Der Kern
//     rechnet jede solche Bedingung dreiwertig wie R (&&, ||, !) und bricht an derselben Stelle mit dem
//     Ereigniscode EV_NA_COND und der Stelle (site) ab; der Host loest den Fehler mit dem Text von R aus.
//   - Probelauf (Abschluss des letzten Jahres): Jahreswechsel und VP-Steuer auf Kopien von Toepfen und
//     Status; Warnungen und details-Ausgaben daraus werden verworfen (R: suppressWarnings, details = FALSE),
//     Abbrueche nicht. Bedingungen, die R nur mit details auswertet, prueft der Kern nur dann (det()).
//   - Reentrant: kein globaler Zustand; der ganze Lauf haengt an einem Engine-Objekt des Aufrufers.
//   - Die Signale nicht aktiver Assets setzt R am Aktivierungstag auf FALSE; das wirkt sich nicht aus
//     (gelesen werden nur Signale aktiver Assets am selben Tag) und entfaellt hier.

#ifndef SIMLEV_ENGINE_CORE_IMPL_H
#define SIMLEV_ENGINE_CORE_IMPL_H

#if defined(__FAST_MATH__)
#error "Gemeinsame Kerne duerfen nicht mit -ffast-math uebersetzt werden (Bitgleichheit)."
#endif
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#elif defined(_MSC_VER)
#pragma fp_contract (off)
#elif defined(__GNUC__) && (defined(__FP_FAST_FMA) || defined(__FP_FAST_FMAF)) && !defined(SIMLEV_FP_CONTRACT_BY_FLAG)
#pragma GCC optimize ("fp-contract=off")
#endif

#include "simlev_core.h"
#include "slc_rbase.h"
#include "tariff_core_impl.h"
#include "prepare_core_impl.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <initializer_list>
#include <utility>
#include <vector>

namespace simlev_engine {

// ── Tagesflags (Bitmaske je Tag; aus der Vorbereitung prepare_core_impl.h) ─────────────
enum DayFlag : uint32_t {
  F_SLOW = 1u << 0,        // flag_slow_path (TRUE)
  F_YEAR = 1u << 1,        // flag_year_change
  F_ACTIVE = 1u << 2,      // flag_active
  F_SPLIT = 1u << 3,       // flag_split
  F_DCA = 1u << 4,         // flag_dca
  F_TRADE = 1u << 5,       // flag_trade
  F_REBAL = 1u << 6,       // flag_rebalance
  F_HARVEST = 1u << 7,     // flag_harvest
  F_TAXES = 1u << 8,       // flag_taxes (31.12.)
  F_LIQ = 1u << 9,         // flag_liquidate
  F_EVENT = 1u << 10,      // flag_event
  F_VPSETTLE = 1u << 11,   // flag_vp_settle
  F_SLOWNA = 1u << 12,     // flag_slow_path ist NA (NA-Signal); nur am Jahreswechsel ein Einzeltag: Abbruch wie R
  F_FILLED = 1u << 13      // flag_filled (aufgefuellter Tag)
};

// ── Eingabe (flach, gleich fuer alle Hosts) ─────────────────────────────────────────────────────────
// Konfiguration als Ganzzahlen (ci) und Zahlen (cd), je Asset ai und ad, Toepfe zu Beginn (tot0)
enum CfgInt {
  CI_FRACTIONS = 0, CI_FEES_ON, CI_BALANCE_MODE, CI_BALANCE_DCA, CI_THRESH_SET, CI_THRESH_REL,
  CI_PERSON,          // tax_mode == "person"
  CI_USE_SPB,         // use_sparer_pauschbetrag
  CI_LOSS_POT,        // harvest_loss_pot
  CI_LIQUIDATE,       // liquidate
  CI_HAS_MARGINAL,    // marginal_tax_rate nicht NULL
  CI_STOPP_YEAR,      // Jahr von stopp_date
  CI_HAS_ZVE_ALL,     // Tarifweg: eine Zahl fuer alle Jahre (cd[CD_ZVE_ALL])
  CI_DETAILS,         // details = TRUE: details-Ausgaben als Ereignisse
  CI_N
};
enum CfgDbl {
  CD_BALANCE_THRESH = 0, CD_DCA_VALUE, CD_FEE_PAID0, CD_EFF_RATE, CD_MARGINAL, CD_PS_THRESHOLD, CD_SPB,
  CD_SOLI_FACTOR, CD_CHURCH_K, CD_SPLIT_LO, CD_SPLIT_HI, CD_ZVE_ALL, CD_N
};
enum AssetInt { AI_STYLE = 0, AI_START_IDX, AI_START_DAY, AI_INITIAL, AI_REGIME, AI_NO_SPLIT, AI_BUY_LGL, AI_SELL_LGL, AI_N };
enum AssetDbl { AD_SPREAD = 0, AD_SHARE, AD_BONUS, AD_N };
// Toepfe (sim_mem$totals; Reihenfolge der Ausgabe totals_out)
enum TotIdx {
  TT_TOTAL_TAXES = 0, TT_LOSS_CG, TT_LOSS_PS, TT_PS_GAINS, TT_PS_LOSSES, TT_SPB_ANNUAL, TT_SPB_REM, TT_SPB_USED,
  TT_CURRENT_YEAR, TT_CGT_BASE, TT_CGT_ADDED, TT_CGT_USED, TT_CGT_POOL_START, TT_N
};
// Steuerregime (fl$tax_regimes); 0 nur im Modus "none" (Verkaeufe ohne Steuerangaben)
enum Regime { RG_NONE = 0, RG_FUND = 1, RG_CG = 2, RG_PS = 3 };

struct Input {
  int64_t n = 0, na = 0;
  const int32_t* flags = nullptr;          // Tagesflags (n)
  const double* dca_n = nullptr;           // flag_dca_n (n)
  const double* day = nullptr;             // flag_date als Tageszahl (n)
  const double* const* price = nullptr;    // je Asset market$asset_price (n); der Kern rechnet auf Kopien
  const double* const* sig_buy = nullptr;  // je Asset Signal als double (logisch 0/1, NA)
  const double* const* sig_sell = nullptr;
  const double* const* event_w = nullptr;  // nullptr oder je Asset nullptr bzw. Spalte (n)
  const double* const* base_rates = nullptr;  // nullptr oder je Asset nullptr bzw. market$base_rates (n)
  const int32_t* ai = nullptr;             // AI_N je Asset
  const double* ad = nullptr;              // AD_N je Asset
  const double* st0 = nullptr;             // 8 je Asset (Status nach .sim_init_weights)
  const int32_t* ci = nullptr;             // CI_N
  const double* cd = nullptr;              // CD_N
  const double* fees = nullptr;            // 10: order (on, fixed, percent, min, max), dca (dito)
  const double* tot0 = nullptr;            // TT_N
  const double* tariff_par = nullptr;      // Tarifparameter (tariff_core_impl.h); Laenge 0 = kein Tarifweg
  int64_t n_tariff_par = 0;
  const double* zve = nullptr;             // Tarifweg: Paare (Jahr, zvE) ohne zve_all
  int64_t n_zve = 0;
  double* const* reports = nullptr;        // 5 je Asset: worth, money, flows, total, share (n); Tag 1 vorbelegt
};

// ── Ereigniscodes (Texte in den Hosts, wortgleich zu R) ────────────────────────────────────────────
enum EventCode : int {
  EV_BUY_PRICE = 1,     // Warnung perform_trade_buy: ungueltiger Kurs; d0 Kurs
  EV_SELL_EXCESS = 2,   // Warnung perform_trade_sell: Menge > Bestand; d0 Menge, d1 Bestand
  EV_LIQ_FEE = 3,       // Warnung liquidate: Position nicht verkauft; d0 Wert (worth)
  EV_MAX_EMPTY = 4,     // Warnung von max(deviations, na.rm = TRUE) ohne Werte
  EV_TAX_UNPAID = 5,    // Warnung .pay_tax: Depot reicht nicht; d0 Betrag, d1 offen; aux Bezeichnung (LBL_*), Jahre
  EV_MARGINAL = 6,      // Warnung .handle_year_change: marginal_tax_rate fehlt; d0 Jahressaldo, d1 Freigrenze
  EV_NA_COND = 100,     // Fehler: NA in einer Bedingung (site = Stelle)
  EV_SPLIT_RATIO = 101, // Fehler .perform_asset_split: ratio <= 0; d0 ratio
  // details-Ausgaben: Werte in ev_vals[v_off ..], Ganzzahlen (Asset-Indizes bzw. Jahre) in
  // ev_ints[y_off ..]; Texte in den Hosts wortgleich zu den bisherigen cat()-Aufrufen von R
  DT_BUY = 201,         // .perform_trade_buy: aux Anlass (RS_*); v: Menge, Preis
  DT_SELL_VP = 202,     // .perform_trade_sell: Vorabpauschale-Anrechnung; v: Betrag
  DT_SELL_SPB = 203,    // .perform_trade_sell: Sparerpauschbetrag; v: genutzt, verbleibend
  DT_SELL_EXG = 204,    // .perform_trade_sell: steuerfreier Gewinn; v: Betrag
  DT_SELL_EXL = 205,    // .perform_trade_sell: nicht verrechenbarer Verlust; v: Betrag
  DT_SELL_TXG = 206,    // .perform_trade_sell: steuerpflichtiger Gewinn; v: Betrag, seit Jahresbeginn
  DT_SELL_TXL = 207,    // .perform_trade_sell: verrechenbarer Verlust; v: Betrag, seit Jahresbeginn
  DT_SELL = 208,        // .perform_trade_sell: aux Anlass; v: Menge, Preis
  DT_SELL_GAIN = 209,   // .perform_trade_sell: Gewinn/Verlust und Steuer; v: Gewinn, Steuer
  DT_HARVEST = 210,     // .perform_gain_harvest; v: steuerpflichtiger Gewinn, Menge, Spielraum
  DT_SPLIT = 211,       // .perform_asset_split: aux 1 Split, 0 Reverse-Split; v: Verhaeltnis
  DT_SPLIT_FREE = 212,  // .sim_day_split ohne Bestand: aux 1 "1 :", 0 ": 1"; v: Verhaeltnis
  DT_ACTIVATE = 213,    // .sim_day_activate: ints neue Assets
  DT_DCA = 214,         // .sim_day_dca: v: Sparrate, Zufluesse je aktivem Asset; ints aktive Assets
  DT_REB_FORCE = 215,   // .sim_day_rebalance: erzwungen; ints neue Assets
  DT_REB_YES = 216,     // .sim_day_rebalance: v: max. Abweichung * 100, Schwelle * 100
  DT_REB_ASSET = 217,   // .sim_day_rebalance: v: Ziel * 100, Ist * 100, Abweichung * 100
  DT_REB_NO = 218,      // .sim_day_rebalance: v: max. Abweichung * 100, Schwelle * 100
  DT_REB_POOL_IN = 219, // .sim_day_rebalance: v: Betrag in den Topf
  DT_REB_ALLOC = 220,   // .sim_day_rebalance: v: Betrag aus dem Topf
  DT_REB_CASH = 221,    // .sim_day_rebalance: v: Cash-Reserve
  DT_REB_REST = 222,    // .sim_day_rebalance: v: Restverteilung
  DT_REB_REDIST = 223,  // .sim_day_rebalance: v: Anteil der Restverteilung
  DT_VP_ASSESS = 224,   // .sim_day_assess_vp: v: Vorabpauschale
  DT_PAY_CASH = 225,    // .pay_one: aux Bezeichnung (LBL_*), ints Jahre; v: Betrag
  DT_PAY_PART = 226,    // .pay_one: Teilzahlung; v: Betrag
  DT_PAY_SOLD = 227,    // .pay_one: Anteile verkauft; v: Betrag
  DT_P23_VERANL = 228,  // .settle_p23: aux Bit 0 Guenstigerpruefung-Rest, Bit 1 nach § 23-Saldo; v: Jahr, D, § 23, KiSt-SA, Rest
  DT_P23_SHARE = 229,   // .settle_p23: Anteil (Tarifweg); v: Betrag
  DT_P23_TAX = 230,     // .settle_p23: § 23-Steuer; v: Betrag
  DT_GP_REFUND = 231,   // .settle_gp: v: Erstattung
  DT_VP_SETTLE = 232,   // .settle_vp: v: Festsetzungstag, VP, nach TFS, SPB, Steuer
  DT_YC_HEAD = 240,     // .handle_year_change: v: altes, neues Jahr
  DT_YC_CARRY = 241,    // v: Verlustvortrag verwendet, verbleibend
  DT_YC_SUMMARY = 242,  // v: Jahr, Gewinne, Verluste, interne Verrechnung, Vortrag-Verrechnung, Netto
  DT_YC_LIMIT = 243,    // aux 1 Tarifweg; v: Saldo, Freigrenze, Gewinn, Satz, Soli-Faktor, KiSt-Faktor, Steuer
  DT_YC_LOSS = 244,     // v: Nettoverlust, Vortrag
  DT_YC_FREE = 245,     // v: Saldo, Freigrenze
  DT_YC_NONE = 246,     // v: Jahr
  DT_YC_SPB = 247,      // v: Jahr, Jahresbetrag, verwendet, verfallen
  DT_YC_REFUND = 248,   // v: Erstattung
  DT_YC_RELEASE = 249,  // v: Freigabe, Jahr, genutzt, Verlusttopf
  DT_TARIFF = 250,      // .tariff_close: aux use_gp; v: Jahreszeile (TR_N Werte, tariff_core_impl.h)
  DT_YC_END = 251       // v: neues Jahr
};
// Anlass (reason) der Kaeufe und Verkaeufe in der details-Ausgabe
enum Reason : int {
  RS_TRADE = 0,         // "Handelssignal:"
  RS_REBAL = 1,         // "Rebalancing:"
  RS_SIG_ENTRY = 2,     // "Rebalancing/Signal-Einstieg:"
  RS_SIG_EXIT = 3,      // "Rebalancing/Signal-Ausstieg:"
  RS_LIQ = 4,           // "Liquidation:"
  RS_TAX = 5,           // "Steuerereignis:"
  RS_SPLIT = 6,         // "Split:"
  RS_HARVEST = 7        // "Freibetrag:"
};
// Bezeichnungen der Steuerzahlungen (.pay_tax label)
enum Label : int { LBL_VP = 0, LBL_P23 = 1, LBL_VERANLAGUNG = 2 };

// Stellen (site) der Aufrufe bzw. Bedingungen (Anlass der Verkaeufe, sell_reason; bis R 1.3.0 ordnete R jeder
// Stelle den Aufruf der Phase zu, seit 1.4.1 tragen die Bedingungen den Aufruf von simulation())
enum Site : int {
  // Kaeufe (.perform_trade_buy)
  S_BUY_FEE_START = 1,  // .buy_with_fee: Startkapital am ersten Tag (sim_actions.R)
  S_BUY_FEE = 2,        // .buy_with_fee: Kauf (sim_actions.R)
  S_BUY_SIG_ENTRY = 3,  // .sim_day_rebalance: Signal-Einstieg
  S_BUY_REBAL = 4,      // .sim_day_rebalance: Kauf aus dem Rebalancing-Topf
  S_BUY_HARVEST = 5,    // .perform_gain_harvest: Wiederanlage
  // Verkaeufe (.perform_trade_sell)
  S_SELL_TRADE = 11,    // .sim_day_trade
  S_SELL_SIG_EXIT = 12, // .sim_day_rebalance: Signal-Ausstieg
  S_SELL_REBAL = 13,    // .sim_day_rebalance: Verkauf uebergewichteter Assets
  S_SELL_LIQ = 14,      // .sim_day_liquidate
  S_SELL_TAX = 15,      // .pay_one (sim_actions.R): Zwangsverkauf fuer eine Zahlung
  S_SELL_SPLIT = 16,    // .sim_day_split: Spitzenausgleich
  S_SELL_HARVEST = 17,  // .perform_gain_harvest
  // Aufrufe von .perform_asset_split in .sim_day_split (Abbruch EV_SPLIT_RATIO)
  S_SPLIT_FWD = 18,     // Split (ratio = Kurs / 100; 0, wenn der Kurs auf 0 unterlaeuft)
  S_SPLIT_REV = 19,     // Reverse-Split
  // Bedingungen mit moeglichem NA (if)
  C_BUYSIG_1 = 21,      // .calculate_buy_signal, erste Regel (Signal-Einstieg)
  C_BUYSIG_2 = 22,      // .calculate_buy_signal, zweite Regel (offene Position)
  C_BUYSIG_3 = 23,      // .calculate_buy_signal, Buy-and-Hold
  C_SELLSIG = 24,       // .calculate_sell_signal
  C_BWF_START = 25,     // .buy_with_fee: time == 1L && money - dca_part > 0.005
  C_FEE_VOLUME = 26,    // .fee_volume: fee < f$min
  C_BUY_TC_FEE = 27,    // .perform_trade_buy: trade_count <= 0 (mit Gebuehr)
  C_BUY_TC = 28,        // .perform_trade_buy: trade_count <= 0
  C_SELL_EXCESS = 29,   // .perform_trade_sell: count > available
  C_SELL_TC = 30,       // .perform_trade_sell: trade_count <= 0
  C_SELL_FEE = 31,      // .perform_trade_sell: trade_count * trade_price - fee_paid <= 0
  C_SC_SHARES = 32,     // .calculate_sell_count: total_shares <= 0
  C_SC_TARGET = 33,     // .calculate_sell_count: target <= 0
  C_DCA_DEFICIT = 34,   // .sim_day_dca: sum(deficit) > dca_amount
  C_GATE_EXIT = 35,     // .sim_day_rebalance: .has_pos && .sig_sell
  C_GATE_ENTRY = 36,    // .sim_day_rebalance: !.has_pos && .sig_buy
  C_GATE_CASH = 37,     // .sim_day_rebalance: !.has_pos && !.sig_buy
  C_REB_SELL = 38,      // .sim_day_rebalance: count > 0 && sell_target > 0
  C_REB_ALLOC = 39,     // .sim_day_rebalance: allocation > 0
  C_REB_POOL = 40,      // .sim_day_rebalance: transfer_pool > 0.01
  C_REB_REST = 41,      // .sim_day_rebalance: Restcash reinvestieren
  C_LIQ_COUNT = 42,     // .sim_day_liquidate: count > 0
  C_LIQ_LEFT = 43,      // .sim_day_liquidate: count > 0 nach dem Verkauf
  C_SLOW_NA = 44,       // .sim_run_days: if (!flag_slow_path[time]) mit NA
  // Steuerphasen
  C_PS_NET = 45,        // .perform_trade_sell: net_by != 0
  C_PS_GAIN = 46,       // .perform_trade_sell: lot_result$taxable_gain > 0
  C_PS_LOSS = 47,       // .perform_trade_sell: lot_result$taxable_loss > 0
  C_YC_SALDO = 48,      // .handle_year_change: net_saldo >= private_sale_threshold && net_saldo > 0
  C_YC_GAIN = 49,       // .handle_year_change: net_gain > 0
  C_YC_LOSS = 50,       // .handle_year_change: net_ytd_losses > 0
  C_YC_FREE = 51,       // .handle_year_change: net_saldo > 0 && net_saldo < private_sale_threshold
  C_YC_CARRY = 52,      // .handle_year_change: carry_start > 0
  C_YC_REFUND = 53,     // .handle_year_change: refund_done
  C_YC_REL = 54,        // .handle_year_change: release > 0
  C_YC_TOT = 55,        // .handle_year_change: any_refund && abs(total_taxes) < 1e-9
  C_YC_W = 56,          // .handle_year_change: sum(w) > 0
  C_GP_W = 57,          // .settle_gp: sum(w) > 0
  C_TB_TOT = 58,        // .tariff_book: abs(total_taxes) < 1e-9
  C_PO_CASH = 59,       // .pay_one: money >= amount
  C_PO_PART = 60,       // .pay_one: money > 0
  C_PO_LOOP = 61,       // .pay_one: short <= 0.005 || count <= 0
  C_PO_MIN = 62,        // .pay_one: k > 1 || !(n_sell > 0)
  C_PO_RAISED = 63,     // .pay_one: raised(sim_mem) <= before
  C_PO_SHORT = 64,      // .pay_one: short <= 0.005
  C_SCN_ROUND = 65,     // .sell_count_net: round_up && !fractions && sell_count > 0
  C_PT_UNPAID1 = 66,    // .pay_tax: unpaid > 1e-6 (erste)
  C_PT_UNPAID2 = 67,    // .pay_tax: unpaid > 1e-6 (zweite)
  C_PT_DONE = 68,       // .pay_tax: unpaid <= 1e-6
  C_PT_VAL = 69,        // .pay_tax: !(val[[nm]] > 0)
  C_PV_ZERO = 70,       // .pay_vp: prepaid == 0
  C_PV_MORE = 71,       // .pay_vp: tax_debt - prepaid > 1e-9
  C_PV_LESS = 72,       // .pay_vp: tax_debt - prepaid < -1e-9
  C_P23_DUE = 73,       // .settle_p23: !(due[[nm]] > 0)
  C_SV_PAY = 74,        // .settle_vp: result$tax > 0 || pre > 0
  C_AV_FUND = 75,       // .sim_day_assess_vp: tax_regime == "investment_fund" && count > 0
  C_AV_RATE = 76,       // .sim_day_assess_vp: flat_rate > 0
  C_FR_BASE = 77,       // .calculate_flat_rate: base_rate <= 0
  C_SP_FREE = 78,       // .sim_day_split: px0 > hi || px0 < lo
  C_SP_HELD = 79,       // .sim_day_split: count > 0
  C_SP_FWD = 80,        // .sim_day_split: split_price > hi
  C_SP_REV = 81,        // .sim_day_split: split_price < lo
  C_SP_FRAC = 82,       // .sim_day_split: !fractions && split_frac > 1e-9
  C_SPLIT_RATIO = 83,   // .perform_asset_split: ratio <= 0
  C_HV_TOTAL = 84,      // .perform_gain_harvest: total <= 0
  C_HV_ROOM = 85,       // .perform_gain_harvest: room <= 0.01
  C_HV_FIRST = 86,      // .perform_gain_harvest: taxable(first_lot, FALSE) <= 0
  C_HV_ALL = 87,        // .perform_gain_harvest: taxable(total) <= room
  C_HV_MID = 88,        // .perform_gain_harvest: taxable(mid) > room
  C_HV_TOL = 89,        // .perform_gain_harvest: hi - lo < total * 1e-10
  C_HV_N = 90,          // .perform_gain_harvest: n <= 0 || taxable(n) <= 0
  C_HV_TAXN = 91,       // .perform_gain_harvest (taxable): n <= 0
  C_CY_PREPAID = 92,    // .sim_close_years: prepaid[j] > 0
  C_CY_GP = 93,         // .sim_close_years: isTRUE(use_gp) && y_last > Jahr && cgt_base_taxed_ytd > 0
  C_VT_SHARE = 94,      // .vp_taxes: sum(taxable) > 0
  // Bedingungen, die R nur mit details = TRUE auswertet
  C_D_VP = 95,          // .perform_trade_sell: vorabpauschale_paid > 0
  C_D_SPB = 96,         // .perform_trade_sell: result$spb_used > 0
  C_D_EXG = 97,         // .perform_trade_sell: lot_result$exempt_gain > 0
  C_D_EXL = 98,         // .perform_trade_sell: lot_result$exempt_loss > 0
  C_D_PAID = 99,        // .pay_one: details && remaining - unpaid > 0
  C_D_DUE = 100,        // .settle_p23: details && length(info) && any(due > 0)
  C_D_REST = 101,       // .settle_p23: abs(rest) >= 0.005
  C_D_DEV = 102,        // .sim_day_rebalance: dev > balance_thresh
  C_D_CARRY = 103,      // .handle_year_change: details && carryforward_offset > 0
  C_D_G23 = 104         // .tariff_close: g23 > 0
};

struct Event {
  int code, site, day, asset;   // day 1-basiert, asset 0-basiert (-1: keins)
  int aux, y_off, ny;           // EV_TAX_UNPAID: Bezeichnung und Jahre (ev_ints[y_off .. y_off + ny - 1])
  int v_off, nv;                // details (DT_*): Werte ev_vals[v_off .. v_off + nv - 1]
  double d0, d1;
};

struct Fee {
  int on;
  double fixed, percent, min, max;
};

struct Status {
  double count, price, worth, money, total, target, actual, differ;
};

struct Lot {
  double date, count, price, remaining, original, vp;
  int has_vp;                   // Feld vp vorhanden (R: erst ab der ersten Festsetzung am 31.12.)
};

// Verkauf (Eintrag in trades$sells); regime RG_NONE: tax_mode "none" (Steuerangaben NA)
struct Sell {
  double date, count, price, gain, taxes, exempt;
  int regime, has_exempt;
};

// Steuerbuchung (trades$taxes): kind 1 Vorabpauschale, 2 § 23-Steuer bzw. Veranlagung
struct TaxEntry {
  int kind;
  double event_date, assessment_date, gross, bonus, taxable, spb_used, paid;
};

struct VPPend {
  int asset;
  double flat_rate, bonus, assessment_date;
};

// sim_mem$totals; p23_due und ps_net_by als (Asset, Betrag) in der Reihenfolge der Namen in R
struct Totals {
  double v[TT_N];
  std::vector<VPPend> vp_pending;
  std::vector<std::pair<int, double>> p23_due, ps_net_by;
};

struct DueInfo {
  int year;
  double D, p23, ded;
  int by_p23;
};

// Eingaben je Asset (Zeiger des Hosts, waehrend des Laufs gueltig)
struct AssetIn {
  const double* sig_buy = nullptr;    // Signalwerte als double (logisch: 0/1, NA = R's NA)
  const double* sig_sell = nullptr;
  const double* event_w = nullptr;    // Spalte aus event_weight (n Tage) oder nullptr
  const double* base_rates = nullptr; // market$base_rates (n Tage) oder nullptr
  int buy_logical = 0, sell_logical = 0;   // Spalte logisch (isTRUE nur fuer logisches TRUE)
  int style = 0;                      // 0 bnh, 1 signal
  int start_idx = 1;                  // asset_start_indices (1-basiert)
  int start_day = 0;                  // Tag (1-basiert) mit asset_starts == flag_date, sonst 0
  int initial = 0;                    // in initial_assets
  int regime = 0;                     // fl$tax_regimes (Regime)
  int no_split = 0;                   // cfg$no_split (Fonds-Wrapper)
  double spread = 0.0;                // spread_rate (Anteil)
  double share = 0.0;                 // strategy[[name]]$share (Sparplan-Gewicht)
  double bonus = 0.0;                 // assets$bonus (Teilfreistellung)
  Status st0{};                       // Status nach .sim_init_weights
};

// Ergebnis-Vektoren je Asset (Speicher des Hosts, Laenge n; vom Kern ganz beschrieben)
struct ReportOut {
  double *worth, *money, *flows, *total, *share;
};

struct NAError {
  int site, day, asset, code;
  double d0;
  NAError(int s = 0, int d = 0, int a = -1, int c = EV_NA_COND, double v = 0.0)
      : site(s), day(d), asset(a), code(c), d0(v) {}
};

// R-Wahrheitswerte: 0 FALSE, 1 TRUE, 2 NA
typedef int lgl;
static inline lgl rl_cmp_nan(double a, double b) { return (a != a || b != b) ? 1 : 0; }
static inline lgl r_gt(double a, double b) { return rl_cmp_nan(a, b) ? 2 : (a > b ? 1 : 0); }
static inline lgl r_ge(double a, double b) { return rl_cmp_nan(a, b) ? 2 : (a >= b ? 1 : 0); }
static inline lgl r_le(double a, double b) { return rl_cmp_nan(a, b) ? 2 : (a <= b ? 1 : 0); }
static inline lgl r_lt(double a, double b) { return rl_cmp_nan(a, b) ? 2 : (a < b ? 1 : 0); }
static inline lgl r_eq(double a, double b) { return rl_cmp_nan(a, b) ? 2 : (a == b ? 1 : 0); }
static inline lgl r_ne(double a, double b) { return rl_cmp_nan(a, b) ? 2 : (a != b ? 1 : 0); }
static inline lgl r_and(lgl a, lgl b) { return (a == 0 || b == 0) ? 0 : ((a == 2 || b == 2) ? 2 : 1); }
static inline lgl r_or(lgl a, lgl b) { return (a == 1 || b == 1) ? 1 : ((a == 2 || b == 2) ? 2 : 0); }
static inline lgl r_not(lgl a) { return a == 2 ? 2 : 1 - a; }
static inline lgl r_lgl(double x) { return x != x ? 2 : (x != 0 ? 1 : 0); }   // as.logical eines Signals
static inline lgl r_bool(bool b) { return b ? 1 : 0; }

// R's min(a, b) bzw. max(a, b) fuer zwei Zahlen (NA vor NaN wie rmin/rmax)
static inline double r_nan2(double a, double b) {
  if (a != a && simlev_is_na(a)) return a;
  if (b != b) return b;
  return a;
}
static inline double r_min2(double a, double b) { return (a != a || b != b) ? r_nan2(a, b) : (b < a ? b : a); }
static inline double r_max2(double a, double b) { return (a != a || b != b) ? r_nan2(a, b) : (b > a ? b : a); }

// civil_from_days/days_from_civil (eng_civil, eng_days): prepare_core_impl.h
using simlev_prepare::eng_civil;
using simlev_prepare::eng_days;
// Jahr eines Datums (Tageszahl, auch gebrochen: abgerundet wie format(, "%Y"))
static inline int eng_year(double day) {
  int y, m, d;
  eng_civil((long) std::floor(day), y, m, d);
  return y;
}

class Engine {
 public:
  // ── Eingaben ──
  int n = 0, na = 0;                       // Tage, Assets
  const uint32_t* flags = nullptr;         // Tagesflags (n)
  const double* dca_n = nullptr;           // flag_dca_n (n)
  const double* day = nullptr;             // flag_date als Tageszahl (n)
  std::vector<AssetIn> in;
  std::vector<std::vector<double>> px;     // Kurse je Asset (Kopie; Splits rechnen sie um)
  std::vector<double> no_sig;              // seit 1.6.1: FALSE an jedem Tag fuer Assets ohne Signalspalte (leerer Zeiger)
  std::vector<char> px_changed;            // Kursreihe durch einen Split geaendert
  int fractions = 0, fees_on = 0, balance_mode = 0, balance_dca = 0;
  int thresh_set = 0, thresh_relative = 0, has_event_weight = 0;
  int person = 0, use_spb = 0, loss_pot = 0, liquidate = 0, has_marginal = 0, stopp_year = 0;
  int details = 0;                         // details-Ausgaben als Ereignisse DT_*
  double balance_thresh = 0.0, dca_value = 0.0;
  double eff_rate = 0.0, marginal = 0.0, ps_threshold = 0.0, spb = 0.0, soli_factor = 1.0, church_k = 0.0;
  double split_lo = 0.0, split_hi = 0.0;
  Fee fee_order{}, fee_dca{};
  double fee_paid0 = 0.0;                  // .fee_env$paid vor dem Lauf
  double tot0[TT_N] = {0};
  // Tarifweg (tariff_env)
  int tariff_on = 0, has_zve_all = 0;
  double zve_all = 0.0;
  simlev::TariffCore tariff;
  std::vector<std::pair<int, double>> zve;
  // ── Zustand und Ergebnis ──
  std::vector<Status> st;
  std::vector<ReportOut> rep;
  std::vector<std::vector<Lot>> buys;
  std::vector<int> front;                  // fifo_front je Asset (1-basiert)
  std::vector<std::vector<Sell>> sells;
  std::vector<std::vector<TaxEntry>> taxes;
  Totals T;
  double fee_paid = 0.0, tax_unpaid = 0.0;
  std::vector<std::array<double, simlev::TR_N>> rows;      // tariff_env$rows (Jahreszeilen)
  std::vector<std::pair<int, double>> ks;                  // tariff_env$ks (Jahr -> KiSt-Saldo), Reihenfolge wie R
  double refund_due = 0.0;
  std::vector<DueInfo> due_info;
  std::vector<Event> events;
  std::vector<int> ev_ints;                // Ganzzahlen der Ereignisse (Jahre, Asset-Indizes)
  std::vector<double> ev_vals;             // Werte der details-Ereignisse
  NAError err;

  void init(int n_days, int n_assets) {
    n = n_days;
    na = n_assets;
    in.assign((std::size_t) na, AssetIn());
    rep.assign((std::size_t) na, ReportOut{nullptr, nullptr, nullptr, nullptr, nullptr});
    px.assign((std::size_t) na, std::vector<double>());
    no_sig.clear();
    px_changed.assign((std::size_t) na, 0);
  }

  // Vorbereitung (prepare_core_impl.h) aus den flachen Angaben F, dann setup(). Aus I gelten
  // day, price, sig_buy, sig_sell, ai (Stil, no_split; Startindizes setzt die Vorbereitung), ad (share) und
  // reports (Tag 1 setzt die Vorbereitung); I.flags, I.dca_n und I.st0 werden hier gesetzt.
  // Rueckgabe wie setup(), 10 + Code von simlev_prepare::prepare bei fehlerhaften Angaben.
  std::vector<int32_t> prep_flags, prep_ai;
  std::vector<double> prep_dca_n, prep_st0;
  int setup_prepared(Input I, const simlev_prepare::PrepFlat& F) {
    if (I.n < 1 || I.na < 1 || !I.ai || !I.ad || !I.reports || !F.pi || !F.pd || !F.start) return 1;
    const std::size_t nn = (std::size_t) I.n, nk = (std::size_t) I.na;
    simlev_prepare::PrepIn P;
    simlev_prepare::prep_from_flat(F, P);
    std::vector<int32_t> style(nk), no_split(nk), aux(3 * nk);
    std::vector<double> share(nk), rep0(3 * nk);
    for (std::size_t a = 0; a < nk; a++) {
      style[a] = I.ai[AI_N * a + AI_STYLE];
      no_split[a] = I.ai[AI_N * a + AI_NO_SPLIT];
      share[a] = I.ad[AD_N * a + AD_SHARE];
    }
    P.n = I.n; P.na = I.na; P.day = I.day; P.price = I.price; P.sig_buy = I.sig_buy; P.sig_sell = I.sig_sell;
    P.style = style.data(); P.no_split = no_split.data(); P.share = share.data();
    prep_flags.assign(nn, 0);
    prep_dca_n.assign(nn, 0.0);
    prep_st0.assign(8 * nk, 0.0);
    simlev_prepare::PrepOut O;
    O.flags = prep_flags.data(); O.dca_n = prep_dca_n.data(); O.st0 = prep_st0.data(); O.rep0 = rep0.data();
    O.aux = aux.data();
    const int pr = simlev_prepare::prepare(P, O);
    if (pr) return 10 + pr;
    prep_ai.assign(I.ai, I.ai + AI_N * nk);
    for (std::size_t a = 0; a < nk; a++) {
      prep_ai[AI_N * a + AI_START_IDX] = aux[3 * a];
      prep_ai[AI_N * a + AI_START_DAY] = aux[3 * a + 1];
      prep_ai[AI_N * a + AI_INITIAL] = aux[3 * a + 2];
      double* const* r = I.reports + 5 * a;
      if (!r[0] || !r[1] || !r[3]) return 3;
      r[0][0] = rep0[3 * a];
      r[1][0] = rep0[3 * a + 1];
      r[3][0] = rep0[3 * a + 2];
    }
    I.flags = prep_flags.data();
    I.dca_n = prep_dca_n.data();
    I.st0 = prep_st0.data();
    I.ai = prep_ai.data();
    return setup(I);
  }

  // Flache Eingabe uebernehmen; Rueckgabe 0 in Ordnung, sonst Nummer der fehlerhaften Angabe
  int setup(const Input& I) {
    if (I.n < 1 || I.na < 1 || !I.flags || !I.dca_n || !I.day || !I.price || !I.sig_buy || !I.sig_sell || !I.ai ||
        !I.ad || !I.st0 || !I.ci || !I.cd || !I.fees || !I.tot0 || !I.reports)
      return 1;
    init((int) I.n, (int) I.na);
    flags = reinterpret_cast<const uint32_t*>(I.flags);
    dca_n = I.dca_n;
    day = I.day;
    has_event_weight = I.event_w != nullptr;
    for (int a = 0; a < na; a++) {
      AssetIn& A = in[a];
      if (!I.price[a]) return 2;
      // Seit 1.6.1 darf ein Asset ohne Signalstil (bnh) leere Zeiger fuer die Signale haben (Python, Julia: keine
      // Spalte); sie lesen sich wie FALSE an jedem Tag, also wie die bis 1.6.0 von den Hosts angelegten Nullspalten.
      if (!I.sig_buy[a] || !I.sig_sell[a]) {
        if (I.ai[(std::size_t) AI_N * a + AI_STYLE] == 1) return 2;
        if (no_sig.empty()) no_sig.assign((std::size_t) n, 0.0);
      }
      px[a].assign(I.price[a], I.price[a] + n);
      A.sig_buy = I.sig_buy[a] ? I.sig_buy[a] : no_sig.data();
      A.sig_sell = I.sig_sell[a] ? I.sig_sell[a] : no_sig.data();
      A.event_w = I.event_w ? I.event_w[a] : nullptr;
      A.base_rates = I.base_rates ? I.base_rates[a] : nullptr;
      const int32_t* ai = I.ai + (std::size_t) AI_N * a;
      A.style = ai[AI_STYLE];
      A.start_idx = ai[AI_START_IDX];
      A.start_day = ai[AI_START_DAY];
      A.initial = ai[AI_INITIAL];
      A.regime = ai[AI_REGIME];
      A.no_split = ai[AI_NO_SPLIT];
      A.buy_logical = ai[AI_BUY_LGL];
      A.sell_logical = ai[AI_SELL_LGL];
      const double* ad = I.ad + (std::size_t) AD_N * a;
      A.spread = ad[AD_SPREAD];
      A.share = ad[AD_SHARE];
      A.bonus = ad[AD_BONUS];
      const double* s0 = I.st0 + 8 * (std::size_t) a;
      A.st0 = Status{s0[0], s0[1], s0[2], s0[3], s0[4], s0[5], s0[6], s0[7]};
      double* const* r = I.reports + 5 * (std::size_t) a;
      if (!r[0] || !r[1] || !r[2] || !r[3] || !r[4]) return 3;
      rep[a] = ReportOut{r[0], r[1], r[2], r[3], r[4]};
    }
    fractions = I.ci[CI_FRACTIONS];
    fees_on = I.ci[CI_FEES_ON];
    balance_mode = I.ci[CI_BALANCE_MODE];
    balance_dca = I.ci[CI_BALANCE_DCA];
    thresh_set = I.ci[CI_THRESH_SET];
    thresh_relative = I.ci[CI_THRESH_REL];
    person = I.ci[CI_PERSON];
    use_spb = I.ci[CI_USE_SPB];
    loss_pot = I.ci[CI_LOSS_POT];
    liquidate = I.ci[CI_LIQUIDATE];
    has_marginal = I.ci[CI_HAS_MARGINAL];
    stopp_year = I.ci[CI_STOPP_YEAR];
    has_zve_all = I.ci[CI_HAS_ZVE_ALL];
    details = I.ci[CI_DETAILS];
    balance_thresh = I.cd[CD_BALANCE_THRESH];
    dca_value = I.cd[CD_DCA_VALUE];
    fee_paid0 = I.cd[CD_FEE_PAID0];
    eff_rate = I.cd[CD_EFF_RATE];
    marginal = I.cd[CD_MARGINAL];
    ps_threshold = I.cd[CD_PS_THRESHOLD];
    spb = I.cd[CD_SPB];
    soli_factor = I.cd[CD_SOLI_FACTOR];
    church_k = I.cd[CD_CHURCH_K];
    split_lo = I.cd[CD_SPLIT_LO];
    split_hi = I.cd[CD_SPLIT_HI];
    zve_all = I.cd[CD_ZVE_ALL];
    fee_order = Fee{(int) I.fees[0], I.fees[1], I.fees[2], I.fees[3], I.fees[4]};
    fee_dca = Fee{(int) I.fees[5], I.fees[6], I.fees[7], I.fees[8], I.fees[9]};
    for (int k = 0; k < TT_N; k++) tot0[k] = I.tot0[k];
    std::vector<double> par(I.tariff_par ? I.tariff_par : (const double*) nullptr,
                            I.tariff_par ? I.tariff_par + I.n_tariff_par : (const double*) nullptr);
    if (!tariff.init(par)) return 4;
    tariff_on = tariff.on ? 1 : 0;
    zve.clear();
    for (int64_t k = 0; k < I.n_zve; k++) zve.emplace_back((int) I.zve[2 * k], I.zve[2 * k + 1]);
    return 0;
  }

  // Lauf mit Abschluss des letzten Jahres; Rueckgabe 0 in Ordnung, 1 Abbruch (err)
  int run() {
    st.resize((std::size_t) na);
    buys.assign((std::size_t) na, std::vector<Lot>());
    front.assign((std::size_t) na, 1);
    sells.assign((std::size_t) na, std::vector<Sell>());
    taxes.assign((std::size_t) na, std::vector<TaxEntry>());
    for (int a = 0; a < na; a++) st[a] = in[a].st0;
    for (int k = 0; k < TT_N; k++) T.v[k] = tot0[k];
    T.vp_pending.clear();
    T.p23_due.clear();
    T.ps_net_by.clear();
    fee_paid = fee_paid0;
    tax_unpaid = 0.0;
    rows.clear();
    ks.clear();
    refund_due = 0.0;
    due_info.clear();
    events.clear();
    ev_ints.clear();
    ev_vals.clear();
    fee_cur = nullptr;
    quiet = false;
    try {
      run_days();
      close_years();
    } catch (const NAError& e) {
      err = e;
      return 1;
    }
    return 0;
  }

  // ── Ausgaben (flach) ──
  void status_out(double* o) const {
    for (int a = 0; a < na; a++) {
      const Status& s = st[a];
      double* p = o + 8 * (std::size_t) a;
      p[0] = s.count; p[1] = s.price; p[2] = s.worth; p[3] = s.money;
      p[4] = s.total; p[5] = s.target; p[6] = s.actual; p[7] = s.differ;
    }
  }
  void totals_out(double* o) const { for (int k = 0; k < TT_N; k++) o[k] = T.v[k]; }
  // Lots: date, count, price, remaining, original, vp, has_vp (7 je Lot)
  void lots_out(int a, double* o) const {
    for (const Lot& l : buys[a]) {
      o[0] = l.date; o[1] = l.count; o[2] = l.price; o[3] = l.remaining; o[4] = l.original; o[5] = l.vp;
      o[6] = l.has_vp;
      o += 7;
    }
  }
  // Verkaeufe: date, count, price, gain, taxes, regime, exempt, has_exempt (8 je Verkauf)
  void sells_out(int a, double* o) const {
    for (const Sell& s : sells[a]) {
      o[0] = s.date; o[1] = s.count; o[2] = s.price; o[3] = s.gain; o[4] = s.taxes; o[5] = s.regime;
      o[6] = s.exempt; o[7] = s.has_exempt;
      o += 8;
    }
  }
  // Steuerbuchungen: kind, event_date, assessment_date, gross, bonus, taxable, spb_used, paid (8 je Eintrag)
  void taxes_out(int a, double* o) const {
    for (const TaxEntry& e : taxes[a]) {
      o[0] = e.kind; o[1] = e.event_date; o[2] = e.assessment_date; o[3] = e.gross; o[4] = e.bonus;
      o[5] = e.taxable; o[6] = e.spb_used; o[7] = e.paid;
      o += 8;
    }
  }
  // Ereignisse: 9 Ganzzahlen (code, site, day, asset, aux, y_off, ny, v_off, nv) und 2 Zahlen (d0, d1) je Ereignis
  void events_out(int32_t* oi, double* od) const {
    for (const Event& e : events) {
      oi[0] = e.code; oi[1] = e.site; oi[2] = e.day; oi[3] = e.asset; oi[4] = e.aux; oi[5] = e.y_off; oi[6] = e.ny;
      oi[7] = e.v_off; oi[8] = e.nv;
      od[0] = e.d0; od[1] = e.d1;
      oi += 9;
      od += 2;
    }
  }
  // Jahreszeilen des Tarifwegs (TR_N je Zeile) und KiSt-Salden (Jahr, Betrag)
  void rows_out(double* o) const {
    for (const auto& r : rows) {
      for (int k = 0; k < simlev::TR_N; k++) o[k] = r[k];
      o += simlev::TR_N;
    }
  }
  void ks_out(double* o) const {
    for (const auto& p : ks) {
      o[0] = p.first;
      o[1] = p.second;
      o += 2;
    }
  }

 private:
  const Fee* fee_cur = nullptr;            // .fee_env$current
  bool quiet = false;                      // Probelauf: Warnungen verwerfen
  std::vector<int> active;                 // aktive Assets (Reihenfolge der Strategie)
  std::vector<double> buf;                 // Puffer
  std::vector<double> buf2, buf3, buf4, buf5;

  bool cond(lgl v, int site, int t, int a) {
    if (v == 2) throw NAError(site, t, a);
    return v == 1;
  }
  void warn(int code, int site, int t, int a, double d0 = 0.0, double d1 = 0.0, int aux = 0,
            const std::vector<int>* years = nullptr) {
    if (quiet) return;
    Event e{code, site, t, a, aux, (int) ev_ints.size(), 0, (int) ev_vals.size(), 0, d0, d1};
    if (years) {
      ev_ints.insert(ev_ints.end(), years->begin(), years->end());
      e.ny = (int) years->size();
    }
    events.push_back(e);
  }
  // details-Ausgaben: nur mit details = TRUE und nicht im Probelauf (R: details = FALSE dort)
  bool det() const { return details && !quiet; }
  void detail(int code, int t, int a, std::initializer_list<double> v, int aux = 0,
              const std::vector<int>* ints = nullptr) {
    detail_v(code, t, a, v.begin(), (int) v.size(), aux, ints);
  }
  void detail_v(int code, int t, int a, const double* v, int nv, int aux = 0, const std::vector<int>* ints = nullptr) {
    if (!det()) return;
    Event e{code, 0, t, a, aux, (int) ev_ints.size(), 0, (int) ev_vals.size(), nv, 0.0, 0.0};
    if (ints) {
      ev_ints.insert(ev_ints.end(), ints->begin(), ints->end());
      e.ny = (int) ints->size();
    }
    ev_vals.insert(ev_vals.end(), v, v + nv);
    events.push_back(e);
  }
  static int sell_reason(int site) {
    switch (site) {
      case S_SELL_TRADE: return RS_TRADE;
      case S_SELL_SIG_EXIT: return RS_SIG_EXIT;
      case S_SELL_REBAL: return RS_REBAL;
      case S_SELL_LIQ: return RS_LIQ;
      case S_SELL_TAX: return RS_TAX;
      case S_SELL_SPLIT: return RS_SPLIT;
      default: return RS_HARVEST;
    }
  }
  bool has(int t, uint32_t f) const { return (flags[t - 1] & f) != 0; }
  static const Fee* fee_ptr(const Fee& f) { return f.on ? &f : nullptr; }   // NULL = keine Gebuehr
  static double spread_buy(double price, double spread) { return price * (1 + spread / 2); }
  static double spread_sell(double price, double spread) { return price * (1 - spread / 2); }
  static double fee_amount(const Fee& f, double volume) {
    return r_min2(r_max2(f.fixed + f.percent * volume, f.min), f.max);
  }
  double fee_volume(const Fee& f, double money, int t, int a) {
    double v = (money - f.fixed) / (1 + f.percent);
    double fee = f.fixed + f.percent * v;
    if (cond(r_lt(fee, f.min), C_FEE_VOLUME, t, a)) v = money - f.min;
    else if (cond(r_gt(fee, f.max), C_FEE_VOLUME, t, a)) v = money - f.max;
    return r_max2(0.0, v);
  }

  // ── Kerne wie core/simulation_core_impl.h (dieselbe Rechnung, Zustand als Strukturen) ──
  void total_report(int t) {
    const int i0 = t - 1;
    for (int a = 0; a < na; a++) {
      Status& s = st[a];
      const double price = px[a][i0];
      s.price = price;
      const double worth = simlev_mul(price, s.count);
      s.worth = worth;
      rep[a].worth[i0] = worth;
      const double money = s.money;
      rep[a].money[i0] = money;
      const double total = simlev_add(money, worth);
      s.total = total;
      rep[a].total[i0] = total;
    }
    double total_worth = 0.0;
    for (int a = 0; a < na; a++) total_worth = simlev_add(total_worth, st[a].total);
    for (int a = 0; a < na; a++) {
      const double w = (total_worth > 0) ? simlev_div(st[a].total, total_worth) : 0.0;
      st[a].differ = w;
      rep[a].share[i0] = w;
    }
  }

  void market_update(int t) {
    const int i0 = t - 1;
    double total_portfolio = 0.0;
    buf.resize((std::size_t) na);
    for (int a = 0; a < na; a++) {
      Status& s = st[a];
      const double price = px[a][i0];
      const double worth = simlev_mul(s.count, price);
      const double total = simlev_add(worth, s.money);
      buf[a] = total;
      total_portfolio = simlev_add(total_portfolio, total);
      rep[a].worth[i0] = worth;
      rep[a].money[i0] = s.money;
      rep[a].flows[i0] = 0.0;
      rep[a].total[i0] = total;
      s.price = price;
      s.worth = worth;
      s.total = total;
    }
    for (int a = 0; a < na; a++) {
      const double w = (total_portfolio > 0) ? simlev_div(buf[a], total_portfolio) : 0.0;
      rep[a].share[i0] = w;
      st[a].differ = w;
    }
  }

  void batch_market_update(int start_idx, int end_idx) {
    const int nd = end_idx - start_idx + 1;
    if (nd <= 0) return;
    buf.assign((std::size_t) nd, 0.0);
    for (int a = 0; a < na; a++) {
      Status& s = st[a];
      const double count = s.count, money = s.money;
      const double* prices = px[a].data();
      double last_worth = 0.0, last_total = 0.0, last_price = 0.0;
      for (int d = 0; d < nd; d++) {
        const int idx = start_idx - 1 + d;
        const double price = prices[idx];
        const double worth = simlev_mul(count, price);
        const double total = simlev_add(worth, money);
        rep[a].worth[idx] = worth;
        rep[a].money[idx] = money;
        rep[a].flows[idx] = 0.0;
        rep[a].total[idx] = total;
        buf[d] = simlev_add(buf[d], total);
        last_price = price;
        last_worth = worth;
        last_total = total;
      }
      s.price = last_price;
      s.worth = last_worth;
      s.total = last_total;
    }
    for (int a = 0; a < na; a++) {
      double last_weight = 0.0;
      for (int d = 0; d < nd; d++) {
        const int idx = start_idx - 1 + d;
        const double w = (buf[d] > 0.0) ? simlev_div(rep[a].total[idx], buf[d]) : 0.0;
        rep[a].share[idx] = w;
        last_weight = w;
      }
      st[a].differ = last_weight;
    }
  }

  void dca_flows(int a, double flows, int t) {
    const int i0 = t - 1;
    Status& s = st[a];
    rep[a].flows[i0] = flows;
    const double money = simlev_add(s.money, flows);
    s.money = money;
    rep[a].money[i0] = money;
    const double total = simlev_add(money, s.worth);
    s.total = total;
    rep[a].total[i0] = total;
  }

  void buy_report(int a, int t, double tc, double tp, double mp) {
    const int i0 = t - 1;
    Status& s = st[a];
    const double count = simlev_add(s.count, tc);
    s.count = count;
    s.price = mp;
    const double worth = simlev_mul(count, mp);
    s.worth = worth;
    const double money = simlev_sub(s.money, simlev_mul(tc, tp));
    s.money = money;
    const double total = simlev_add(worth, money);
    s.total = total;
    rep[a].worth[i0] = worth;
    rep[a].money[i0] = money;
    rep[a].total[i0] = total;
  }

  void sell_report(int a, int t, double tc, double tp, double mp, double tax) {
    const int i0 = t - 1;
    Status& s = st[a];
    const double count = simlev_sub(s.count, tc);
    s.count = count;
    s.price = mp;
    const double worth = simlev_mul(count, mp);
    s.worth = worth;
    const double money = simlev_add(s.money, simlev_sub(simlev_mul(tc, tp), tax));
    s.money = money;
    const double total = simlev_add(worth, money);
    s.total = total;
    rep[a].worth[i0] = worth;
    rep[a].money[i0] = money;
    rep[a].total[i0] = total;
  }

  // ── FIFO (core/fifo_core_impl.h auf den Lots ab fifo_front) ──
  double fifo_price(int a, double units) const {
    double ut = units, tp = 0.0;
    const std::vector<Lot>& L = buys[a];
    for (int i = front[a]; ut > 0 && i <= (int) L.size(); ++i) {
      const Lot& b = L[i - 1];
      const double rem = b.remaining;
      if (rem > 0) {
        const double s = std::min(rem, ut);
        tp = simlev_add(tp, simlev_mul(s, b.price));
        ut = simlev_sub(ut, s);
      }
    }
    return (units > 0) ? simlev_div(tp, units) : 0.0;
  }
  double fifo_vp(int a, double units) const {
    double ut = units, tv = 0.0;
    const std::vector<Lot>& L = buys[a];
    for (int i = front[a]; ut > 0 && i <= (int) L.size(); ++i) {
      const Lot& b = L[i - 1];
      const double rem = b.remaining;
      if (rem > 0) {
        const double s = std::min(rem, ut);
        const double lot_vp = b.has_vp ? b.vp : 0.0;
        if (rem > 0 && lot_vp > 0) tv = simlev_add(tv, simlev_mul(s, simlev_div(lot_vp, rem)));   // Basis = remaining
        ut = simlev_sub(ut, s);
      }
    }
    return tv;
  }
  struct PSTax { double exempt_gain, exempt_loss, taxable_gain, taxable_loss; };
  PSTax private_sale_tax(int a, double trade_count, double sell_price, int current_date) const {
    double ur = trade_count;
    PSTax r{0, 0, 0, 0};
    const std::vector<Lot>& L = buys[a];
    for (int i = front[a]; ur > 0 && i <= (int) L.size(); ++i) {
      const Lot& b = L[i - 1];
      const double avail = b.remaining;
      if (avail > 0) {
        const double s = std::min(avail, ur);
        const int buy_days = static_cast<int>(b.date);
        int y, m, d;
        eng_civil(buy_days, y, m, d);
        const bool leap = ((y + 1) % 4 == 0 && (y + 1) % 100 != 0) || ((y + 1) % 400 == 0);
        const long one_year_later = (m == 2 && d == 29 && !leap) ? eng_days(y + 1, 2, 28) : eng_days(y + 1, m, d);
        const bool is_exempt = current_date > one_year_later;
        const double lot_gain = simlev_mul(s, simlev_sub(sell_price, b.price));
        if (is_exempt) {
          if (lot_gain >= 0) r.exempt_gain = simlev_add(r.exempt_gain, lot_gain);
          else r.exempt_loss = simlev_add(r.exempt_loss, -lot_gain);
        } else {
          if (lot_gain >= 0) r.taxable_gain = simlev_add(r.taxable_gain, lot_gain);
          else r.taxable_loss = simlev_add(r.taxable_loss, -lot_gain);
        }
        ur = simlev_sub(ur, s);
      }
    }
    return r;
  }
  void fifo_consume(int a, double trade_count) {
    std::vector<Lot>& L = buys[a];
    const int bc = (int) L.size();
    double ur = trade_count;
    for (int i = front[a]; ur > 0 && i <= bc; ++i) {
      Lot& b = L[i - 1];
      const double rem = b.remaining;
      if (rem > 0) {
        const double red = std::min(rem, ur);
        if (b.has_vp && b.vp > 0 && rem > 0) b.vp = simlev_mul(b.vp, 1.0 - simlev_div(red, rem));
        b.remaining = simlev_sub(rem, red);
        ur = simlev_sub(ur, red);
      }
    }
    int f = front[a];
    while (f <= bc && !(L[f - 1].remaining > 0)) ++f;
    front[a] = f;
  }
  static int update_front(const std::vector<Lot>& L) {   // .update_fifo_front ab 1
    int f = 1;
    while (f <= (int) L.size()) {
      if (L[f - 1].remaining > 0) return f;
      ++f;
    }
    return f;
  }

  // ── Steuerkerne (core/tax_core_impl.h auf Totals) ──
  struct TaxRes { double tax, spb_used; };
  TaxRes p20_tax(Totals& X, double trade_gain, double bonus) const {
    const double adj = simlev_mul(trade_gain, 1.0 - bonus);
    double* v = X.v;
    if (adj < 0) {
      v[TT_LOSS_CG] = simlev_sub(v[TT_LOSS_CG], adj);
      v[TT_CGT_ADDED] = simlev_sub(v[TT_CGT_ADDED], adj);
      return TaxRes{0.0, 0.0};
    }
    const double pool = v[TT_LOSS_CG];
    const double loss_offset = std::min(adj, pool);
    v[TT_LOSS_CG] = simlev_sub(pool, loss_offset);
    v[TT_CGT_USED] = simlev_add(v[TT_CGT_USED], loss_offset);
    const double gain_after_loss = simlev_sub(adj, loss_offset);
    double spb_offset = 0.0;
    const double spb_rem = v[TT_SPB_REM];
    if (use_spb && spb_rem > 0) {
      spb_offset = std::min(gain_after_loss, spb_rem);
      v[TT_SPB_REM] = simlev_sub(spb_rem, spb_offset);
      v[TT_SPB_USED] = simlev_add(v[TT_SPB_USED], spb_offset);
    }
    const double taxable_gain = simlev_sub(gain_after_loss, spb_offset);
    v[TT_CGT_BASE] = simlev_add(v[TT_CGT_BASE], taxable_gain);
    const double tax = simlev_mul(taxable_gain, eff_rate);
    v[TT_TOTAL_TAXES] = simlev_add(v[TT_TOTAL_TAXES], tax);
    return TaxRes{tax, spb_offset};
  }
  TaxRes vp_tax(Totals& X, double flat_rate, double bonus) const {
    const double taxable = simlev_mul(flat_rate, 1.0 - bonus);
    double* v = X.v;
    const double pool = v[TT_LOSS_CG];
    const double loss_offset = std::min(taxable, pool);
    v[TT_LOSS_CG] = simlev_sub(pool, loss_offset);
    v[TT_CGT_USED] = simlev_add(v[TT_CGT_USED], loss_offset);
    const double after = simlev_sub(taxable, loss_offset);
    double spb_offset = 0.0;
    const double spb_rem = v[TT_SPB_REM];
    if (use_spb && spb_rem > 0) {
      spb_offset = std::min(after, spb_rem);
      v[TT_SPB_REM] = simlev_sub(spb_rem, spb_offset);
      v[TT_SPB_USED] = simlev_add(v[TT_SPB_USED], spb_offset);
    }
    const double taxable_gain = simlev_sub(after, spb_offset);
    v[TT_CGT_BASE] = simlev_add(v[TT_CGT_BASE], std::max(0.0, taxable_gain));
    const double tax = std::max(0.0, simlev_mul(taxable_gain, eff_rate));
    return TaxRes{tax, spb_offset};
  }

  // ── Signale (.calculate_buy_signal, .calculate_sell_signal) ──
  lgl sig_true(const double* v, int logical, int t) const {   // isTRUE(signal[t])
    return r_bool(logical && v[t - 1] == 1.0);
  }
  bool buy_signal(int a, int t) {
    const AssetIn& A = in[a];
    const Status& s = st[a];
    bool sig = false;
    const lgl is_sig = r_bool(A.style == 1), is_bnh = r_bool(A.style == 0);
    if (cond(r_and(r_and(r_and(is_sig, r_lgl(A.sig_buy[t - 1])), r_gt(s.money, 0)), r_eq(s.count, 0)),
             C_BUYSIG_1, t, a))
      sig = true;
    if (cond(r_and(r_and(r_and(is_sig, r_gt(s.count, 0)), r_gt(s.money, 0)), r_not(sig_true(A.sig_sell, A.sell_logical, t))),
             C_BUYSIG_2, t, a))
      sig = true;
    if (cond(r_and(is_bnh, r_gt(s.money, 0)), C_BUYSIG_3, t, a)) sig = true;
    return sig;
  }
  bool sell_signal(int a, int t) {
    const AssetIn& A = in[a];
    bool sig = false;
    if (cond(r_and(r_and(r_bool(A.style == 1), r_lgl(A.sig_sell[t - 1])), r_gt(st[a].count, 0)), C_SELLSIG, t, a))
      sig = true;
    if (A.style == 0) sig = false;
    return sig;
  }

  // ── .perform_trade_buy (count = NULL) ──
  void perform_buy(int a, int t, int site, int reason) {
    const AssetIn& A = in[a];
    const double mp = px[a][t - 1];
    if (std::isnan(mp) || mp <= 0) {
      warn(EV_BUY_PRICE, site, t, a, mp);
      return;
    }
    double tp = spread_buy(mp, A.spread);
    double tc = fractions ? simlev_div(st[a].money, tp) : std::floor(simlev_div(st[a].money, tp));
    if (fee_cur != nullptr) {
      const Fee& f = *fee_cur;
      const double money = st[a].money;
      const double vol = fee_volume(f, money, t, a);
      tc = fractions ? vol / tp : std::floor(vol / tp);
      if (cond(r_le(tc, 0), C_BUY_TC_FEE, t, a)) return;
      const double fp = fee_amount(f, tc * tp);
      tp = tp + fp / tc;
      fee_paid = fee_paid + fp;
    }
    if (cond(r_le(tc, 0), C_BUY_TC, t, a)) return;
    buy_report(a, t, tc, tp, mp);
    buys[a].push_back(Lot{day[t - 1], tc, tp, tc, tc, 0.0, 0});
    detail(DT_BUY, t, a, {tc, tp}, reason);
  }

  // ── .perform_trade_sell; ohne Menge (has_count) der ganze Bestand, ohne Preis (has_price) FIFO ──
  void perform_sell(int a, int t, int site, double spread, bool has_count = false, double count = 0.0,
                    bool has_price = false, double price = 0.0) {
    const AssetIn& A = in[a];
    const double mp = px[a][t - 1];
    double tp = spread_sell(mp, spread);
    const double available = st[a].count;
    double tc;
    if (!has_count) {
      tc = available;
    } else {
      if (cond(r_gt(count, available), C_SELL_EXCESS, t, a)) warn(EV_SELL_EXCESS, site, t, a, count, available);
      tc = r_min2(count, available);
    }
    if (cond(r_le(tc, 0), C_SELL_TC, t, a)) return;
    if (fee_cur != nullptr) {
      const double fp = fee_amount(*fee_cur, tc * tp);
      if (cond(r_le(tc * tp - fp, 0), C_SELL_FEE, t, a)) return;
      tp = tp - fp / tc;
      fee_paid = fee_paid + fp;
    }
    const double fifo_p = (!has_price && person) ? fifo_price(a, tc) : (has_price ? price : 0.0);
    const double gain = simlev_mul(simlev_sub(tp, fifo_p), tc);
    double tax = 0.0;
    double exempt = 0.0;
    int has_exempt = 0;
    const int regime = person ? A.regime : RG_NONE;
    if (regime == RG_FUND) {
      const double vp_paid = fifo_vp(a, tc);
      const TaxRes r = p20_tax(T, simlev_sub(gain, vp_paid), A.bonus);
      tax = r.tax;
      if (det()) {
        if (cond(r_gt(vp_paid, 0), C_D_VP, t, a)) detail(DT_SELL_VP, t, a, {vp_paid});
        if (cond(r_gt(r.spb_used, 0), C_D_SPB, t, a)) detail(DT_SELL_SPB, t, a, {r.spb_used, T.v[TT_SPB_REM]});
      }
    } else if (regime == RG_CG) {
      tax = p20_tax(T, gain, 0.0).tax;
    } else if (regime == RG_PS) {
      const PSTax lr = private_sale_tax(a, tc, tp, (int) day[t - 1]);
      if (det()) {
        if (cond(r_gt(lr.exempt_gain, 0), C_D_EXG, t, a)) detail(DT_SELL_EXG, t, a, {lr.exempt_gain});
        if (cond(r_gt(lr.exempt_loss, 0), C_D_EXL, t, a)) detail(DT_SELL_EXL, t, a, {lr.exempt_loss});
      }
      const double net_by = simlev_sub(lr.taxable_gain, lr.taxable_loss);
      if (cond(r_ne(net_by, 0), C_PS_NET, t, a)) {
        bool found = false;
        for (auto& p : T.ps_net_by)
          if (p.first == a) {
            p.second = simlev_add(p.second, net_by);
            found = true;
          }
        if (!found) T.ps_net_by.emplace_back(a, simlev_add(0.0, net_by));
      }
      if (cond(r_gt(lr.taxable_gain, 0), C_PS_GAIN, t, a)) {
        T.v[TT_PS_GAINS] = simlev_add(T.v[TT_PS_GAINS], lr.taxable_gain);
        detail(DT_SELL_TXG, t, a, {lr.taxable_gain, T.v[TT_PS_GAINS]});
      }
      if (cond(r_gt(lr.taxable_loss, 0), C_PS_LOSS, t, a)) {
        T.v[TT_PS_LOSSES] = simlev_add(T.v[TT_PS_LOSSES], lr.taxable_loss);
        detail(DT_SELL_TXL, t, a, {lr.taxable_loss, T.v[TT_PS_LOSSES]});
      }
      exempt = lr.exempt_gain;
      has_exempt = 1;
    }
    sell_report(a, t, tc, tp, mp, tax);
    if (person) fifo_consume(a, tc);
    detail(DT_SELL, t, a, {tc, tp}, sell_reason(site));
    if (regime == RG_FUND || regime == RG_CG) detail(DT_SELL_GAIN, t, a, {gain, tax});
    sells[a].push_back(Sell{day[t - 1], tc, tp, gain, tax, exempt, regime, has_exempt});
  }

  // ── .buy_with_fee (sim_actions.R) ──
  void buy_with_fee(int a, int t, int reason) {
    if (fees_on && has(t, F_DCA) && in[a].style == 0) {
      const double money = st[a].money;
      const double dca_part = r_min2(r_max2(0.0, rep[a].flows[t - 1]), money);
      if (t == 1 && cond(r_gt(money - dca_part, 0.005), C_BWF_START, t, a)) {
        fee_cur = fee_ptr(fee_order);
        st[a].money = money - dca_part;
        perform_buy(a, t, S_BUY_FEE_START, reason);
        st[a].money = st[a].money + dca_part;
      }
      fee_cur = fee_ptr(fee_dca);
    }
    perform_buy(a, t, S_BUY_FEE, reason);
    if (fees_on) fee_cur = fee_ptr(fee_order);
  }

  // ── sell_count (core/tax_core_impl.h): Menge und FIFO-Preis fuer einen Ziel-Nettoerloes ──
  static double fifo_fast(double units, const std::vector<double>& cu, const std::vector<double>& cc,
                          const std::vector<double>& prices) {
    const int nl = (int) cu.size();
    if (units <= 0) return 0.0;
    if (units >= cu[nl - 1]) return simlev_div(cc[nl - 1], cu[nl - 1]);
    int lot = 0;
    while (lot < nl && cu[lot] < units) ++lot;
    const int lot_idx = std::min(lot + 1, nl);
    if (lot_idx == 1) return prices[0];
    const double prev_cost = cc[lot_idx - 2];
    const double prev_units = cu[lot_idx - 2];
    const double rem = simlev_sub(units, prev_units);
    return simlev_div(simlev_add(prev_cost, simlev_mul(rem, prices[lot_idx - 1])), units);
  }
  struct Neumaier {
    double s = 0.0, c = 0.0;
    void add(double v) {
      const double t = simlev_add(s, v);
      if (std::fabs(s) >= std::fabs(v)) c = simlev_add(c, simlev_add(simlev_sub(s, t), v));
      else c = simlev_add(c, simlev_add(simlev_sub(v, t), s));
      s = t;
    }
    double value() const { return simlev_add(s, c); }
  };
  void sell_count(int a, double target, double trade_price, double total_shares, bool fr, int regime,
                  double bonus, double loss_pool, double tax_rate, double& out_count, double& out_fp) {
    out_count = 0.0;
    out_fp = 0.0;
    const std::vector<Lot>& b = buys[a];
    std::vector<double>& units = buf2;
    std::vector<double>& prices = buf3;
    std::vector<double>& vpu = buf5;
    units.clear();
    prices.clear();
    vpu.clear();
    bool any_vp = false;
    for (int i = front[a]; i <= (int) b.size(); ++i) {
      const Lot& l = b[i - 1];
      const double rem = l.remaining;
      if (rem > 0) {
        units.push_back(rem);
        prices.push_back(l.price);
        const double lot_vp = l.has_vp ? l.vp : 0.0;
        const double v = (regime == RG_FUND && lot_vp > 0) ? simlev_div(lot_vp, rem) : 0.0;
        if (v > 0) any_vp = true;
        vpu.push_back(v);
      }
    }
    if (units.empty()) return;
    const int nl = (int) units.size();
    std::vector<double> cu((std::size_t) nl), cc((std::size_t) nl), cv((std::size_t) nl);
    Neumaier su, sc, sv;
    for (int i = 0; i < nl; ++i) {
      su.add(units[i]);
      cu[i] = su.value();
      sc.add(simlev_mul(units[i], prices[i]));
      cc[i] = sc.value();
      sv.add(simlev_mul(units[i], vpu[i]));
      cv[i] = sv.value();
    }
    auto fvp = [&](double sell) -> double {
      if (!any_vp || sell <= 0) return 0.0;
      if (sell >= cu[nl - 1]) return cv[nl - 1];
      int lot = 0;
      while (lot < nl && cu[lot] < sell) ++lot;
      if (lot >= nl) lot = nl - 1;
      const double prev_u = lot > 0 ? cu[lot - 1] : 0.0, prev_v = lot > 0 ? cv[lot - 1] : 0.0;
      return simlev_add(prev_v, simlev_mul(simlev_sub(sell, prev_u), vpu[lot]));
    };
    auto objective = [&](double sell) -> double {
      if (sell <= 0) return -target;
      if (sell > total_shares) sell = total_shares;
      const double fp = fifo_fast(sell, cu, cc, prices);
      const double gain = simlev_mul(simlev_sub(trade_price, fp), sell);
      double tax = 0.0;
      if (regime == RG_FUND) {
        const double adj = simlev_mul(simlev_sub(gain, fvp(sell)), 1.0 - bonus);
        tax = simlev_mul(std::max(simlev_sub(adj, loss_pool), 0.0), tax_rate);
      } else if (regime == RG_CG) {
        tax = simlev_mul(std::max(simlev_sub(gain, loss_pool), 0.0), tax_rate);
      }
      return simlev_sub(simlev_sub(simlev_mul(sell, trade_price), tax), target);
    };
    const double initial = simlev_div(target, trade_price);
    double lower = std::max(1e-6, initial * 0.1);
    double upper = std::min(initial * 3.0, total_shares);
    double f_lower = objective(lower);
    double f_upper = objective(upper);
    const double tol = fr ? 1e-6 : 0.5;
    double sell;
    if (f_lower >= 0) {
      sell = lower;
    } else if (f_upper <= 0) {
      sell = upper;
    } else if (std::fabs(f_lower) < tol) {
      sell = lower;
    } else if (std::fabs(f_upper) < tol) {
      sell = upper;
    } else {
      sell = simlev_add(lower, upper) * 0.5;
      for (int it = 0; it < 30; ++it) {
        const double mid = simlev_add(lower, upper) * 0.5;
        const double fm = objective(mid);
        if (std::fabs(fm) < tol || simlev_sub(upper, lower) < tol) {
          sell = mid;
          break;
        }
        if (simlev_mul(fm, f_lower) < 0) {
          upper = mid;
          f_upper = fm;
        } else {
          lower = mid;
          f_lower = fm;
        }
        sell = simlev_add(lower, upper) * 0.5;
      }
    }
    if (!fr) {
      double tl = std::floor(sell), tu = std::ceil(sell);
      if (tl < 1) tl = 1;
      if (tu > total_shares) tu = total_shares;
      sell = (std::fabs(objective(tl)) <= std::fabs(objective(tu))) ? tl : tu;
    }
    out_fp = fifo_fast(sell, cu, cc, prices);
    out_count = std::max(0.0, std::min(sell, total_shares));
  }
  // .calculate_sell_count (tax_rate = effective_tax_rate wie alle Aufrufer)
  void calculate_sell_count(int a, double target, int t, bool fr, double& cnt, double& fp) {
    const double mp = px[a][t - 1];
    const double tp = spread_sell(mp, in[a].spread);
    const double total_shares = st[a].count;
    cnt = 0.0;
    fp = 0.0;
    if (cond(r_le(total_shares, 0), C_SC_SHARES, t, a)) return;
    if (cond(r_le(target, 0), C_SC_TARGET, t, a)) return;
    const int regime = person ? in[a].regime : RG_NONE;
    const double bonus = regime == RG_FUND ? in[a].bonus : 0.0;
    const double loss_pool = simlev_add(T.v[TT_LOSS_CG], r_max2(0.0, T.v[TT_SPB_REM]));
    sell_count(a, target, tp, total_shares, fr, regime, bonus, loss_pool, eff_rate, cnt, fp);
  }

  // ── Zahlungen (sim_actions.R) ──
  // .sell_count_net: has_fp = false, wenn R fifo_price = NULL liefert (Aufrunden fuer eine Zahlung)
  void sell_count_net(int a, double need, int t, bool round_up, double& cnt, double& fp, bool& has_fp) {
    const bool fr = fractions || round_up;
    double target = need;
    if (fee_cur != nullptr) {
      const double p = spread_sell(px[a][t - 1], in[a].spread);
      for (int k = 0; k < 3; k++) {
        double c, f;
        calculate_sell_count(a, target, t, fr, c, f);
        target = simlev_add(need, fee_amount(*fee_cur, r_max2(c, 1e-12) * p));
      }
    }
    calculate_sell_count(a, target, t, fr, cnt, fp);
    has_fp = true;
    if (cond(r_and(r_bool(round_up && !fractions), r_gt(cnt, 0)), C_SCN_ROUND, t, a)) {
      cnt = r_min2(st[a].count, std::ceil(cnt - 1e-9));
      has_fp = false;
    }
  }

  // .pay_one: Rueckgabe nicht gedeckter Rest; label (LBL_*) und Jahre nur fuer die details-Ausgabe
  double pay_one(int a, double amount, int t, int label, const std::vector<int>* years) {
    const double money = st[a].money;
    if (cond(r_ge(money, amount), C_PO_CASH, t, a)) {
      st[a].money = simlev_sub(money, amount);
      detail(DT_PAY_CASH, t, a, {amount}, label, years);
      return 0.0;
    }
    double remaining = amount;
    if (cond(r_gt(money, 0), C_PO_PART, t, a)) {
      remaining = simlev_sub(amount, money);
      st[a].money = 0.0;
      detail(DT_PAY_PART, t, a, {money}, label, years);
    }
    const double c0 = st[a].money;
    auto raised = [&]() { return simlev_sub(st[a].money, c0); };
    for (int k = 1; k <= 10; k++) {
      const double shrt = simlev_sub(remaining, raised());
      const lgl l1 = r_le(shrt, 0.005);
      if (cond(l1 == 1 ? 1 : r_or(l1, r_le(st[a].count, 0)), C_PO_LOOP, t, a)) break;
      double n_sell, fp;
      bool has_fp;
      sell_count_net(a, shrt, t, true, n_sell, fp, has_fp);
      if (cond(k > 1 ? 1 : r_not(r_gt(n_sell, 0)), C_PO_MIN, t, a)) {
        const double c = st[a].count;
        n_sell = r_max2(n_sell, fractions ? r_min2(c, 1e-6) : r_min2(1.0, c));
      }
      const double before = raised();
      perform_sell(a, t, S_SELL_TAX, in[a].spread, true, n_sell, has_fp, fp);
      if (cond(r_le(raised(), before), C_PO_RAISED, t, a)) break;
    }
    const double shrt = simlev_sub(remaining, raised());
    double unpaid = 0.0;
    if (cond(r_le(shrt, 0.005), C_PO_SHORT, t, a)) {
      st[a].money = simlev_sub(st[a].money, remaining);
    } else {
      st[a].money = c0;
      unpaid = shrt;
    }
    if (det() && cond(r_gt(simlev_sub(remaining, unpaid), 0), C_D_PAID, t, a))
      detail(DT_PAY_SOLD, t, a, {simlev_sub(remaining, unpaid)}, label, years);
    return unpaid;
  }

  // .pay_tax: label (LBL_*) und Jahre der Veranlagung nur fuer die Warnung
  void pay_tax(int a, double amount, int t, int label, const std::vector<int>* years = nullptr) {
    double unpaid = pay_one(a, amount, t, label, years);
    if (cond(r_gt(unpaid, 1e-6), C_PT_UNPAID1, t, a)) {
      std::vector<int> others;
      std::vector<double> val;
      for (int b = 0; b < na; b++) {
        if (b == a) continue;
        others.push_back(b);
        val.push_back(simlev_add(simlev_mul(st[b].count, px[b][t - 1]), r_max2(0.0, st[b].money)));
      }
      std::vector<int> ord(others.size());
      for (std::size_t i = 0; i < ord.size(); i++) ord[i] = (int) i;
      std::stable_sort(ord.begin(), ord.end(), [&](int i, int j) {   // order(-val): absteigend, NA zuletzt
        const double x = -val[i], y = -val[j];
        if (std::isnan(x)) return false;
        if (std::isnan(y)) return true;
        return x < y;
      });
      for (int i : ord) {
        if (cond(r_le(unpaid, 1e-6), C_PT_DONE, t, a)) break;
        if (cond(r_not(r_gt(val[i], 0)), C_PT_VAL, t, a)) continue;
        unpaid = pay_one(others[i], unpaid, t, label, years);
      }
    }
    if (cond(r_gt(unpaid, 1e-6), C_PT_UNPAID2, t, a)) {
      st[a].money = simlev_sub(st[a].money, unpaid);
      tax_unpaid = simlev_add(tax_unpaid, unpaid);
      warn(EV_TAX_UNPAID, 0, t, a, amount, unpaid, label, years);
    }
  }

  void pay_vp(int a, double tax_debt, int t, const VPPend& p, double spb_used, double prepaid) {
    if (cond(r_eq(prepaid, 0), C_PV_ZERO, t, a)) {
      pay_tax(a, tax_debt, t, LBL_VP);
    } else if (cond(r_gt(simlev_sub(tax_debt, prepaid), 1e-9), C_PV_MORE, t, a)) {
      pay_tax(a, simlev_sub(tax_debt, prepaid), t, LBL_VP);
    } else if (cond(r_lt(simlev_sub(tax_debt, prepaid), -1e-9), C_PV_LESS, t, a)) {
      st[a].money = simlev_add(st[a].money, simlev_sub(prepaid, tax_debt));
    }
    T.v[TT_TOTAL_TAXES] = simlev_add(T.v[TT_TOTAL_TAXES], tax_debt);
    taxes[a].push_back(TaxEntry{1, day[t - 1], p.assessment_date, p.flat_rate, p.bonus,
                                p.flat_rate * (1 - p.bonus), spb_used, tax_debt});
  }

  void settle_p23(int t) {
    std::vector<std::pair<int, double>> due;
    due.swap(T.p23_due);
    std::vector<int> years;
    std::vector<DueInfo> info;
    if (tariff_on) info.swap(due_info);
    due_info.clear();
    for (const DueInfo& d : info) years.push_back(d.year);
    const int label = years.empty() ? LBL_P23 : LBL_VERANLAGUNG;
    if (det() && !info.empty()) {
      lgl any = 0;                     // any(due > 0) wie R: TRUE vor NA
      for (const auto& p : due) {
        const lgl g = r_gt(p.second, 0);
        if (g == 1) { any = 1; break; }
        if (g == 2) any = 2;
      }
      if (cond(any, C_D_DUE, t, -1)) {
        for (const DueInfo& d : info) {
          const double rest = simlev_sub(simlev_sub(d.D, d.p23), d.ded);
          const int has_rest = cond(r_ge(std::fabs(rest), 0.005), C_D_REST, t, -1) ? 1 : 0;
          detail(DT_P23_VERANL, t, -1, {(double) d.year, d.D, d.p23, d.ded, rest}, has_rest | (d.by_p23 ? 2 : 0));
        }
      }
    }
    for (const auto& p : due) {
      if (cond(r_not(r_gt(p.second, 0)), C_P23_DUE, t, p.first)) continue;
      detail(info.empty() ? DT_P23_TAX : DT_P23_SHARE, t, p.first, {p.second});
      pay_tax(p.first, p.second, t, label, &years);
      taxes[p.first].push_back(TaxEntry{2, day[t - 1], SIMLEV_NA_REAL, SIMLEV_NA_REAL, SIMLEV_NA_REAL, SIMLEV_NA_REAL,
                                        SIMLEV_NA_REAL, p.second});
    }
  }

  bool gp_pending() const { return tariff_on && refund_due > 0; }
  // Gewichte 'actual' (normiert; ohne positive Summe gleich verteilt) fuer Erstattungen
  void refund_weights(std::vector<double>& w, int site, int t) {
    w.resize((std::size_t) na);
    for (int a = 0; a < na; a++) w[a] = st[a].actual;
    const double sw = sl_r_sum(na, w.data(), 0);
    if (cond(r_gt(sw, 0), site, t, -1)) {
      for (int a = 0; a < na; a++) w[a] = simlev_div(w[a], sw);
    } else {
      for (int a = 0; a < na; a++) w[a] = 1.0 / na;
    }
  }
  void settle_gp(int t) {
    const double refund = refund_due;
    refund_due = 0.0;
    std::vector<double>& w = buf4;
    refund_weights(w, C_GP_W, t);
    for (int a = 0; a < na; a++) st[a].money = simlev_add(st[a].money, simlev_mul(refund, w[a]));
    detail(DT_GP_REFUND, t, -1, {refund});
  }

  std::vector<TaxRes> vp_taxes(Totals& X, const std::vector<VPPend>& pend, int t) {
    std::vector<TaxRes> res(pend.size(), TaxRes{0.0, 0.0});
    const int np = (int) pend.size();
    if (np > 1) {
      std::vector<double> taxable((std::size_t) np);
      for (int j = 0; j < np; j++) taxable[j] = pend[j].flat_rate * (1 - pend[j].bonus);
      const double s = sl_r_sum(np, taxable.data(), 0);
      const TaxRes pooled = vp_tax(X, s, 0.0);
      const bool pos = cond(r_gt(s, 0), C_VT_SHARE, t, -1);
      for (int j = 0; j < np; j++) {
        const double share = pos ? simlev_div(taxable[j], s) : 1.0 / np;
        res[j] = TaxRes{simlev_mul(pooled.tax, share), simlev_mul(pooled.spb_used, share)};
      }
    } else if (np == 1) {
      res[0] = vp_tax(X, pend[0].flat_rate, pend[0].bonus);
    }
    return res;
  }

  void settle_vp(int t, const std::vector<double>* prepaid) {
    std::vector<VPPend> pend;
    pend.swap(T.vp_pending);
    const std::vector<TaxRes> res = vp_taxes(T, pend, t);
    for (std::size_t j = 0; j < pend.size(); j++) {
      const double pre = prepaid ? (*prepaid)[j] : 0.0;
      detail(DT_VP_SETTLE, t, pend[j].asset, {pend[j].assessment_date, pend[j].flat_rate,
                                              pend[j].flat_rate * (1 - pend[j].bonus), res[j].spb_used, res[j].tax});
      const lgl c1 = r_gt(res[j].tax, 0);
      if (cond(c1 == 1 ? 1 : r_or(c1, r_gt(pre, 0)), C_SV_PAY, t, pend[j].asset))
        pay_vp(pend[j].asset, res[j].tax, t, pend[j], res[j].spb_used, pre);
    }
  }

  // ── Tarifweg (.tariff_close, .tariff_book, .book_tax_due) ──
  double ks_get(int year) const {
    for (const auto& p : ks)
      if (p.first == year) return std::isnan(p.second) ? 0.0 : p.second;
    return 0.0;
  }
  void ks_set(int year, double v) {
    for (auto& p : ks)
      if (p.first == year) {
        p.second = v;
        return;
      }
    ks.emplace_back(year, v);
  }
  double zve_of(int year) const {
    if (has_zve_all) return zve_all;
    for (const auto& p : zve)
      if (p.first == year) return p.second;
    return SIMLEV_NA_REAL;
  }
  double tariff_close(int year, double g23, double k_base, double abg_rate, int t) {
    const double z = zve_of(year);
    if (std::isnan(z)) return SIMLEV_NA_REAL;
    std::array<double, simlev::TR_N> row{};
    double ks_next = 0.0;
    const double D = tariff.close(z, ks_get(year), g23, k_base, abg_rate, SIMLEV_NA_REAL, row.data(), ks_next);
    row[simlev::TR_YEAR] = year;
    ks_set(year + 1, ks_next);
    rows.push_back(row);
    if (det()) {   // aux: Bit 0 use_gp, Bit 1 Zeile zum § 23-Gewinn (g23 > 0)
      const int with23 = cond(r_gt(g23, 0), C_D_G23, t, -1) ? 2 : 0;
      detail_v(DT_TARIFF, t, -1, row.data(), simlev::TR_N, (tariff.use_gp ? 1 : 0) | with23);
    }
    return D;
  }
  void positive_by(const Totals& X, std::vector<std::pair<int, double>>& by) const {
    by.clear();
    for (const auto& p : X.ps_net_by)
      if (std::isfinite(p.second)) by.emplace_back(p.first, p.second < 0 ? 0.0 : p.second);
  }
  static double sum_by(const std::vector<std::pair<int, double>>& by) {
    std::vector<double> v;
    for (const auto& p : by) v.push_back(p.second);
    return sl_r_sum((int64_t) v.size(), v.data(), 0);
  }
  void book_tax_due(Totals& X, double tax_due) const {
    std::vector<std::pair<int, double>> by;
    positive_by(X, by);
    if (by.empty() || sum_by(by) <= 0) {
      by.clear();
      for (int a = 0; a < na; a++) by.emplace_back(a, 1.0);
    }
    const double s = sum_by(by);
    std::vector<std::pair<int, double>> due;
    for (const auto& p : by) due.emplace_back(p.first, simlev_div(simlev_mul(tax_due, p.second), s));
    if (!X.p23_due.empty()) {
      std::vector<std::pair<int, double>> m = X.p23_due;
      for (const auto& d : due) {
        bool found = false;
        for (auto& q : m)
          if (q.first == d.first) {
            q.second = simlev_add(q.second, d.second);
            found = true;
          }
        if (!found) m.emplace_back(d.first, simlev_add(0.0, d.second));
      }
      due.swap(m);
    }
    X.p23_due.swap(due);
  }
  void tariff_book(Totals& X, double D, int t) {
    if (std::isnan(D) || D == 0) return;
    X.v[TT_TOTAL_TAXES] = simlev_add(X.v[TT_TOTAL_TAXES], D);
    if (D > 0) {
      const auto& rw = rows.back();
      std::vector<std::pair<int, double>> by;
      positive_by(X, by);
      due_info.push_back(DueInfo{(int) rw[simlev::TR_YEAR], D, rw[simlev::TR_TAX23], rw[simlev::TR_DED],
                                 (!by.empty() && sum_by(by) > 0) ? 1 : 0});
      book_tax_due(X, D);
    } else {
      refund_due = refund_due - D;
      if (cond(r_lt(std::fabs(X.v[TT_TOTAL_TAXES]), 1e-9), C_TB_TOT, t, -1)) X.v[TT_TOTAL_TAXES] = 0.0;
    }
  }

  // ── .handle_year_change (auf X und S; with_tariff = Tarifweg, quiet = Probelauf) ──
  void year_change(Totals& X, std::vector<Status>& S, int current_year, bool with_tariff, int t) {
    double* v = X.v;
    const int stored_year = (int) v[TT_CURRENT_YEAR];
    if (current_year == stored_year) return;
    detail(DT_YC_HEAD, t, -1, {(double) stored_year, (double) current_year});
    const double ytd_gains = v[TT_PS_GAINS], ytd_losses = v[TT_PS_LOSSES];
    const double net_saldo = simlev_sub(ytd_gains, ytd_losses);
    const double net_ytd_losses = r_max2(0.0, -net_saldo);
    double net_gain = 0.0, cf = 0.0;
    if (cond(r_and(r_ge(net_saldo, ps_threshold), r_gt(net_saldo, 0)), C_YC_SALDO, t, -1)) {
      cf = r_min2(net_saldo, v[TT_LOSS_PS]);
      v[TT_LOSS_PS] = simlev_sub(v[TT_LOSS_PS], cf);
      net_gain = simlev_sub(net_saldo, cf);
      if (det() && cond(r_gt(cf, 0), C_D_CARRY, t, -1)) detail(DT_YC_CARRY, t, -1, {cf, v[TT_LOSS_PS]});
    }
    if (det())
      detail(DT_YC_SUMMARY, t, -1, {(double) stored_year, ytd_gains, ytd_losses, r_min2(ytd_gains, ytd_losses), cf,
                                    simlev_sub(net_saldo, cf)});
    if (cond(r_gt(net_gain, 0), C_YC_GAIN, t, -1)) {
      double mtr = marginal, tax_due = 0.0;
      if (!with_tariff) {
        if (!has_marginal) {
          warn(EV_MARGINAL, 0, t, -1, net_saldo, ps_threshold);
          mtr = 0.42;
        }
        tax_due = net_gain * mtr * (soli_factor + church_k);
        v[TT_TOTAL_TAXES] = simlev_add(v[TT_TOTAL_TAXES], tax_due);
        book_tax_due(X, tax_due);
      }
      detail(DT_YC_LIMIT, t, -1, {net_saldo, ps_threshold, net_gain, mtr, soli_factor, church_k, tax_due},
             with_tariff ? 1 : 0);
    } else if (cond(r_gt(net_ytd_losses, 0), C_YC_LOSS, t, -1)) {
      v[TT_LOSS_PS] = simlev_add(v[TT_LOSS_PS], net_ytd_losses);
      detail(DT_YC_LOSS, t, -1, {net_ytd_losses, v[TT_LOSS_PS]});
    } else if (cond(r_and(r_gt(net_saldo, 0), r_lt(net_saldo, ps_threshold)), C_YC_FREE, t, -1)) {
      detail(DT_YC_FREE, t, -1, {net_saldo, ps_threshold});
    } else {
      detail(DT_YC_NONE, t, -1, {(double) stored_year});
    }
    if (use_spb && det())
      detail(DT_YC_SPB, t, -1, {(double) stored_year, v[TT_SPB_ANNUAL], simlev_sub(v[TT_SPB_ANNUAL], v[TT_SPB_REM]),
                                v[TT_SPB_REM]});
    const double cgt_added = v[TT_CGT_ADDED], cgt_used = v[TT_CGT_USED], cgt_base = v[TT_CGT_BASE];
    const double carry_start = v[TT_CGT_POOL_START];
    double carry_used = 0.0;
    if (cond(r_gt(carry_start, 0), C_YC_CARRY, t, -1)) {
      const double spb_used_ytd = use_spb ? r_max2(0.0, simlev_sub(v[TT_SPB_ANNUAL], v[TT_SPB_REM])) : 0.0;
      carry_used = r_min2(carry_start,
                          r_max2(0.0, simlev_sub(simlev_add(simlev_add(cgt_used, spb_used_ytd), cgt_base), cgt_added)));
    }
    double unused_loss = r_max2(0.0, simlev_sub(cgt_added, simlev_sub(cgt_used, carry_used)));
    unused_loss = r_min2(unused_loss, v[TT_LOSS_CG]);
    const double refund_base = r_min2(unused_loss, cgt_base);
    const bool refund_done = cond(r_and(r_gt(refund_base, 0), r_gt(eff_rate, 0)), C_YC_REFUND, t, -1);
    if (refund_done) {
      const double refund = simlev_mul(refund_base, eff_rate);
      std::vector<double> w((std::size_t) na);
      for (int a = 0; a < na; a++) w[a] = S[a].actual;
      const double sw = sl_r_sum(na, w.data(), 0);
      if (cond(r_gt(sw, 0), C_YC_W, t, -1)) {
        for (int a = 0; a < na; a++) w[a] = simlev_div(w[a], sw);
      } else {
        for (int a = 0; a < na; a++) w[a] = 1.0 / na;
      }
      for (int a = 0; a < na; a++) S[a].money = simlev_add(S[a].money, simlev_mul(refund, w[a]));
      v[TT_TOTAL_TAXES] = simlev_sub(v[TT_TOTAL_TAXES], refund);
      v[TT_LOSS_CG] = simlev_sub(v[TT_LOSS_CG], refund_base);
      detail(DT_YC_REFUND, t, -1, {refund});
    }
    if (use_spb) {
      const double spb_used_year = r_max2(0.0, simlev_sub(v[TT_SPB_ANNUAL], v[TT_SPB_REM]));
      const double taxed_left = simlev_sub(cgt_base, refund_done ? refund_base : 0.0);
      const double release = r_max2(0.0, r_min2(spb_used_year, simlev_sub(v[TT_LOSS_CG], taxed_left)));
      if (cond(r_gt(release, 0), C_YC_REL, t, -1)) {
        v[TT_LOSS_CG] = simlev_sub(v[TT_LOSS_CG], release);
        v[TT_SPB_REM] = simlev_add(v[TT_SPB_REM], release);
        v[TT_SPB_USED] = simlev_sub(v[TT_SPB_USED], release);
        detail(DT_YC_RELEASE, t, -1, {release, (double) stored_year, simlev_sub(spb_used_year, release), v[TT_LOSS_CG]});
      }
    }
    bool any_refund = refund_done;
    if (with_tariff) {
      const double k_base = r_max2(0.0, simlev_sub(cgt_base, refund_done ? refund_base : 0.0));
      const double D = tariff_close(stored_year, net_gain, k_base, eff_rate, t);
      tariff_book(X, D, t);
      if (!std::isnan(D) && D < 0) any_refund = true;
    }
    if (cond(r_and(r_bool(any_refund), r_lt(std::fabs(v[TT_TOTAL_TAXES]), 1e-9)), C_YC_TOT, t, -1))
      v[TT_TOTAL_TAXES] = 0.0;
    v[TT_PS_GAINS] = 0.0;
    v[TT_PS_LOSSES] = 0.0;
    for (auto& p : X.ps_net_by) p.second = 0.0;
    v[TT_CGT_BASE] = 0.0;
    v[TT_CGT_ADDED] = 0.0;
    v[TT_CGT_USED] = 0.0;
    v[TT_CGT_POOL_START] = v[TT_LOSS_CG];
    if (use_spb) v[TT_SPB_REM] = spb;
    v[TT_CURRENT_YEAR] = current_year;
    detail(DT_YC_END, t, -1, {(double) current_year});
  }

  // ── Tagesschritte (sim_loop.R) ──
  bool day_activate(int t) {
    bool late_now = false;
    for (int a = 0; a < na; a++)
      if (in[a].start_day == t && !in[a].initial) late_now = true;
    bool rebalance_now = false;
    if (balance_mode || late_now) {
      buf.clear();
      for (int a : active) buf.push_back(st[a].actual);
      const double cws = sl_r_sum((int64_t) buf.size(), buf.data(), 0);
      for (int a : active) st[a].differ = simlev_div(st[a].actual, cws);
      if (det()) {
        std::vector<int> nw;
        for (int a = 0; a < na; a++)
          if (in[a].start_day == t) nw.push_back(a);
        if (!nw.empty()) detail(DT_ACTIVATE, t, -1, {}, 0, &nw);
      }
      rebalance_now = true;
    }
    total_report(t);
    return rebalance_now;
  }

  // .sim_day_split mit .perform_asset_split (Lots, Status und Kursreihe exakt umrechnen)
  void asset_split(int a, double ratio, bool forward, int t) {
    if (cond(r_le(ratio, 0), C_SPLIT_RATIO, t, a))
      throw NAError(forward ? S_SPLIT_FWD : S_SPLIT_REV, t, a, EV_SPLIT_RATIO, ratio);
    Status& s = st[a];
    const double cc = s.count, cp = s.price, cw = s.worth;
    for (Lot& b : buys[a]) {
      if (b.remaining <= 0) continue;
      const double orig = b.original;
      if (forward) {
        b.count = b.count * ratio;
        b.price = b.price / ratio;
        b.remaining = b.remaining * ratio;
        b.original = orig * ratio;
      } else {
        b.count = b.count / ratio;
        b.price = b.price * ratio;
        b.remaining = b.remaining / ratio;
        b.original = orig / ratio;
      }
    }
    front[a] = update_front(buys[a]);
    s.count = forward ? cc * ratio : cc / ratio;
    s.price = forward ? cp / ratio : cp * ratio;
    s.worth = cw;
    std::vector<double>& p = px[a];
    if (forward) for (double& x : p) x = x / ratio;
    else for (double& x : p) x = x * ratio;
    px_changed[a] = 1;
    detail(DT_SPLIT, t, a, {ratio}, forward ? 1 : 0);
  }
  void day_split(int t) {
    std::vector<char> held((std::size_t) na, 0);
    for (int a : active) held[a] = st[a].count > 0;
    for (int a = 0; a < na; a++) {
      if (held[a] || in[a].no_split) continue;
      const double px0 = px[a][t - 1];
      const lgl l1 = r_gt(px0, split_hi);
      if (cond(l1 == 1 ? 1 : r_or(l1, r_lt(px0, split_lo)), C_SP_FREE, t, a)) {
        const double r = px0 / 100;
        for (double& x : px[a]) x = x / r;
        px_changed[a] = 1;
        detail(DT_SPLIT_FREE, t, a, {l1 == 1 ? px0 / 100 : 100 / px0}, l1 == 1 ? 1 : 0);
      }
    }
    for (int a : active) {
      if (in[a].no_split) continue;
      if (cond(r_gt(st[a].count, 0), C_SP_HELD, t, a)) {
        const double sp = px[a][t - 1];
        if (cond(r_gt(sp, split_hi), C_SP_FWD, t, a)) asset_split(a, sp / 100, true, t);
        if (cond(r_lt(sp, split_lo), C_SP_REV, t, a)) asset_split(a, 100 / sp, false, t);
        const double cnt = st[a].count;
        const double frac = cnt - std::floor(cnt + 1e-9);
        if (cond(r_and(r_bool(!fractions), r_gt(frac, 1e-9)), C_SP_FRAC, t, a)) {
          const Fee* keep = fee_cur;
          fee_cur = nullptr;
          perform_sell(a, t, S_SELL_SPLIT, 0.0, true, frac);
          fee_cur = keep;
        }
      }
    }
    total_report(t);
  }

  void day_dca(int t) {
    const double dca_amount = dca_value * dca_n[t - 1];
    const int k = (int) active.size();
    std::vector<double>& w = buf4;
    w.resize((std::size_t) k);
    for (int i = 0; i < k; i++) w[i] = in[active[i]].share;
    const double sw = sl_r_sum(k, w.data(), 1);
    for (int i = 0; i < k; i++) w[i] = simlev_div(w[i], sw);
    if (balance_dca && k > 1) {
      total_report(t);
      std::vector<double> totals_now((std::size_t) k), deficit((std::size_t) k), alloc((std::size_t) k);
      for (int i = 0; i < k; i++) totals_now[i] = st[active[i]].total;
      const double base = simlev_add(sl_r_sum(k, totals_now.data(), 1), dca_amount);
      for (int i = 0; i < k; i++) deficit[i] = r_max2(0.0, simlev_sub(simlev_mul(w[i], base), totals_now[i]));
      const double sd = sl_r_sum(k, deficit.data(), 0);
      if (cond(r_gt(sd, dca_amount), C_DCA_DEFICIT, t, -1)) {
        for (int i = 0; i < k; i++) alloc[i] = simlev_div(simlev_mul(dca_amount, deficit[i]), sd);
      } else {
        for (int i = 0; i < k; i++) alloc[i] = simlev_add(deficit[i], simlev_mul(simlev_sub(dca_amount, sd), w[i]));
      }
      for (int i = 0; i < k; i++) dca_flows(active[i], alloc[i], t);
    } else {
      for (int i = 0; i < k; i++) dca_flows(active[i], simlev_mul(w[i], dca_amount), t);
    }
    if (det()) {
      std::vector<double> v(1, dca_amount);
      for (int i = 0; i < k; i++) v.push_back(rep[active[i]].flows[t - 1]);
      detail_v(DT_DCA, t, -1, v.data(), (int) v.size(), 0, &active);
    }
    total_report(t);
  }

  bool day_trade(int t) {
    bool ev = false;
    for (int a : active) {
      const bool fb = buy_signal(a, t);
      const bool fs = sell_signal(a, t);
      if (fb) {
        buy_with_fee(a, t, RS_TRADE);
        ev = true;
      }
      if (fs) {
        perform_sell(a, t, S_SELL_TRADE, in[a].spread);
        ev = true;
      }
    }
    if (ev) total_report(t);
    return ev;
  }

  void day_rebalance(int t) {
    const int k = (int) active.size();
    std::vector<double> targets((std::size_t) k), actual_w((std::size_t) k);
    for (int i = 0; i < k; i++) targets[i] = st[active[i]].actual;
    const double s_at = sl_r_sum(k, targets.data(), 1);
    for (int i = 0; i < k; i++) targets[i] = simlev_div(targets[i], s_at);
    if (has_event_weight && has(t, F_EVENT)) {
      std::vector<double> ow((std::size_t) k);
      bool all_finite = true;
      for (int i = 0; i < k; i++) {
        const double* col = in[active[i]].event_w;
        ow[i] = col ? col[t - 1] : SIMLEV_NA_REAL;
        if (!std::isfinite(ow[i])) all_finite = false;
      }
      if (all_finite) {
        const double so = sl_r_sum(k, ow.data(), 0);
        if (so > 0)
          for (int i = 0; i < k; i++) targets[i] = ow[i] / so;
      }
    }
    std::vector<char> cash_only((std::size_t) na, 0);
    for (int a : active) {
      if (in[a].style != 1) continue;
      const lgl has_pos = r_gt(st[a].count, 0);
      const lgl sb = sig_true(in[a].sig_buy, in[a].buy_logical, t);
      const lgl ss = sig_true(in[a].sig_sell, in[a].sell_logical, t);
      if (cond(r_and(has_pos, ss), C_GATE_EXIT, t, a)) {
        perform_sell(a, t, S_SELL_SIG_EXIT, in[a].spread);
        cash_only[a] = 1;
      } else if (cond(r_and(r_not(has_pos), sb), C_GATE_ENTRY, t, a)) {
        perform_buy(a, t, S_BUY_SIG_ENTRY, RS_SIG_ENTRY);
      } else if (cond(r_and(r_not(has_pos), r_not(sb)), C_GATE_CASH, t, a)) {
        cash_only[a] = 1;
      }
    }
    total_report(t);
    for (int i = 0; i < k; i++) actual_w[i] = st[active[i]].differ;
    bool force = false;
    for (int a = 0; a < na; a++)
      if (in[a].start_day == t) force = true;
    if (force && det()) {
      std::vector<int> nw;
      for (int a = 0; a < na; a++)
        if (in[a].start_day == t) nw.push_back(a);
      detail(DT_REB_FORCE, t, -1, {}, 0, &nw);
    }
    bool ev_reb;
    if (force || !thresh_set) {
      ev_reb = true;
    } else {
      double max_dev = -INFINITY;
      bool any = false;
      std::vector<double> devs((std::size_t) k);
      for (int i = 0; i < k; i++) {
        const double dev = thresh_relative ? std::fabs(simlev_sub(simlev_div(actual_w[i], targets[i]), 1.0))
                                           : std::fabs(simlev_sub(targets[i], actual_w[i]));
        devs[i] = dev;
        if (std::isnan(dev)) continue;
        if (!any || dev > max_dev) max_dev = dev;
        any = true;
      }
      if (!any) warn(EV_MAX_EMPTY, 0, t, -1);
      ev_reb = max_dev > balance_thresh;
      if (det()) {
        if (ev_reb) {
          detail(DT_REB_YES, t, -1, {max_dev * 100, balance_thresh * 100});
          for (int i = 0; i < k; i++)
            if (cond(r_gt(devs[i], balance_thresh), C_D_DEV, t, active[i]))
              detail(DT_REB_ASSET, t, active[i], {targets[i] * 100, actual_w[i] * 100, devs[i] * 100});
        } else {
          detail(DT_REB_NO, t, -1, {max_dev * 100, balance_thresh * 100});
        }
      }
    }
    if (ev_reb) {
      std::vector<double> differ((std::size_t) k), tv((std::size_t) k), tot((std::size_t) k);
      for (int i = 0; i < k; i++) {
        differ[i] = simlev_sub(targets[i], actual_w[i]);
        tot[i] = st[active[i]].total;
      }
      const double total_strategy = sl_r_sum(k, tot.data(), 1);
      double pool = 0.0;
      for (int i = 0; i < k; i++) tv[i] = std::fabs(simlev_mul(differ[i], total_strategy));
      for (int i = 0; i < k; i++) {
        if (!(differ[i] < 0)) continue;
        const int a = active[i];
        const double sell_target = simlev_sub(tv[i], r_max2(0.0, st[a].money));
        if (cond(r_and(r_gt(st[a].count, 0), r_gt(sell_target, 0)), C_REB_SELL, t, a)) {
          double cnt, fp;
          calculate_sell_count(a, sell_target, t, fractions != 0, cnt, fp);
          perform_sell(a, t, S_SELL_REBAL, in[a].spread, true, cnt, true, fp);
        }
        const double available_cash = r_min2(st[a].money, tv[i]);
        pool = simlev_add(pool, available_cash);
        st[a].money = simlev_sub(st[a].money, available_cash);
        detail(DT_REB_POOL_IN, t, a, {available_cash});
      }
      for (int i = 0; i < k; i++) {
        if (!(differ[i] > 0)) continue;
        const int a = active[i];
        const double allocation = r_min2(tv[i], pool);
        if (cond(r_gt(allocation, 0), C_REB_ALLOC, t, a)) {
          st[a].money = simlev_add(st[a].money, allocation);
          pool = simlev_sub(pool, allocation);
          detail(DT_REB_ALLOC, t, a, {allocation});
          if (cash_only[a]) detail(DT_REB_CASH, t, a, {st[a].money});
          else perform_buy(a, t, S_BUY_REBAL, RS_REBAL);
        }
      }
      if (cond(r_gt(pool, 0.01), C_REB_POOL, t, -1)) {
        detail(DT_REB_REST, t, -1, {pool});
        for (int i = 0; i < k; i++) {
          const int a = active[i];
          const double redistribution = simlev_mul(targets[i], pool);
          st[a].money = simlev_add(st[a].money, redistribution);
          detail(DT_REB_REDIST, t, a, {redistribution});
        }
      }
    }
    for (int a : active) {
      const lgl c = r_and(r_and(r_bool(!cash_only[a]), r_gt(st[a].money, 0.005)),
                          r_or(r_bool(in[a].style != 1), r_gt(st[a].count, 0)));
      if (cond(c, C_REB_REST, t, a)) buy_with_fee(a, t, RS_REBAL);
    }
    total_report(t);
  }

  // .perform_gain_harvest
  double harvest_taxable(int a, double n_, double sell_price, int regime, double bonus, bool with_fee, int t) {
    if (cond(r_le(n_, 0), C_HV_TAXN, t, a)) return 0.0;
    double p = sell_price;
    if (with_fee && fee_cur != nullptr) p = p - fee_amount(*fee_cur, n_ * sell_price) / n_;
    double g = simlev_mul(simlev_sub(p, fifo_price(a, n_)), n_);
    if (regime == RG_FUND) g = simlev_sub(g, fifo_vp(a, n_));
    return simlev_mul(1 - bonus, g);
  }
  void gain_harvest(int a, int t) {
    const int regime = in[a].regime;
    if (regime != RG_FUND && regime != RG_CG) return;
    const double total = st[a].count;
    if (cond(r_le(total, 0), C_HV_TOTAL, t, a)) return;
    const double room = simlev_add(use_spb ? T.v[TT_SPB_REM] : 0.0, loss_pot ? T.v[TT_LOSS_CG] : 0.0);
    if (cond(r_le(room, 0.01), C_HV_ROOM, t, a)) return;
    const double mp = px[a][t - 1];
    if (std::isnan(mp) || mp <= 0) return;
    const double sp = spread_sell(mp, in[a].spread);
    const double bonus = regime == RG_FUND ? in[a].bonus : 0.0;
    const double first_lot = r_min2(total, r_max2(1e-9, total * 1e-6));
    if (cond(r_le(harvest_taxable(a, first_lot, sp, regime, bonus, false, t), 0), C_HV_FIRST, t, a)) return;
    double n_;
    if (cond(r_le(harvest_taxable(a, total, sp, regime, bonus, true, t), room), C_HV_ALL, t, a)) {
      n_ = total;
    } else {
      double lo = 0.0, hi = total;
      for (int i = 0; i < 60; i++) {
        const double mid = (lo + hi) / 2;
        if (cond(r_gt(harvest_taxable(a, mid, sp, regime, bonus, true, t), room), C_HV_MID, t, a)) hi = mid;
        else lo = mid;
        if (cond(r_lt(hi - lo, total * 1e-10), C_HV_TOL, t, a)) break;
      }
      n_ = lo;
    }
    if (!fractions) n_ = std::floor(n_);
    const lgl l1 = r_le(n_, 0);
    if (cond(l1 == 1 ? 1 : r_or(l1, r_le(harvest_taxable(a, n_, sp, regime, bonus, true, t), 0)), C_HV_N, t, a)) return;
    detail(DT_HARVEST, t, a, {det() ? harvest_taxable(a, n_, sp, regime, bonus, true, t) : 0.0, n_, room});
    perform_sell(a, t, S_SELL_HARVEST, in[a].spread, true, n_);
    perform_buy(a, t, S_BUY_HARVEST, RS_HARVEST);
  }
  void day_harvest(int t) {
    if (fees_on) fee_cur = fee_ptr(fee_order);
    for (int a : active) gain_harvest(a, t);
    total_report(t);
  }

  // .sim_day_assess_vp mit .calculate_flat_rate
  void day_assess_vp(int t) {
    if (person && !(liquidate && has(t, F_LIQ))) {
      for (int a = 0; a < na; a++) {
        if (!cond(r_and(r_bool(in[a].regime == RG_FUND), r_gt(st[a].count, 0)), C_AV_FUND, t, a)) continue;
        const double date_index = day[t - 1];
        const int yr = eng_year(date_index);
        const long soy = eng_days(yr, 1, 1), eoy = eng_days(yr, 12, 31);
        int ysi = (int) ((double) soy - day[0]) + 1;
        if (ysi < 1) ysi = 1;
        int ri = ysi;
        while (ri < t && has(ri, F_FILLED)) ri++;
        if (has(ri, F_FILLED)) ri = ysi;
        const double ysp = px[a][ri - 1];
        const double raw = (in[a].base_rates ? in[a].base_rates[ri - 1] : 0.0) / 100;
        const double base_rate = r_max2(0.0, raw);
        double flat_rate = 0.0;
        if (!cond(r_le(base_rate, 0), C_FR_BASE, t, a)) {
          const double mp = px[a][t - 1];
          std::vector<Lot>& L = buys[a];
          Neumaier acc;
          for (int i = front[a]; i <= (int) L.size(); ++i) {
            Lot& b = L[i - 1];
            const double rem = b.remaining;
            if (rem <= 0) continue;
            const int buy_days = static_cast<int>(b.date);
            double vp = 0.0;
            if (buy_days <= eoy) {
              double mf = 1.0;
              if (buy_days >= soy) {
                int y, m, d;
                eng_civil(buy_days, y, m, d);
                mf = (12.0 - (m - 1)) / 12.0;
              }
              const double ref = simlev_mul(rem, ysp);
              const double bw = simlev_mul(ref, base_rate) * 0.7;
              const double mw = simlev_mul(rem, mp);
              const double growth = std::max(0.0, simlev_sub(mw, ref));
              vp = std::max(0.0, std::min(bw, growth)) * mf;
            }
            acc.add(vp);
            b.vp = (b.has_vp ? b.vp : 0.0) + vp;
            b.has_vp = 1;
          }
          flat_rate = acc.value();
        }
        if (cond(r_gt(flat_rate, 0), C_AV_RATE, t, a)) {
          T.vp_pending.push_back(VPPend{a, flat_rate, in[a].bonus, day[t - 1]});
          detail(DT_VP_ASSESS, t, a, {flat_rate});
        }
      }
    }
    total_report(t);
  }

  void day_liquidate(int t) {
    for (int a = 0; a < na; a++) {
      if (cond(r_gt(st[a].count, 0), C_LIQ_COUNT, t, a)) {
        perform_sell(a, t, S_SELL_LIQ, in[a].spread);
        if (cond(r_gt(st[a].count, 0), C_LIQ_LEFT, t, a)) warn(EV_LIQ_FEE, 0, t, a, st[a].worth);
      }
    }
    total_report(t);
  }

  // ── Tagesschleife (.sim_run_days) ──
  void run_days() {
    int prev_end = 0;
    active.clear();
    for (int t = 1; t <= n; t++) {
      const uint32_t f = flags[t - 1];
      if (!(f & (F_SLOW | F_YEAR))) continue;   // kein Einzeltag
      if (t > prev_end + 1) batch_market_update(prev_end + 1, t - 1);
      if (f & F_YEAR) year_change(T, st, eng_year(day[t - 1]), tariff_on != 0, t);
      if (f & F_SLOWNA) throw NAError(C_SLOW_NA, t, -1);
      if (!(f & F_SLOW)) {
        market_update(t);
        prev_end = t;
        continue;
      }
      if ((f & F_ACTIVE) || active.empty()) {
        active.clear();
        for (int a = 0; a < na; a++)
          if (in[a].start_idx <= t) active.push_back(a);
      }
      if (fees_on) fee_cur = fee_ptr(fee_order);
      bool fast = true;
      if (person && (f & F_VPSETTLE) && (!T.vp_pending.empty() || !T.p23_due.empty() || gp_pending())) {
        if (!T.vp_pending.empty()) settle_vp(t, nullptr);
        if (!T.p23_due.empty()) settle_p23(t);
        if (gp_pending()) settle_gp(t);
        total_report(t);
        fast = false;
      }
      bool rebal = (f & F_REBAL) != 0, trade = (f & F_TRADE) != 0;
      if (f & F_ACTIVE) {
        if (day_activate(t)) {
          rebal = true;
          trade = false;
        }
        fast = false;
      }
      if (f & F_SPLIT) {
        day_split(t);
        fast = false;
      }
      if (f & F_DCA) {
        day_dca(t);
        fast = false;
      }
      if (trade) {
        if (day_trade(t)) fast = false;
      }
      if (rebal) {
        day_rebalance(t);
        fast = false;
      }
      if (f & F_HARVEST) {
        day_harvest(t);
        fast = false;
      }
      if (f & F_TAXES) {
        day_assess_vp(t);
        fast = false;
      }
      if (f & F_LIQ) {
        day_liquidate(t);
        fast = false;
      }
      if (fast) market_update(t);
      prev_end = t;
    }
    if (prev_end < n) batch_market_update(prev_end + 1, n);
  }

  // ── Abschluss des letzten Jahres (.sim_close_years) ──
  void close_years() {
    if (!person) return;
    const int next_year = stopp_year + 1;
    if (!T.vp_pending.empty()) {
      const int vp_year = eng_year(T.vp_pending[0].assessment_date);
      std::vector<double> prepaid;
      bool has_prepaid = false;
      if ((int) T.v[TT_CURRENT_YEAR] <= vp_year) {
        // Probelauf: Jahreswechsel ohne Tarif auf Kopien, Warnungen verworfen; nur die Toepfe zaehlen
        Totals dry = T;
        std::vector<Status> dry_st = st;
        quiet = true;
        year_change(dry, dry_st, next_year, false, n);
        quiet = false;
        const std::vector<VPPend> pend = T.vp_pending;
        const std::vector<TaxRes> res = vp_taxes(dry, pend, n);
        for (std::size_t j = 0; j < pend.size(); j++) prepaid.push_back(res[j].tax);
        for (std::size_t j = 0; j < pend.size(); j++)
          if (cond(r_gt(prepaid[j], 0), C_CY_PREPAID, n, pend[j].asset)) pay_tax(pend[j].asset, prepaid[j], n, LBL_VP);
        year_change(T, st, next_year, tariff_on != 0, n);
        has_prepaid = true;
      }
      settle_vp(n, has_prepaid ? &prepaid : nullptr);
    }
    year_change(T, st, next_year, tariff_on != 0, n);
    if (tariff_on) {
      const int y_last = (int) T.v[TT_CURRENT_YEAR];
      if (tariff.use_gp && y_last > stopp_year && cond(r_gt(T.v[TT_CGT_BASE], 0), C_CY_GP, n, -1)) {
        const double D = tariff_close(y_last, 0.0, T.v[TT_CGT_BASE], eff_rate, n);
        tariff_book(T, D, n);
      }
    }
    if (!T.p23_due.empty()) settle_p23(n);
    if (tariff_on && gp_pending()) settle_gp(n);
    total_report(n);
  }
};

}  // namespace simlev_engine

#endif
