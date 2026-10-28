# Änderungen der eingefrorenen Schnittstelle (`tools/api_snapshot/frozen/`)

Jede Festschreibung von `frozen/` hat hier einen Eintrag, der neueste oben.
`tools/api_snapshot/run.sh --freeze` schreibt `frozen/` nur, wenn der oberste
Eintrag neu ist (seine Überschrift steht noch nicht als `stand` in `frozen/`)
und diese Form hat:

```
## JJJJ-MM-TT – Titel
- Was: welche Funktionen, Argumente oder Standardwerte sich ändern
- Warum: Grund (Etappe, Spezifikation, Fehler)
```

Die Überschrift ohne `## ` wird als `stand` in alle drei Dateien geschrieben;
`run.sh --check` meldet einen `stand`, der hier nicht steht.

## 2026-10-27 – Etappe 8.0: Auswahl aus SimLevWrapperNav
- Was: R neu die S3-Methode `[.SimLevWrapperNav(x, ...)`: jede Auswahl (`x[i, ]`, `x[j]`, `x[]`, über `[` auch `head()`, `tail()`, `subset()`) liefert einen gewöhnlichen data.frame ohne Klasse und ohne die Attribute `inner`/`wrapper`. Python (Auswahl = `pandas.DataFrame` ohne `attrs`) und Julia (`rows()` ohne Klasse und Attribute) ohne Änderung ihrer Schnittstelle; im Abgleich der Sprachen zwei neue bewusste Abweichungen (`[.SimLevWrapperNav` fehlt in Python und Julia, `known_differences.tsv`). `strategy_from_weights(weights, ...)` und `portfolio_template(name, map, ...)` nehmen `wrapper` je Asset über `...` (keine Signaturänderung). Übrige Funktionen, Argumente und Standardwerte unverändert.
- Warum: Entscheidung des Nutzers vom 27.10.2026 (Etappe 8.0, Auftrag 8.0 X): Eine Auswahl aus dem Anteilswert ist in allen drei Sprachen eine gewöhnliche Tabelle, weil das innere Ergebnis nicht mehr zum Ausschnitt passt.

## 2026-10-26 – Etappe 6.5c C+D: Fonds-Wrapper
- Was: Neu `wrapper_config(strategy, rebalance = NULL, costs = funds_costs(), order_fee = NULL, volume = NULL)` und `wrapper_nav(data, wrapper, splits = NULL)` (R, Python, Julia; in Python mit Schlüsselwörtern nach `strategy` bzw. `wrapper`, in Julia nach `;`), `asset_config()` mit neuem letztem Argument `wrapper` (Standard `NULL`/`None`/`nothing`, Stelle 11), Druckmethoden `print.SimLevWrapperConfig` und `print.SimLevWrapperNav` (Python: Klassen `SimLevWrapperConfig` und `SimLevWrapperNav` mit `format()`, Julia: `register_print!`). Übrige Funktionen, Argumente und Standardwerte unverändert; im Abgleich der Sprachen keine neue Abweichung.
- Warum: Entscheidung des Nutzers vom 26.10.2026 (Etappe 6.5c, Entscheidungen E1–E9 in `SPEZ-6.5c-Fonds-Wrapper.md`): Fonds-Wrapper als eigene Kursreihe (Anteilswert) aus einer inneren Strategie, in R umgesetzt in Teil C, in Python und Julia in Teil D.

## 2026-10-26 – Etappe 6.5c A+B: Standard-Spread 0, alter Fondsmodus entfernt
- Was: `asset_config()` hat den Standardwert `spread = 0` statt `0.1` (R, Python, Julia). `simulation()` verliert das Argument `funds` (R, Python, Julia); `simulation(..., funds = …)` ergibt den üblichen Fehler der Sprache für ein unbekanntes Argument. `funds_costs()` und `print.SimLevFundsCosts` bleiben unverändert.
- Warum: Entscheidung des Nutzers vom 26.10.2026 (Etappe 6.5c, Entscheidungen E4 und E6): Der alte Fondsmodus wird durch den Fonds-Wrapper `wrapper_config()` ersetzt (folgt, Teil C/D), für den `funds_costs()` der Kostenbaustein ist; innere Spreads gelten unverändert, daher der Standard 0.

## 2026-10-26 – Schnittstelle 0.5.0 festgehalten
- Was: Erste Festschreibung der öffentlichen Schnittstelle von R, Python und Julia 0.5.0 (Stand nach Etappe 6.5: neue Namen, `simulation()` mit Bausteinen, Aufrufer umgestellt, Argumentordnung). R 113 Funktionen und 75 S3-Methoden, Python 118 Funktionen, 77 Methoden und 52 Klassen, Julia 128 Funktionen, 75 Methoden und 9 Typen.
- Warum: Etappe 6.6. Spätere Erweiterungen (zuerst 6.5b) sollen die Schnittstelle nur gezielt und nachvollziehbar ändern; die Tests in allen drei Sprachen prüfen dagegen.
