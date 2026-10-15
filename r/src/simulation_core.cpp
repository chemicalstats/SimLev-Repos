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
// input[k] hier und in fifo_core_RCpp.cpp anpassen.
//
// In-place-Semantik: Rcpp::List ist ein Verweis auf das R-Objekt, keine Kopie. Die
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

#include <Rcpp.h>
#include <vector>
#include <string>
#include <algorithm>
#include <cmath>

using namespace Rcpp;

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
// EXPORTIERTE FUNKTIONEN
// ===========================================================================

//' DCA-Zufluss einem Asset zuordnen
//'
//' Bucht die Sparplan-Einzahlung in den Simulationszustand (flows, money, total).
//'
//' @param input Liste des Simulationszustands (sim_mem)
//' @param name Asset-Name
//' @param flows Einzuzahlender Betrag in EUR
//' @param index Tagesindex (1-basiert)
//' @noRd
// [[Rcpp::export]]
void dca_flows_allocation(List input, String name, double flows, int index) {
  List status = input[1];
  List report = input[4];
  
  List status_name = as<List>(status[name]);
  List report_name = as<List>(report[name]);
  
  // flows im Report aktualisieren
  NumericVector report_flows = as<NumericVector>(report_name["flows"]);
  report_flows[index - 1] = flows;
  report_name["flows"] = report_flows;
  
  // money (Cash) aktualisieren
  double money = as<double>(status_name["money"]);
  money += flows;
  status_name["money"] = money;
  
  NumericVector report_money = as<NumericVector>(report_name["money"]);
  report_money[index - 1] = money;
  report_name["money"] = report_money;
  
  // total aktualisieren
  double worth = as<double>(status_name["worth"]);
  double total = money + worth;
  status_name["total"] = total;
  
  NumericVector report_total = as<NumericVector>(report_name["total"]);
  report_total[index - 1] = total;
  report_name["total"] = report_total;
  
  // Zurueckschreiben
  report[name] = report_name;
  status[name] = status_name;
  input[4] = report;
  input[1] = status;
}


//' Report nach einem Kauf aktualisieren
//'
//' @param input Liste des Simulationszustands (sim_mem)
//' @param name Asset-Name
//' @param index Tagesindex (1-basiert)
//' @param trade_count Anzahl gekaufter Anteile
//' @param trade_price Gezahlter Preis je Anteil
//' @param market_price Aktueller Marktkurs
//' @noRd
// [[Rcpp::export]]
void calculate_buy_report(List input, String name, int index, 
                          double trade_count, double trade_price, 
                          double market_price) {
  List status = input[1];
  List report = input[4];
  
  List status_name = status[name];
  List report_name = report[name];
  
  double count = as<double>(status_name["count"]);
  double money = as<double>(status_name["money"]);
  
  count += trade_count;
  status_name["count"] = count;
  status_name["price"] = market_price;
  
  double worth = count * market_price;
  status_name["worth"] = worth;
  
  money -= (trade_count * trade_price);
  status_name["money"] = money;
  
  double total = worth + money;
  status_name["total"] = total;
  
  status[name] = status_name;
  input[1] = status;
  
  NumericVector worth_vec = report_name["worth"];
  worth_vec[index - 1] = worth;
  report_name["worth"] = worth_vec;
  
  NumericVector money_vec = report_name["money"];
  money_vec[index - 1] = money;
  report_name["money"] = money_vec;
  
  NumericVector total_vec = report_name["total"];
  total_vec[index - 1] = total;
  report_name["total"] = total_vec;
  
  report[name] = report_name;
  input[4] = report;
}


