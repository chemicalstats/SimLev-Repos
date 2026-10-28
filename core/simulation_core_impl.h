// core/simulation_core_impl.h
// C++-Kernfunktionen des Pakets SimLev
//
// Version: 2.2.1
//
// WICHTIG: Alle Zugriffe auf status/report/market erfolgen ueber Namen,
// um Indizierungsfehler zu vermeiden.
//
// Ausnahme oberste Ebene von sim_mem (C7-11): Sie wird ueber die POSITION gelesen und
// geschrieben (0-basiert): input[0] assets, input[1] status, input[2] market,
// input[3] trades, input[4] report, input[5] totals. Die Reihenfolge legt R zentral in
// .SIM_MEM_LAYOUT (R/sim_prepare.R) fest; simulation() prueft sie mit .sim_check_layout()
// vor dem ersten Aufruf einer C++-Funktion. Wer die Feldfolge in R aendert, muss alle
// input[k] hier und in fifo_core.cpp anpassen.
//
// In-place-Semantik: Die Kerne arbeiten auf den R-Objekten selbst (SEXP), nicht auf
// Kopien; Listen und Zahlenvektoren werden wie frueher mit Rcpp::List/NumericVector nur
// umgewandelt, wenn ihr Typ nicht passt (sl::as_list, sl::num_vec). Die
// Funktionen aendern sim_mem an Ort und Stelle (vorhandene Listenelemente und
// Zahlenvektoren werden ueberschrieben, Unterlisten per status[name] = ... bzw.
// input[k] = ... zurueckgeschrieben). Die void-Funktionen geben nichts zurueck: Der
// Aufrufer in R arbeitet mit demselben Objekt weiter und weist es nicht neu zu. Jedes
// R-Objekt, das dieselben Unterlisten bzw. Vektoren teilt (z. B. nach x <- sim_mem ohne
// Aenderung in R), sieht die Aenderung mit; unabhaengig ist nur eine tiefe Kopie
// (unserialize(serialize(sim_mem, NULL)), Probelauf im Jahresabschluss).
//
// Status-Felder (R-Namen):
//   count, price, worth, money, total, target, actual, differ
//
//   ACHTUNG: Die Feldnamen "actual" und "differ" haben historisch
//   vertauschte Semantik:
//     - "actual" (R[[7]]) enthält das NORMALISIERTE ZIELGEWICHT
//     - "differ" (R[[8]]) enthält das AKTUELLE PORTFOLIO-GEWICHT
//   Dies ist in der R-Initialisierung so angelegt und wird vom gesamten
//   R-Code konsistent so verwendet. Die C++-Funktionen folgen dieser
//   Konvention.
//
// Report-Felder (R-Namen):
//   worth, money, flows, total, share
//
// Market-Felder (R-Namen):
//   asset_day, base_rates, asset_price, signal_buy, signal_sell, spread_rate
//
// GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3a): Die Kerne arbeiten auf dem
// Simulationszustand des Hosts (R: die Listen von sim_mem; Python: die dict/list-
// Struktur sim aus simlev/_sim_phases.py) ueber die Zugriffe simlev_host::as_list,
// get, set, put, at, has, as_double, as_int, num_vec, named_list und die Makros
// SIMLEV_XLENGTH, SIMLEV_LENGTH, SIMLEV_IS_NULL, SIMLEV_STRING_AT (Schnittstelle in
// simlev_core.h). Fuer R sind das genau die frueheren Aufrufe aus simlev_capi.h
// (simlev_host nimmt den Namensraum sl auf), der Compiler erzeugt daher denselben
// Maschinencode wie vor der Teilung (geprueft per Disassemblierung); Python stellt
// dieselben Zugriffe auf seine Objekte (python/src/_ext_common.h, _ext_engine.cpp).
// R ruft die Kerne ueber die .Call-Huellen in r/src/simulation_core.cpp auf, Python ueber
// simlev._ext. Kanonisch in core/ (seit Etappe 9.6c, F16); R und Python bauen aus
// Byte-fuer-Byte-Kopien in r/src/ bzw. python/src/core/ (tools/core_sync.py
// --write/--check); Aenderungen nur in core/ vornehmen und danach kopieren.
// Die Python-Huellen (simlev/_core.py) rufen nur noch diese Kerne; die reinen
// Python-Kerne als Rueckfall sind seit 9.6c entfallen.

