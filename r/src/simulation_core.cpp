// src/simulation_core.cpp
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

#include "simlev_capi.h"
#include <vector>
#include <string>
#include <algorithm>
#include <cmath>

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
static void dca_flows_allocation(SEXP input, const char* name, double flows, int index) {
  SEXP status = sl::as_list(sl::at(input, 1));
  SEXP report = sl::as_list(sl::at(input, 4));
  
  SEXP status_name = sl::as_list(sl::get(status, name));
  SEXP report_name = sl::as_list(sl::get(report, name));
  
  // flows im Report aktualisieren
  sl::NumVec report_flows = sl::num_vec(sl::get(report_name, "flows"));
  report_flows[index - 1] = flows;
  sl::set(report_name, "flows", report_flows);
  
  // money (Cash) aktualisieren
  double money = sl::as_double(sl::get(status_name, "money"));
  money += flows;
  sl::set(status_name, "money", money);
  
  sl::NumVec report_money = sl::num_vec(sl::get(report_name, "money"));
  report_money[index - 1] = money;
  sl::set(report_name, "money", report_money);
  
  // total aktualisieren
  double worth = sl::as_double(sl::get(status_name, "worth"));
  double total = money + worth;
  sl::set(status_name, "total", total);
  
  sl::NumVec report_total = sl::num_vec(sl::get(report_name, "total"));
  report_total[index - 1] = total;
  sl::set(report_name, "total", report_total);
  
  // Zurueckschreiben
  sl::set(report, name, report_name);
  sl::set(status, name, status_name);
  sl::put(input, 4, report);
  sl::put(input, 1, status);
}


