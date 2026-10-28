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

## 2026-10-26 – Schnittstelle 0.5.0 festgehalten
- Was: Erste Festschreibung der öffentlichen Schnittstelle von R, Python und Julia 0.5.0 (Stand nach Etappe 6.5: neue Namen, `simulation()` mit Bausteinen, Aufrufer umgestellt, Argumentordnung). R 113 Funktionen und 75 S3-Methoden, Python 118 Funktionen, 77 Methoden und 52 Klassen, Julia 128 Funktionen, 75 Methoden und 9 Typen.
- Warum: Etappe 6.6. Spätere Erweiterungen (zuerst 6.5b) sollen die Schnittstelle nur gezielt und nachvollziehbar ändern; die Tests in allen drei Sprachen prüfen dagegen.