//' Report nach einem Verkauf aktualisieren
//'
//' @param input Liste des Simulationszustands (sim_mem)
//' @param name Asset-Name
//' @param index Tagesindex (1-basiert)
//' @param trade_count Anzahl verkaufter Anteile
//' @param trade_price Erhaltener Preis je Anteil
//' @param market_price Aktueller Marktkurs
//' @param capital_gains_tax Gezahlte Steuer auf den Gewinn
//' @noRd
// [[Rcpp::export]]
void calculate_sell_report(List input, String name, int index,
                           double trade_count, double trade_price,
                           double market_price, double capital_gains_tax) {
  List status = input[1];
  List report = input[4];
  
  List status_name = status[name];
  List report_name = report[name];
  
  double count = as<double>(status_name["count"]);
  double money = as<double>(status_name["money"]);
  
  count -= trade_count;
  status_name["count"] = count;
  status_name["price"] = market_price;
  
  double worth = count * market_price;
  status_name["worth"] = worth;
  
  money += (trade_count * trade_price) - capital_gains_tax;
  status_name["money"] = money;
  
  double total = worth + money;
  status_name["total"] = total;
  
  status[name] = status_name;
  input[1] = status;
  
  NumericVector worth_vec = report_name["worth"];
  worth_vec[index - 1] = worth;
  report_name["worth"] = worth_vec;
  
  NumericVector money_vec = report_name["money"];
  money_vec[index - 1] = money;
  report_name["money"] = money_vec;
  
  NumericVector total_vec = report_name["total"];
  total_vec[index - 1] = total;
  report_name["total"] = total_vec;
  
  report[name] = report_name;
  input[4] = report;
}


//' Gesamtreport fuer alle Assets berechnen
//'
//' Aktualisiert Status und Report aller Assets an einem Tag.
//' Berechnet die Portfolio-Gewichte neu (gespeichert im Status-Feld "differ")
//' auf Basis der aktuellen Marktwerte.
//'
//' @param input Liste des Simulationszustands (sim_mem)
//' @param assets Zeichenvektor der Asset-Namen
//' @param index Tagesindex (1-basiert)
//' @noRd
// [[Rcpp::export]]
void calculate_total_report(List input, CharacterVector assets, int index) {
  List status = input[1];
  List market = input[2];
  List report = input[4];
  
  // Erster Durchlauf: Kurse aktualisieren und Summen berechnen
  for (int i = 0; i < assets.size(); i++) {
    String name = assets[i];
    
    List status_name = as<List>(status[name]);
    List market_name = as<List>(market[name]);
    List report_name = as<List>(report[name]);
    
    NumericVector asset_price = as<NumericVector>(market_name["asset_price"]);
    double price = asset_price[index - 1];
    status_name["price"] = price;
    
    double count = as<double>(status_name["count"]);
    double worth = price * count;
    status_name["worth"] = worth;
    
    NumericVector report_worth = as<NumericVector>(report_name["worth"]);
    report_worth[index - 1] = worth;
    report_name["worth"] = report_worth;
    
    double money = as<double>(status_name["money"]);
    NumericVector report_money = as<NumericVector>(report_name["money"]);
    report_money[index - 1] = money;
    report_name["money"] = report_money;
    
    double total = money + worth;
    status_name["total"] = total;
    NumericVector report_total = as<NumericVector>(report_name["total"]);
    report_total[index - 1] = total;
    report_name["total"] = report_total;
    
    status[name] = status_name;
    report[name] = report_name;
  }
  
  // Gesamtwert des Portfolios berechnen
  double total_worth = 0.0;
  for (int i = 0; i < assets.size(); i++) {
    String name = assets[i];
    List status_name = as<List>(status[name]);
    total_worth += as<double>(status_name["total"]);
  }
  
  // Zweiter Durchlauf: Portfolio-Gewichte berechnen und speichern
  //
  // Feldkonvention (historisch bedingt):
  //   status["actual"] = normalisiertes Zielgewicht (wird hier NICHT ueberschrieben)
  //   status["differ"] = aktuelles Portfolio-Gewicht (wird hier aktualisiert)
  //
  for (int i = 0; i < assets.size(); i++) {
    String name = assets[i];
    
    List status_name = as<List>(status[name]);
    List report_name = as<List>(report[name]);
    
    double total = as<double>(status_name["total"]);
    double current_weight = (total_worth > 0) ? total / total_worth : 0.0;
    
    // Aktuelles Portfolio-Gewicht in "differ" speichern
    // (R-Code liest dies als sim_mem[[2]][[name]][[8]] fuer DCA/Rebalancing)
    status_name["differ"] = current_weight;
    
    // Report: share-Vektor aktualisieren
    NumericVector report_share = as<NumericVector>(report_name["share"]);
    report_share[index - 1] = current_weight;
    report_name["share"] = report_share;
    
    status[name] = status_name;
    report[name] = report_name;
  }
  
  input[1] = status;
  input[4] = report;
}