// Report nach einem Kauf aktualisieren (.sim_buy_report_cpp)
//
// input        Liste des Simulationszustands (sim_mem)
// name         Asset-Name
// index        Tagesindex (1-basiert)
// trade_count  Anzahl gekaufter Anteile
// trade_price  Gezahlter Preis je Anteil
// market_price Aktueller Marktkurs
static void calculate_buy_report(SEXP input, const char* name, int index, 
                                 double trade_count, double trade_price, 
                                 double market_price) {
  SEXP status = sl::as_list(sl::at(input, 1));
  SEXP report = sl::as_list(sl::at(input, 4));
  
  SEXP status_name = sl::as_list(sl::get(status, name));
  SEXP report_name = sl::as_list(sl::get(report, name));
  
  double count = sl::as_double(sl::get(status_name, "count"));
  double money = sl::as_double(sl::get(status_name, "money"));
  
  count += trade_count;
  sl::set(status_name, "count", count);
  sl::set(status_name, "price", market_price);
  
  double worth = count * market_price;
  sl::set(status_name, "worth", worth);
  
  money -= (trade_count * trade_price);
  sl::set(status_name, "money", money);
  
  double total = worth + money;
  sl::set(status_name, "total", total);
  
  sl::set(status, name, status_name);
  sl::put(input, 1, status);
  
  sl::NumVec worth_vec = sl::num_vec(sl::get(report_name, "worth"));
  worth_vec[index - 1] = worth;
  sl::set(report_name, "worth", worth_vec);
  
  sl::NumVec money_vec = sl::num_vec(sl::get(report_name, "money"));
  money_vec[index - 1] = money;
  sl::set(report_name, "money", money_vec);
  
  sl::NumVec total_vec = sl::num_vec(sl::get(report_name, "total"));
  total_vec[index - 1] = total;
  sl::set(report_name, "total", total_vec);
  
  sl::set(report, name, report_name);
  sl::put(input, 4, report);
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
static void calculate_sell_report(SEXP input, const char* name, int index,
                                  double trade_count, double trade_price,
                                  double market_price, double capital_gains_tax) {
  SEXP status = sl::as_list(sl::at(input, 1));
  SEXP report = sl::as_list(sl::at(input, 4));
  
  SEXP status_name = sl::as_list(sl::get(status, name));
  SEXP report_name = sl::as_list(sl::get(report, name));
  
  double count = sl::as_double(sl::get(status_name, "count"));
  double money = sl::as_double(sl::get(status_name, "money"));
  
  count -= trade_count;
  sl::set(status_name, "count", count);
  sl::set(status_name, "price", market_price);
  
  double worth = count * market_price;
  sl::set(status_name, "worth", worth);
  
  money += (trade_count * trade_price) - capital_gains_tax;
  sl::set(status_name, "money", money);
  
  double total = worth + money;
  sl::set(status_name, "total", total);
  
  sl::set(status, name, status_name);
  sl::put(input, 1, status);
  
  sl::NumVec worth_vec = sl::num_vec(sl::get(report_name, "worth"));
  worth_vec[index - 1] = worth;
  sl::set(report_name, "worth", worth_vec);
  
  sl::NumVec money_vec = sl::num_vec(sl::get(report_name, "money"));
  money_vec[index - 1] = money;
  sl::set(report_name, "money", money_vec);
  
  sl::NumVec total_vec = sl::num_vec(sl::get(report_name, "total"));
  total_vec[index - 1] = total;
  sl::set(report_name, "total", total_vec);
  
  sl::set(report, name, report_name);
  sl::put(input, 4, report);
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
static void calculate_total_report(SEXP input, SEXP assets, int index) {
  SEXP status = sl::as_list(sl::at(input, 1));
  SEXP market = sl::as_list(sl::at(input, 2));
  SEXP report = sl::as_list(sl::at(input, 4));
  
  // Erster Durchlauf: Kurse aktualisieren und Summen berechnen
  for (int i = 0; i < Rf_xlength(assets); i++) {
    const char* name = CHAR(STRING_ELT(assets, i));
    
    SEXP status_name = sl::as_list(sl::get(status, name));
    SEXP market_name = sl::as_list(sl::get(market, name));
    SEXP report_name = sl::as_list(sl::get(report, name));
    
    sl::NumVec asset_price = sl::num_vec(sl::get(market_name, "asset_price"));
    double price = asset_price[index - 1];
    sl::set(status_name, "price", price);
    
    double count = sl::as_double(sl::get(status_name, "count"));
    double worth = price * count;
    sl::set(status_name, "worth", worth);
    
    sl::NumVec report_worth = sl::num_vec(sl::get(report_name, "worth"));
    report_worth[index - 1] = worth;
    sl::set(report_name, "worth", report_worth);
    
    double money = sl::as_double(sl::get(status_name, "money"));
    sl::NumVec report_money = sl::num_vec(sl::get(report_name, "money"));
    report_money[index - 1] = money;
    sl::set(report_name, "money", report_money);
    
    double total = money + worth;
    sl::set(status_name, "total", total);
    sl::NumVec report_total = sl::num_vec(sl::get(report_name, "total"));
    report_total[index - 1] = total;
    sl::set(report_name, "total", report_total);
    
    sl::set(status, name, status_name);
    sl::set(report, name, report_name);
  }
  
  // Gesamtwert des Portfolios berechnen
  double total_worth = 0.0;
  for (int i = 0; i < Rf_xlength(assets); i++) {
    const char* name = CHAR(STRING_ELT(assets, i));
    SEXP status_name = sl::as_list(sl::get(status, name));
    total_worth += sl::as_double(sl::get(status_name, "total"));
  }
  
  // Zweiter Durchlauf: Portfolio-Gewichte berechnen und speichern
  //
  // Feldkonvention (historisch bedingt):
  //   status["actual"] = normalisiertes Zielgewicht (wird hier NICHT ueberschrieben)
  //   status["differ"] = aktuelles Portfolio-Gewicht (wird hier aktualisiert)
  //
  for (int i = 0; i < Rf_xlength(assets); i++) {
    const char* name = CHAR(STRING_ELT(assets, i));
    
    SEXP status_name = sl::as_list(sl::get(status, name));
    SEXP report_name = sl::as_list(sl::get(report, name));
    
    double total = sl::as_double(sl::get(status_name, "total"));
    double current_weight = (total_worth > 0) ? total / total_worth : 0.0;
    
    // Aktuelles Portfolio-Gewicht in "differ" speichern
    // (R-Code liest dies als sim_mem[[2]][[name]][[8]] fuer DCA/Rebalancing)
    sl::set(status_name, "differ", current_weight);
    
    // Report: share-Vektor aktualisieren
    sl::NumVec report_share = sl::num_vec(sl::get(report_name, "share"));
    report_share[index - 1] = current_weight;
    sl::set(report_name, "share", report_share);
    
    sl::set(status, name, status_name);
    sl::set(report, name, report_name);
  }
  
  sl::put(input, 1, status);
  sl::put(input, 4, report);
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
static void perform_trade_buy_cpp(SEXP input, const char* name, int index,
                                  double trade_count, double trade_price,
                                  double market_price) {
  
  // 1. Report- und Status-Update (ueber vorhandene C++-Funktion)
  calculate_buy_report(input, name, index, trade_count, trade_price, market_price);
  
  // 2. FIFO-Lot erstellen
  SEXP trades = sl::as_list(sl::at(input, 3));  // trades
  SEXP trades_name = sl::as_list(sl::get(trades, name));
  
  // Kaufdatum aus market[[name]][["asset_day"]] (wie Rcpp::DateVector: Zahlenvektor,
  // dessen class-Attribut an Ort und Stelle auf "Date" gesetzt wird)
  SEXP market = sl::as_list(sl::at(input, 2));
  SEXP market_name = sl::as_list(sl::get(market, name));
  sl::NumVec asset_days = sl::num_vec(sl::get(market_name, "asset_day"));
  {
    SEXP date_class = PROTECT(Rf_mkString("Date"));
    Rf_setAttrib(asset_days.sexp, R_ClassSymbol, date_class);
    UNPROTECT(1);
  }
  sl::Date event_date = {asset_days[index - 1]};
  
  // Lot-Felder: Zugriff ueber Namen, konsistent mit dem R-Code
  // buy[["date"]], buy[["type"]], buy[["count"]], buy[["price"]],
  // buy[["remaining"]], buy[["original"]], (buy[["vp"]] wird später am 31.12. ergänzt)
  SEXP lot = sl::named_list(
    "date", event_date,
    "type", "Buy",
    "count", trade_count,
    "price", trade_price,
    "remaining", trade_count,
    "original", trade_count
  );
  
  // 3. Lot an buys-Liste anhängen
  int buy_count = sl::as_int(sl::get(trades_name, "buy_count")) + 1;
  sl::set(trades_name, "buy_count", buy_count);
  
  SEXP buys = sl::as_list(sl::get(trades_name, "buys"));
  sl::put(buys, buy_count - 1, lot);  // 0-basierter Index
  sl::set(trades_name, "buys", buys);
  
  sl::set(trades, name, trades_name);
  sl::put(input, 3, trades);
}


// Markt-Update fuer einen einzelnen Tag, Fast Path (.sim_market_update_cpp)
//
// Aktualisiert Kurse, worth, total und Portfolio-Gewichte aller Assets
// an einem Tag. Ersetzt das fruehere perform_market_update in R.
//
// input  Liste des Simulationszustands (wird direkt veraendert)
// assets Zeichenvektor der Asset-Namen
// index  Tagesindex (1-basiert)
static void perform_market_update(SEXP input, SEXP assets, int index) {
  SEXP status = sl::as_list(sl::at(input, 1));
  SEXP market = sl::as_list(sl::at(input, 2));
  SEXP report = sl::as_list(sl::at(input, 4));
  
  int n_assets = Rf_xlength(assets);
  double total_portfolio = 0.0;
  std::vector<double> asset_totals(n_assets);
  
  for (int i = 0; i < n_assets; i++) {
    const char* name = CHAR(STRING_ELT(assets, i));
    SEXP status_name = sl::as_list(sl::get(status, name));
    SEXP market_name = sl::as_list(sl::get(market, name));
    SEXP report_name = sl::as_list(sl::get(report, name));
    
    sl::NumVec prices = sl::num_vec(sl::get(market_name, "asset_price"));
    double count = sl::as_double(sl::get(status_name, "count"));
    double money = sl::as_double(sl::get(status_name, "money"));
    double worth = count * prices[index - 1];
    double total = worth + money;
    
    asset_totals[i] = total;
    total_portfolio += total;
    
    // Report-Vektoren in-place aktualisieren
    sl::NumVec rw = sl::num_vec(sl::get(report_name, "worth"));
    sl::NumVec rm = sl::num_vec(sl::get(report_name, "money"));
    sl::NumVec rf = sl::num_vec(sl::get(report_name, "flows"));
    sl::NumVec rt = sl::num_vec(sl::get(report_name, "total"));
    rw[index - 1] = worth;
    rm[index - 1] = money;
    rf[index - 1] = 0.0;
    rt[index - 1] = total;
    
    // Status aktualisieren
    sl::set(status_name, "price", prices[index - 1]);
    sl::set(status_name, "worth", worth);
    sl::set(status_name, "total", total);
    
    sl::set(status, name, status_name);
  }
  
  // Gewichte berechnen und schreiben
  for (int i = 0; i < n_assets; i++) {
    const char* name = CHAR(STRING_ELT(assets, i));
    SEXP status_name = sl::as_list(sl::get(status, name));
    SEXP report_name = sl::as_list(sl::get(report, name));
    
    double weight = (total_portfolio > 0) ? asset_totals[i] / total_portfolio : 0.0;
    sl::NumVec rs = sl::num_vec(sl::get(report_name, "share"));
    rs[index - 1] = weight;
    sl::set(status_name, "differ", weight);
    
    sl::set(status, name, status_name);
  }
  
  sl::put(input, 1, status);
  sl::put(input, 4, report);
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
static void batch_market_update(SEXP input, SEXP assets, 
                                int start_idx, int end_idx) {
  SEXP status = sl::as_list(sl::at(input, 1));
  SEXP market = sl::as_list(sl::at(input, 2));
  SEXP report = sl::as_list(sl::at(input, 4));
  
  int n_assets = Rf_xlength(assets);
  int n_days = end_idx - start_idx + 1;
  if (n_days <= 0) return;
  
  // Portfolio-Tagessummen fuer Gewichtsberechnung
  std::vector<double> portfolio_totals(n_days, 0.0);
  
  // === PASS 1: Preise, Worth, Total berechnen und Report schreiben ===
  // Pro Asset: Ein Durchlauf ueber den Preisvektor (cache-freundlich)
  for (int a = 0; a < n_assets; a++) {
    const char* name = CHAR(STRING_ELT(assets, a));
    SEXP status_name = sl::as_list(sl::get(status, name));
    SEXP market_name = sl::as_list(sl::get(market, name));
    SEXP report_name = sl::as_list(sl::get(report, name));
    
    double count = sl::as_double(sl::get(status_name, "count"));
    double money = sl::as_double(sl::get(status_name, "money"));
    
    sl::NumVec prices = sl::num_vec(sl::get(market_name, "asset_price"));
    sl::NumVec rw = sl::num_vec(sl::get(report_name, "worth"));
    sl::NumVec rm = sl::num_vec(sl::get(report_name, "money"));
    sl::NumVec rf = sl::num_vec(sl::get(report_name, "flows"));
    sl::NumVec rt = sl::num_vec(sl::get(report_name, "total"));
    
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
    sl::set(status_name, "price", last_price);
    sl::set(status_name, "worth", last_worth);
    sl::set(status_name, "total", last_total);
    
    sl::set(status, name, status_name);
  }
  
  // === PASS 2: Portfolio-Gewichte berechnen ===
  for (int a = 0; a < n_assets; a++) {
    const char* name = CHAR(STRING_ELT(assets, a));
    SEXP status_name = sl::as_list(sl::get(status, name));
    SEXP report_name = sl::as_list(sl::get(report, name));
    
    sl::NumVec rs = sl::num_vec(sl::get(report_name, "share"));
    sl::NumVec rt = sl::num_vec(sl::get(report_name, "total"));
    
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
    sl::set(status_name, "differ", last_weight);
    sl::set(status, name, status_name);
  }
  
  sl::put(input, 1, status);
  sl::put(input, 4, report);
}

// ===========================================================================
// .CALL-HUELLEN (registriert in init.c). Argumente wie die frueheren
// Rcpp-Huellen: input als Liste, name als Rcpp::String (erstes Element eines
// Zeichenvektors), assets als Zeichenvektor; Rueckgabe NULL (R: invisible()).
// ===========================================================================

extern "C" SEXP C_sim_dca_flows(SEXP s_input, SEXP s_name, SEXP s_flows, SEXP s_index) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_rstring(s_name);
    double flows = sl::as_double(s_flows);
    int index = sl::as_int(s_index);
    dca_flows_allocation(input, name, flows, index);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_buy_report(SEXP s_input, SEXP s_name, SEXP s_index, SEXP s_trade_count,
                                 SEXP s_trade_price, SEXP s_market_price) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_rstring(s_name);
    int index = sl::as_int(s_index);
    double trade_count = sl::as_double(s_trade_count);
    double trade_price = sl::as_double(s_trade_price);
    double market_price = sl::as_double(s_market_price);
    calculate_buy_report(input, name, index, trade_count, trade_price, market_price);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_sell_report(SEXP s_input, SEXP s_name, SEXP s_index, SEXP s_trade_count,
                                  SEXP s_trade_price, SEXP s_market_price, SEXP s_capital_gains_tax) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_rstring(s_name);
    int index = sl::as_int(s_index);
    double trade_count = sl::as_double(s_trade_count);
    double trade_price = sl::as_double(s_trade_price);
    double market_price = sl::as_double(s_market_price);
    double capital_gains_tax = sl::as_double(s_capital_gains_tax);
    calculate_sell_report(input, name, index, trade_count, trade_price, market_price, capital_gains_tax);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_total_report(SEXP s_input, SEXP s_assets, SEXP s_index) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    SEXP assets = sl::as_character(s_assets);
    int index = sl::as_int(s_index);
    calculate_total_report(input, assets, index);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_buy(SEXP s_input, SEXP s_name, SEXP s_index, SEXP s_trade_count,
                          SEXP s_trade_price, SEXP s_market_price) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_rstring(s_name);
    int index = sl::as_int(s_index);
    double trade_count = sl::as_double(s_trade_count);
    double trade_price = sl::as_double(s_trade_price);
    double market_price = sl::as_double(s_market_price);
    perform_trade_buy_cpp(input, name, index, trade_count, trade_price, market_price);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_market_update(SEXP s_input, SEXP s_assets, SEXP s_index) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    SEXP assets = sl::as_character(s_assets);
    int index = sl::as_int(s_index);
    perform_market_update(input, assets, index);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_market_update_batch(SEXP s_input, SEXP s_assets, SEXP s_start_idx, SEXP s_end_idx) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    SEXP assets = sl::as_character(s_assets);
    int start_idx = sl::as_int(s_start_idx);
    int end_idx = sl::as_int(s_end_idx);
    batch_market_update(input, assets, start_idx, end_idx);
    return R_NilValue;
  });
}