#ifndef SIMLEV_SIMULATION_CORE_IMPL_H
#define SIMLEV_SIMULATION_CORE_IMPL_H

// Gleitkomma wie im Pilot (simlev_core.h): Abbruch bei -ffast-math; kein
// Zusammenziehen von a * b + c zu fma. Das Pragma steht nur dort, wo der Compiler
// fma ueberhaupt erzeugen kann (__FP_FAST_FMA, etwa aarch64 oder -mfma): auf
// x86-64 ohne FMA ist -ffp-contract=off wirkungslos, das GCC-Pragma optimize
// veraendert dort aber die Codeerzeugung der ganzen Datei (geprueft), und R soll
// denselben Maschinencode wie vor der Teilung ausfuehren. Python baut immer mit
// -ffp-contract=off (setup.py) und setzt SIMLEV_FP_CONTRACT_BY_FLAG.
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
#if !defined(SIMLEV_XLENGTH) || !defined(SIMLEV_STRING_AT)
#error "Vor diesem Kern den Host einbinden: R simlev_capi.h, Python _ext_common.h (siehe simlev_core.h)."
#endif

#include <vector>
#include <string>
#include <algorithm>
#include <cmath>

namespace simlev {

// ===========================================================================
// HILFSFUNKTIONEN
// ===========================================================================

bool leap_year(int year) {
  return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
}

int days_in_month(int year, int month) {
  static const int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  if (month < 1 || month > 12) return 30;
  int d = days[month - 1];
  if (month == 2 && leap_year(year)) d = 29;
  return d;
}

// ===========================================================================
// KERNE (R-Huellen in R/cores.R)
// ===========================================================================

// DCA-Zufluss einem Asset zuordnen (.sim_dca_flows_cpp)
//
// Bucht die Sparplan-Einzahlung in den Simulationszustand (flows, money, total).
//
// input  Liste des Simulationszustands (sim_mem)
// name   Asset-Name
// flows  Einzuzahlender Betrag in EUR
// index  Tagesindex (1-basiert)
static void dca_flows_allocation(simlev_host::Obj input, const char* name, double flows, int index) {
  simlev_host::Obj status = simlev_host::as_list(simlev_host::at(input, 1));
  simlev_host::Obj report = simlev_host::as_list(simlev_host::at(input, 4));
  
  simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
  simlev_host::Obj report_name = simlev_host::as_list(simlev_host::get(report, name));
  
  // flows im Report aktualisieren
  simlev_host::NumVec report_flows = simlev_host::num_vec(simlev_host::get(report_name, "flows"));
  report_flows[index - 1] = flows;
  simlev_host::set(report_name, "flows", report_flows);
  
  // money (Cash) aktualisieren
  double money = simlev_host::as_double(simlev_host::get(status_name, "money"));
  money += flows;
  simlev_host::set(status_name, "money", money);
  
  simlev_host::NumVec report_money = simlev_host::num_vec(simlev_host::get(report_name, "money"));
  report_money[index - 1] = money;
  simlev_host::set(report_name, "money", report_money);
  
  // total aktualisieren
  double worth = simlev_host::as_double(simlev_host::get(status_name, "worth"));
  double total = money + worth;
  simlev_host::set(status_name, "total", total);
  
  simlev_host::NumVec report_total = simlev_host::num_vec(simlev_host::get(report_name, "total"));
  report_total[index - 1] = total;
  simlev_host::set(report_name, "total", report_total);
  
  // Zurueckschreiben
  simlev_host::set(report, name, report_name);
  simlev_host::set(status, name, status_name);
  simlev_host::put(input, 4, report);
  simlev_host::put(input, 1, status);
}


// Report nach einem Kauf aktualisieren (.sim_buy_report_cpp)
//
// input        Liste des Simulationszustands (sim_mem)
// name         Asset-Name
// index        Tagesindex (1-basiert)
// trade_count  Anzahl gekaufter Anteile
// trade_price  Gezahlter Preis je Anteil
// market_price Aktueller Marktkurs
static void calculate_buy_report(simlev_host::Obj input, const char* name, int index, 
                                 double trade_count, double trade_price, 
                                 double market_price) {
  simlev_host::Obj status = simlev_host::as_list(simlev_host::at(input, 1));
  simlev_host::Obj report = simlev_host::as_list(simlev_host::at(input, 4));
  
  simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
  simlev_host::Obj report_name = simlev_host::as_list(simlev_host::get(report, name));
  
  double count = simlev_host::as_double(simlev_host::get(status_name, "count"));
  double money = simlev_host::as_double(simlev_host::get(status_name, "money"));
  
  count += trade_count;
  simlev_host::set(status_name, "count", count);
  simlev_host::set(status_name, "price", market_price);
  
  double worth = count * market_price;
  simlev_host::set(status_name, "worth", worth);
  
  money -= (trade_count * trade_price);
  simlev_host::set(status_name, "money", money);
  
  double total = worth + money;
  simlev_host::set(status_name, "total", total);
  
  simlev_host::set(status, name, status_name);
  simlev_host::put(input, 1, status);
  
  simlev_host::NumVec worth_vec = simlev_host::num_vec(simlev_host::get(report_name, "worth"));
  worth_vec[index - 1] = worth;
  simlev_host::set(report_name, "worth", worth_vec);
  
  simlev_host::NumVec money_vec = simlev_host::num_vec(simlev_host::get(report_name, "money"));
  money_vec[index - 1] = money;
  simlev_host::set(report_name, "money", money_vec);
  
  simlev_host::NumVec total_vec = simlev_host::num_vec(simlev_host::get(report_name, "total"));
  total_vec[index - 1] = total;
  simlev_host::set(report_name, "total", total_vec);
  
  simlev_host::set(report, name, report_name);
  simlev_host::put(input, 4, report);
}


// Report nach einem Verkauf aktualisieren (.sim_sell_report_cpp)
//
// input             Liste des Simulationszustands (sim_mem)
// name              Asset-Name
// index             Tagesindex (1-basiert)
// trade_count       Anzahl verkaufter Anteile
// trade_price       Erhaltener Preis je Anteil
// market_price      Aktueller Marktkurs
// capital_gains_tax Gezahlte Steuer auf den Gewinn
static void calculate_sell_report(simlev_host::Obj input, const char* name, int index,
                                  double trade_count, double trade_price,
                                  double market_price, double capital_gains_tax) {
  simlev_host::Obj status = simlev_host::as_list(simlev_host::at(input, 1));
  simlev_host::Obj report = simlev_host::as_list(simlev_host::at(input, 4));
  
  simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
  simlev_host::Obj report_name = simlev_host::as_list(simlev_host::get(report, name));
  
  double count = simlev_host::as_double(simlev_host::get(status_name, "count"));
  double money = simlev_host::as_double(simlev_host::get(status_name, "money"));
  
  count -= trade_count;
  simlev_host::set(status_name, "count", count);
  simlev_host::set(status_name, "price", market_price);
  
  double worth = count * market_price;
  simlev_host::set(status_name, "worth", worth);
  
  money += (trade_count * trade_price) - capital_gains_tax;
  simlev_host::set(status_name, "money", money);
  
  double total = worth + money;
  simlev_host::set(status_name, "total", total);
  
  simlev_host::set(status, name, status_name);
  simlev_host::put(input, 1, status);
  
  simlev_host::NumVec worth_vec = simlev_host::num_vec(simlev_host::get(report_name, "worth"));
  worth_vec[index - 1] = worth;
  simlev_host::set(report_name, "worth", worth_vec);
  
  simlev_host::NumVec money_vec = simlev_host::num_vec(simlev_host::get(report_name, "money"));
  money_vec[index - 1] = money;
  simlev_host::set(report_name, "money", money_vec);
  
  simlev_host::NumVec total_vec = simlev_host::num_vec(simlev_host::get(report_name, "total"));
  total_vec[index - 1] = total;
  simlev_host::set(report_name, "total", total_vec);
  
  simlev_host::set(report, name, report_name);
  simlev_host::put(input, 4, report);
}


// Gesamtreport fuer alle Assets berechnen (.sim_total_report_cpp)
//
// Aktualisiert Status und Report aller Assets an einem Tag.
// Berechnet die Portfolio-Gewichte neu (gespeichert im Status-Feld "differ")
// auf Basis der aktuellen Marktwerte.
//
// input  Liste des Simulationszustands (sim_mem)
// assets Zeichenvektor der Asset-Namen
// index  Tagesindex (1-basiert)
static void calculate_total_report(simlev_host::Obj input, simlev_host::Obj assets, int index) {
  simlev_host::Obj status = simlev_host::as_list(simlev_host::at(input, 1));
  simlev_host::Obj market = simlev_host::as_list(simlev_host::at(input, 2));
  simlev_host::Obj report = simlev_host::as_list(simlev_host::at(input, 4));
  
  // Erster Durchlauf: Kurse aktualisieren und Summen berechnen
  for (int i = 0; i < SIMLEV_XLENGTH(assets); i++) {
    const char* name = SIMLEV_STRING_AT(assets, i);
    
    simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
    simlev_host::Obj market_name = simlev_host::as_list(simlev_host::get(market, name));
    simlev_host::Obj report_name = simlev_host::as_list(simlev_host::get(report, name));
    
    simlev_host::NumVec asset_price = simlev_host::num_vec(simlev_host::get(market_name, "asset_price"));
    double price = asset_price[index - 1];
    simlev_host::set(status_name, "price", price);
    
    double count = simlev_host::as_double(simlev_host::get(status_name, "count"));
    double worth = price * count;
    simlev_host::set(status_name, "worth", worth);
    
    simlev_host::NumVec report_worth = simlev_host::num_vec(simlev_host::get(report_name, "worth"));
    report_worth[index - 1] = worth;
    simlev_host::set(report_name, "worth", report_worth);
    
    double money = simlev_host::as_double(simlev_host::get(status_name, "money"));
    simlev_host::NumVec report_money = simlev_host::num_vec(simlev_host::get(report_name, "money"));
    report_money[index - 1] = money;
    simlev_host::set(report_name, "money", report_money);
    
    double total = money + worth;
    simlev_host::set(status_name, "total", total);
    simlev_host::NumVec report_total = simlev_host::num_vec(simlev_host::get(report_name, "total"));
    report_total[index - 1] = total;
    simlev_host::set(report_name, "total", report_total);
    
    simlev_host::set(status, name, status_name);
    simlev_host::set(report, name, report_name);
  }
  
  // Gesamtwert des Portfolios berechnen
  double total_worth = 0.0;
  for (int i = 0; i < SIMLEV_XLENGTH(assets); i++) {
    const char* name = SIMLEV_STRING_AT(assets, i);
    simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
    total_worth += simlev_host::as_double(simlev_host::get(status_name, "total"));
  }
  
  // Zweiter Durchlauf: Portfolio-Gewichte berechnen und speichern
  //
  // Feldkonvention (historisch bedingt):
  //   status["actual"] = normalisiertes Zielgewicht (wird hier NICHT ueberschrieben)
  //   status["differ"] = aktuelles Portfolio-Gewicht (wird hier aktualisiert)
  //
  for (int i = 0; i < SIMLEV_XLENGTH(assets); i++) {
    const char* name = SIMLEV_STRING_AT(assets, i);
    
    simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
    simlev_host::Obj report_name = simlev_host::as_list(simlev_host::get(report, name));
    
    double total = simlev_host::as_double(simlev_host::get(status_name, "total"));
    double current_weight = (total_worth > 0) ? total / total_worth : 0.0;
    
    // Aktuelles Portfolio-Gewicht in "differ" speichern
    // (R-Code liest dies als sim_mem[[2]][[name]][[8]] fuer DCA/Rebalancing)
    simlev_host::set(status_name, "differ", current_weight);
    
    // Report: share-Vektor aktualisieren
    simlev_host::NumVec report_share = simlev_host::num_vec(simlev_host::get(report_name, "share"));
    report_share[index - 1] = current_weight;
    simlev_host::set(report_name, "share", report_share);
    
    simlev_host::set(status, name, status_name);
    simlev_host::set(report, name, report_name);
  }
  
  simlev_host::put(input, 1, status);
  simlev_host::put(input, 4, report);
}


// Kauf ausfuehren (.sim_buy_cpp)
//
// Fuehrt die Kern-Kauflogik aus: ruft calculate_buy_report auf (Report- und Status-Update),
// legt einen FIFO-Lot-Eintrag an und erhoeht buy_count. Alles per Referenz.
//
// Der R-Wrapper uebernimmt: Berechnung von trade_count (Spread, Bruchteile), Detailausgabe.
//
// input        Liste des Simulationszustands (wird direkt veraendert)
// name         Asset-Name
// index        Tagesindex (1-basiert)
// trade_count  Anzahl zu kaufender Anteile
// trade_price  Preis je Anteil (nach Spread)
// market_price Marktkurs (vor Spread)
static void perform_trade_buy_cpp(simlev_host::Obj input, const char* name, int index,
                                  double trade_count, double trade_price,
                                  double market_price) {
  
  // 1. Report- und Status-Update (ueber vorhandene C++-Funktion)
  calculate_buy_report(input, name, index, trade_count, trade_price, market_price);
  
  // 2. FIFO-Lot erstellen
  simlev_host::Obj trades = simlev_host::as_list(simlev_host::at(input, 3));  // trades
  simlev_host::Obj trades_name = simlev_host::as_list(simlev_host::get(trades, name));
  
  // Kaufdatum aus market[[name]][["asset_day"]] (wie Rcpp::DateVector: Zahlenvektor,
  // dessen class-Attribut an Ort und Stelle auf "Date" gesetzt wird)
  simlev_host::Obj market = simlev_host::as_list(simlev_host::at(input, 2));
  simlev_host::Obj market_name = simlev_host::as_list(simlev_host::get(market, name));
  simlev_host::NumVec asset_days = simlev_host::num_vec(simlev_host::get(market_name, "asset_day"));
  SIMLEV_MARK_DATE(asset_days);
  simlev_host::Date event_date = {asset_days[index - 1]};
  
  // Lot-Felder: Zugriff ueber Namen, konsistent mit dem R-Code
  // buy[["date"]], buy[["type"]], buy[["count"]], buy[["price"]],
  // buy[["remaining"]], buy[["original"]], (buy[["vp"]] wird später am 31.12. ergänzt)
  simlev_host::Obj lot = simlev_host::named_list(
    "date", event_date,
    "type", "Buy",
    "count", trade_count,
    "price", trade_price,
    "remaining", trade_count,
    "original", trade_count
  );
  
  // 3. Lot an buys-Liste anhängen
  int buy_count = simlev_host::as_int(simlev_host::get(trades_name, "buy_count")) + 1;
  simlev_host::set(trades_name, "buy_count", buy_count);
  
  simlev_host::Obj buys = simlev_host::as_list(simlev_host::get(trades_name, "buys"));
  simlev_host::put(buys, buy_count - 1, lot);  // 0-basierter Index
  simlev_host::set(trades_name, "buys", buys);
  
  simlev_host::set(trades, name, trades_name);
  simlev_host::put(input, 3, trades);
}


// Markt-Update fuer einen einzelnen Tag, Fast Path (.sim_market_update_cpp)
//
// Aktualisiert Kurse, worth, total und Portfolio-Gewichte aller Assets
// an einem Tag. Ersetzt das fruehere perform_market_update in R.
//
// input  Liste des Simulationszustands (wird direkt veraendert)
// assets Zeichenvektor der Asset-Namen
// index  Tagesindex (1-basiert)
static void perform_market_update(simlev_host::Obj input, simlev_host::Obj assets, int index) {
  simlev_host::Obj status = simlev_host::as_list(simlev_host::at(input, 1));
  simlev_host::Obj market = simlev_host::as_list(simlev_host::at(input, 2));
  simlev_host::Obj report = simlev_host::as_list(simlev_host::at(input, 4));
  
  int n_assets = SIMLEV_XLENGTH(assets);
  double total_portfolio = 0.0;
  std::vector<double> asset_totals(n_assets);
  
  for (int i = 0; i < n_assets; i++) {
    const char* name = SIMLEV_STRING_AT(assets, i);
    simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
    simlev_host::Obj market_name = simlev_host::as_list(simlev_host::get(market, name));
    simlev_host::Obj report_name = simlev_host::as_list(simlev_host::get(report, name));
    
    simlev_host::NumVec prices = simlev_host::num_vec(simlev_host::get(market_name, "asset_price"));
    double count = simlev_host::as_double(simlev_host::get(status_name, "count"));
    double money = simlev_host::as_double(simlev_host::get(status_name, "money"));
    double worth = count * prices[index - 1];
    double total = worth + money;
    
    asset_totals[i] = total;
    total_portfolio += total;
    
    // Report-Vektoren in-place aktualisieren
    simlev_host::NumVec rw = simlev_host::num_vec(simlev_host::get(report_name, "worth"));
    simlev_host::NumVec rm = simlev_host::num_vec(simlev_host::get(report_name, "money"));
    simlev_host::NumVec rf = simlev_host::num_vec(simlev_host::get(report_name, "flows"));
    simlev_host::NumVec rt = simlev_host::num_vec(simlev_host::get(report_name, "total"));
    rw[index - 1] = worth;
    rm[index - 1] = money;
    rf[index - 1] = 0.0;
    rt[index - 1] = total;
    
    // Status aktualisieren
    simlev_host::set(status_name, "price", prices[index - 1]);
    simlev_host::set(status_name, "worth", worth);
    simlev_host::set(status_name, "total", total);
    
    simlev_host::set(status, name, status_name);
  }
  
  // Gewichte berechnen und schreiben
  for (int i = 0; i < n_assets; i++) {
    const char* name = SIMLEV_STRING_AT(assets, i);
    simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
    simlev_host::Obj report_name = simlev_host::as_list(simlev_host::get(report, name));
    
    double weight = (total_portfolio > 0) ? asset_totals[i] / total_portfolio : 0.0;
    simlev_host::NumVec rs = simlev_host::num_vec(simlev_host::get(report_name, "share"));
    rs[index - 1] = weight;
    simlev_host::set(status_name, "differ", weight);
    
    simlev_host::set(status, name, status_name);
  }
  
  simlev_host::put(input, 1, status);
  simlev_host::put(input, 4, report);
}


// Gebuendeltes Markt-Update fuer zusammenhaengende Fast-Path-Tage
// (.sim_market_update_batch_cpp)
//
// Vektorisiertes Update fuer einen Tagesbereich ohne Trades, DCA, Rebalancing,
// Jahreswechsel oder "Staking"-Ereignisse. An diesen Tagen sind count und money
// je Asset konstant; worth und total sind daher einfach mit dem Kurs skalierte Vektoren.
//
// Das ersetzt Hunderte einzelner Aufrufe von .sim_market_update_cpp() durch
// eine einzige kompakte C++-Schleife ueber die Kursvektoren.
//
// input     Liste des Simulationszustands (wird direkt veraendert)
// assets    Zeichenvektor der Asset-Namen
// start_idx Erster Tagesindex (1-basiert, einschliesslich)
// end_idx   Letzter Tagesindex (1-basiert, einschliesslich)
static void batch_market_update(simlev_host::Obj input, simlev_host::Obj assets, 
                                int start_idx, int end_idx) {
  simlev_host::Obj status = simlev_host::as_list(simlev_host::at(input, 1));
  simlev_host::Obj market = simlev_host::as_list(simlev_host::at(input, 2));
  simlev_host::Obj report = simlev_host::as_list(simlev_host::at(input, 4));
  
  int n_assets = SIMLEV_XLENGTH(assets);
  int n_days = end_idx - start_idx + 1;
  if (n_days <= 0) return;
  
  // Portfolio-Tagessummen fuer Gewichtsberechnung
  std::vector<double> portfolio_totals(n_days, 0.0);
  
  // === PASS 1: Preise, Worth, Total berechnen und Report schreiben ===
  // Pro Asset: Ein Durchlauf ueber den Preisvektor (cache-freundlich)
  for (int a = 0; a < n_assets; a++) {
    const char* name = SIMLEV_STRING_AT(assets, a);
    simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
    simlev_host::Obj market_name = simlev_host::as_list(simlev_host::get(market, name));
    simlev_host::Obj report_name = simlev_host::as_list(simlev_host::get(report, name));
    
    double count = simlev_host::as_double(simlev_host::get(status_name, "count"));
    double money = simlev_host::as_double(simlev_host::get(status_name, "money"));
    
    simlev_host::NumVec prices = simlev_host::num_vec(simlev_host::get(market_name, "asset_price"));
    simlev_host::NumVec rw = simlev_host::num_vec(simlev_host::get(report_name, "worth"));
    simlev_host::NumVec rm = simlev_host::num_vec(simlev_host::get(report_name, "money"));
    simlev_host::NumVec rf = simlev_host::num_vec(simlev_host::get(report_name, "flows"));
    simlev_host::NumVec rt = simlev_host::num_vec(simlev_host::get(report_name, "total"));
    
    double last_worth = 0.0, last_total = 0.0, last_price = 0.0;
    
    for (int d = 0; d < n_days; d++) {
      int idx = start_idx - 1 + d;  // 0-basierter Index
      double price = prices[idx];
      double worth = count * price;
      double total = worth + money;
      
      rw[idx] = worth;
      rm[idx] = money;
      rf[idx] = 0.0;
      rt[idx] = total;
      
      portfolio_totals[d] += total;
      last_price = price;
      last_worth = worth;
      last_total = total;
    }
    
    // Status auf letzten Tag des Blocks setzen
    simlev_host::set(status_name, "price", last_price);
    simlev_host::set(status_name, "worth", last_worth);
    simlev_host::set(status_name, "total", last_total);
    
    simlev_host::set(status, name, status_name);
  }
  
  // === PASS 2: Portfolio-Gewichte berechnen ===
  for (int a = 0; a < n_assets; a++) {
    const char* name = SIMLEV_STRING_AT(assets, a);
    simlev_host::Obj status_name = simlev_host::as_list(simlev_host::get(status, name));
    simlev_host::Obj report_name = simlev_host::as_list(simlev_host::get(report, name));
    
    simlev_host::NumVec rs = simlev_host::num_vec(simlev_host::get(report_name, "share"));
    simlev_host::NumVec rt = simlev_host::num_vec(simlev_host::get(report_name, "total"));
    
    double last_weight = 0.0;
    for (int d = 0; d < n_days; d++) {
      int idx = start_idx - 1 + d;
      double weight = (portfolio_totals[d] > 0.0) 
                        ? rt[idx] / portfolio_totals[d] 
                        : 0.0;
      rs[idx] = weight;
      last_weight = weight;
    }
    
    // Status-Gewicht auf letzten Tag des Blocks setzen
    simlev_host::set(status_name, "differ", last_weight);
    simlev_host::set(status, name, status_name);
  }
  
  simlev_host::put(input, 1, status);
  simlev_host::put(input, 4, report);
}

}  // namespace simlev

#endif