//' Kauf ausfuehren (C++-Kern)
//'
//' Fuehrt die Kern-Kauflogik aus: ruft calculate_buy_report auf (Report- und Status-Update),
//' legt einen FIFO-Lot-Eintrag an und erhoeht buy_count. Alles per Referenz.
//'
//' Der R-Wrapper uebernimmt: Berechnung von trade_count (Spread, Bruchteile), Detailausgabe.
//'
//' @param input Liste des Simulationszustands (wird direkt veraendert)
//' @param name Asset-Name
//' @param index Tagesindex (1-basiert)
//' @param trade_count Anzahl zu kaufender Anteile
//' @param trade_price Preis je Anteil (nach Spread)
//' @param market_price Marktkurs (vor Spread)
//' @noRd
// [[Rcpp::export]]
void perform_trade_buy_cpp(List input, String name, int index,
                           double trade_count, double trade_price,
                           double market_price) {
  
  // 1. Report- und Status-Update (ueber vorhandene C++-Funktion)
  calculate_buy_report(input, name, index, trade_count, trade_price, market_price);
  
  // 2. FIFO-Lot erstellen
  List trades = input[3];  // trades
  List trades_name = as<List>(trades[name]);
  
  // Kaufdatum aus market[[name]][["asset_day"]]
  List market = input[2];
  List market_name = as<List>(market[name]);
  DateVector asset_days = as<DateVector>(market_name["asset_day"]);
  Date event_date = asset_days[index - 1];
  
  // Lot-Felder: Zugriff ueber Namen, konsistent mit dem R-Code
  // buy[["date"]], buy[["type"]], buy[["count"]], buy[["price"]],
  // buy[["remaining"]], buy[["original"]], (buy[["vp"]] wird später am 31.12. ergänzt)
  List lot = List::create(
    Named("date") = Date(event_date),
    Named("type") = "Buy",
    Named("count") = trade_count,
    Named("price") = trade_price,
    Named("remaining") = trade_count,
    Named("original") = trade_count
  );
  
  // 3. Lot an buys-Liste anhängen
  int buy_count = as<int>(trades_name["buy_count"]) + 1;
  trades_name["buy_count"] = buy_count;
  
  List buys = as<List>(trades_name["buys"]);
  buys[buy_count - 1] = lot;  // 0-basierter Index
  trades_name["buys"] = buys;
  
  trades[name] = trades_name;
  input[3] = trades;
}


//' Markt-Update fuer einen einzelnen Tag (Fast Path)
//'
//' Aktualisiert Kurse, worth, total und Portfolio-Gewichte aller Assets
//' an einem Tag. Ersetzt das fruehere perform_market_update in R.
//'
//' @param input Liste des Simulationszustands (wird direkt veraendert)
//' @param assets Zeichenvektor der Asset-Namen
//' @param index Tagesindex (1-basiert)
//' @noRd
// [[Rcpp::export]]
void perform_market_update(List input, CharacterVector assets, int index) {
  List status = input[1];
  List market = input[2];
  List report = input[4];
  
  int n_assets = assets.size();
  double total_portfolio = 0.0;
  std::vector<double> asset_totals(n_assets);
  
  for (int i = 0; i < n_assets; i++) {
    String name = assets[i];
    List status_name = as<List>(status[name]);
    List market_name = as<List>(market[name]);
    List report_name = as<List>(report[name]);
    
    NumericVector prices = as<NumericVector>(market_name["asset_price"]);
    double count = as<double>(status_name["count"]);
    double money = as<double>(status_name["money"]);
    double worth = count * prices[index - 1];
    double total = worth + money;
    
    asset_totals[i] = total;
    total_portfolio += total;
    
    // Report-Vektoren in-place aktualisieren
    NumericVector rw = as<NumericVector>(report_name["worth"]);
    NumericVector rm = as<NumericVector>(report_name["money"]);
    NumericVector rf = as<NumericVector>(report_name["flows"]);
    NumericVector rt = as<NumericVector>(report_name["total"]);
    rw[index - 1] = worth;
    rm[index - 1] = money;
    rf[index - 1] = 0.0;
    rt[index - 1] = total;
    
    // Status aktualisieren
    status_name["price"] = prices[index - 1];
    status_name["worth"] = worth;
    status_name["total"] = total;
    
    status[name] = status_name;
  }
  
  // Gewichte berechnen und schreiben
  for (int i = 0; i < n_assets; i++) {
    String name = assets[i];
    List status_name = as<List>(status[name]);
    List report_name = as<List>(report[name]);
    
    double weight = (total_portfolio > 0) ? asset_totals[i] / total_portfolio : 0.0;
    NumericVector rs = as<NumericVector>(report_name["share"]);
    rs[index - 1] = weight;
    status_name["differ"] = weight;
    
    status[name] = status_name;
  }
  
  input[1] = status;
  input[4] = report;
}


//' Gebuendeltes Markt-Update fuer zusammenhaengende Fast-Path-Tage
//'
//' Vektorisiertes Update fuer einen Tagesbereich ohne Trades, DCA, Rebalancing,
//' Jahreswechsel oder "Staking"-Ereignisse. An diesen Tagen sind count und money
//' je Asset konstant; worth und total sind daher einfach mit dem Kurs skalierte Vektoren.
//'
//' Das ersetzt Hunderte einzelner Aufrufe von perform_market_update() durch
//' eine einzige kompakte C++-Schleife ueber die Kursvektoren.
//'
//' @param input Liste des Simulationszustands (wird direkt veraendert)
//' @param assets Zeichenvektor der Asset-Namen
//' @param start_idx Erster Tagesindex (1-basiert, einschliesslich)
//' @param end_idx Letzter Tagesindex (1-basiert, einschliesslich)
//' @noRd
// [[Rcpp::export]]
void batch_market_update(List input, CharacterVector assets, 
                         int start_idx, int end_idx) {
  List status = input[1];
  List market = input[2];
  List report = input[4];
  
  int n_assets = assets.size();
  int n_days = end_idx - start_idx + 1;
  if (n_days <= 0) return;
  
  // Portfolio-Tagessummen fuer Gewichtsberechnung
  std::vector<double> portfolio_totals(n_days, 0.0);
  
  // === PASS 1: Preise, Worth, Total berechnen und Report schreiben ===
  // Pro Asset: Ein Durchlauf ueber den Preisvektor (cache-freundlich)
  for (int a = 0; a < n_assets; a++) {
    String name = assets[a];
    List status_name = as<List>(status[name]);
    List market_name = as<List>(market[name]);
    List report_name = as<List>(report[name]);
    
    double count = as<double>(status_name["count"]);
    double money = as<double>(status_name["money"]);
    
    NumericVector prices = as<NumericVector>(market_name["asset_price"]);
    NumericVector rw = as<NumericVector>(report_name["worth"]);
    NumericVector rm = as<NumericVector>(report_name["money"]);
    NumericVector rf = as<NumericVector>(report_name["flows"]);
    NumericVector rt = as<NumericVector>(report_name["total"]);
    
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
    status_name["price"] = last_price;
    status_name["worth"] = last_worth;
    status_name["total"] = last_total;
    
    status[name] = status_name;
  }
  
  // === PASS 2: Portfolio-Gewichte berechnen ===
  for (int a = 0; a < n_assets; a++) {
    String name = assets[a];
    List status_name = as<List>(status[name]);
    List report_name = as<List>(report[name]);
    
    NumericVector rs = as<NumericVector>(report_name["share"]);
    NumericVector rt = as<NumericVector>(report_name["total"]);
    
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
    status_name["differ"] = last_weight;
    status[name] = status_name;
  }
  
  input[1] = status;
  input[4] = report;
}
