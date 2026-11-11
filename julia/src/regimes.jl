# Regimes – Gegenstück zu r/R/regimes.R und python/simlev/regimes.py
#
#   regime_hmm()     schätzt K Marktphasen aus den Periodenrenditen einer oder
#                    mehrerer Reihen (Gauss'sches Hidden-Markov-Modell, Baum-Welch,
#                    mehrere Startwerte); gefilterte und geglättete
#                    Wahrscheinlichkeiten sowie der Viterbi-Pfad
#   regime_states()  legt die Regime auf einen Tageskalender (Standard: gefiltert,
#                    verzögert, ohne Zukunftsinformation)
module Regimes

import ..SimLev
using ..SimLev: _which_max   # util.jl (seit 1.6.1 eine Fassung)
using ..SimLev: _grid_lines!, _grid_svg
using Dates
using ..SimLev: chk_msg, chk_stop   # pruefen.jl (seit 1.6.5, Entscheidung 193)

export regime_hmm, regime_states

const _NA = SimLev.NA
const RFrame = SimLev.RFrame
const RList = SimLev.RList
const RVector = SimLev.RVector
const NamedMat = SimLev.NamedMat

_D() = SimLev.Dependence
_fmat(X) = SimLev.Dependence._fmat(X)
_fvec(x) = SimLev.Dependence._fvec(x)

"`max.col(m, ties.method = \"first\")` je Zeile (NA bei NaN in der Zeile)."
function _max_col_first(M)
    M = _fmat(M)
    out = Vector{Union{Missing,Int}}(undef, size(M, 1))
    for r in 1:size(M, 1)
        if any(isnan, view(M, r, :))
            out[r] = missing
            continue
        end
        m = 1; a = M[r, 1]
        for c in 2:size(M, 2)
            b = M[r, c]
            a < b && (a = b; m = c)
        end
        out[r] = m
    end
    out
end

"Viterbi-Pfad aus Log-Emissionen, Log-Übergangsmatrix und Log-Startverteilung (`.hmm_viterbi`)."
function _hmm_viterbi(lB, lA, lp0)
    lB = _fmat(lB); lA = _fmat(lA); lp0 = _fvec(lp0)
    # seit 1.6.5 (CR2-X7-2) ohne NA/NaN über den Kern (sl_hmm_viterbi, erstes Maximum; gleicher Pfad)
    if !(any(isnan, lB) || any(isnan, lA) || any(isnan, lp0))
        return Int[Int(v) for v in SimLev.SLib.hmm_viterbi(lB, lA, lp0)]
    end
    Tn, k = size(lB)
    dl = lp0 .+ lB[1, :]
    bp = zeros(Int, Tn, k)
    for t in 2:Tn
        cand = dl .+ lA                      # cand[i, j] = dl[i] + lA[i, j]
        im = _max_col_first(permutedims(cand))
        if any(ismissing, im)
            wm = [_which_max(cand[:, j]) for j in 1:k]
            any(w -> w === nothing, wm) && error("replacement has length zero")
            imv = Int[w for w in wm]
            mx = Float64[_D()._rmax(cand[:, j]) for j in 1:k]
        else
            imv = Int[i for i in im]
            mx = Float64[cand[imv[j], j] for j in 1:k]
        end
        bp[t, :] = imv
        dl = mx .+ lB[t, :]
    end
    path = zeros(Int, Tn)
    w = _which_max(dl)
    w === nothing && error("replacement has length zero")
    path[Tn] = w
    for t in Tn:-1:2
        path[t-1] = bp[t, path[t]]
    end
    path
end

"""
Baum-Welch-EM des Gauss'schen HMM aus einem Startwert (`.hmm_em`).

`X`: Matrix Perioden × Spalten; `k`: Anzahl Zustände; `init`: NamedTuple
`(mu, S, A)` (mu k × Spalten, S Vektor von k Kovarianzmatrizen, A
Übergangsmatrix k × k), Startverteilung gleichverteilt; `max_iter`, `tol`:
Höchstzahl Iterationen und relative Abbruchschranke (Abbruch, wenn sich die
Log-Likelihood um weniger als `tol * (1 + |logL|)` ändert); `ridge`: Matrix,
die jeder Kovarianzmatrix im M-Schritt zugeschlagen wird. Liefert
`(mu, S, A, p0, ll, filtered, smoothed, lB, iter)`; ll, filtered, smoothed und
lB zu den gelieferten (zuletzt geschätzten) Parametern.
"""
function _hmm_em(X, k, init, max_iter, tol, ridge)
    # E- und M-Schritte im Kern (core/research_core_impl.h, hmm_em; bis 1.4.3 hier in Julia); ein Fehler dort
    # verwirft wie in R den Startwert (regime_hmm fängt ihn ab)
    ni = trunc(Int, max_iter)                     # max_iter = 0: nur der E-Schritt zum Startwert
    ni < 0 && error("argument of length 0")       # R: seq_len(max_iter) scheitert
    r = SimLev.DependenceCore.hmm_em(_fmat(X), Int(k), init.mu, init.S, init.A, ni, Float64(tol), _fmat(ridge))
    r === nothing && error("regime_hmm: EM-Schritt fehlgeschlagen")
    return r
end

"""
HMM-Startwert aus einer Einteilung `cl` der Perioden in k Gruppen (`.hmm_init_cl`):
Mittelwert und Kovarianz (plus `ridge`) je Gruppe, Übergangsmatrix 0.9 auf der
Diagonale, Rest gleich verteilt.
"""
function _hmm_init_cl(X, cl, k, ridge)
    D = _D()
    X = _fmat(X)
    d = size(X, 2)
    k = Int(k)
    mu = Matrix{Float64}(undef, k, d)
    for j in 1:k
        mu[j, :] = D._colmeans(X[cl .== j, :])
    end
    S = [_fmat(SimLev.RStats.cov(X[cl .== j, :])) .+ ridge for j in 1:k]
    off = 0.1 / max(1, k - 1)
    A = fill(off, k, k)
    for i in 1:k
        A[i, i] += 0.9 - off
    end
    (mu = mu, S = S, A = A)
end

"""
Deterministischer HMM-Startwert (`.hmm_init_rank`): Rangeinteilung einer
rollierenden Volatilität (Wurzel des gleitenden Mittelwerts von `rowSums(X^2)`
über `win` Perioden; fehlende Anfangswerte = Median) in k gleich große Gruppen
(`cut(rank(vol), k)`), daraus `_hmm_init_cl`.
"""
function _hmm_init_rank(X, k, win, ridge)
    D = _D()
    X = _fmat(X)
    vol = sqrt.(D._roll_mean(D._rowsums(X .* X), win))
    if any(isnan, vol)
        md = D._median(vol; na_rm = true)
        vol = [isnan(v) ? md : v for v in vol]
    end
    _hmm_init_cl(X, D._cut_n(D._rank_avg(vol), Int(k)), k, ridge)
end

"`stats::cov2cor` (über RStats, mit R's Warnung)."
_cov2cor(V) = _fmat(SimLev.RStats.cov2cor(_fmat(V)))

"""Datumsvektor (Date, DateTime oder Text wie R Date/character), keine Zahl, kein Faktor, nicht leer
(Entscheidungen 7 und 15; R `regime_states`)."""
function _e4_dates(@nospecialize(dv), fn)
    dv isa RVector && (dv = dv.values)
    isd(v) = v isa Union{Date,DateTime,AbstractString} || v === missing
    ok = !(dv isa SimLev.RFmt.RFactor) && (dv isa Union{Date,DateTime,AbstractString} ||
         (dv isa AbstractVector && !(dv isa AbstractMatrix) && !isempty(dv) && all(isd, dv) &&
          # nur fehlende Werte: gültig, wenn der Vektor als Datum oder Text getypt ist (seit 1.6.4, T3-N9; R
          # as.Date(c(NA, NA))); ein ungetyptes [missing] bleibt abgelehnt
          ((nonmissingtype(eltype(dv)) !== Union{} && nonmissingtype(eltype(dv)) <: Union{Date,DateTime,AbstractString}) ||
           !all(v -> v === missing, dv))))
    ok || SimLev.chk_stop("e4.daten", fn)
    return dv
end

function _isint_scalar(k)
    k isa AbstractVector && (length(k) == 1 ? (k = k[1]) : return false)
    (k isa Real && !(k isa Bool)) || return false
    kf = Float64(k)
    isfinite(kf) && kf == Float64(SimLev.RFmt.r_round(kf)) && kf >= 2
end

"""
    regime_hmm(data, columns; k = 2, frequency = "week", n_start = 5, max_iter = 300,
               tol = 1e-7, seed = 1)

Hidden-Markov-Modell für Marktregime.

Gauß'sches HMM mit `k` Zuständen (eigener Mittelwert und eigene Kovarianzmatrix je Zustand) auf den
Periodenrenditen der Spalten, geschätzt mit dem Baum-Welch-Algorithmus aus mehreren Startwerten. Die Zustände
werden nach Volatilität sortiert (Zustand 1 = ruhigster). Für Handelsregeln und bedingte Analysen sind die
**gefilterten** Wahrscheinlichkeiten maßgeblich - sie nutzen nur Daten bis zum jeweiligen Zeitpunkt;
geglättete Wahrscheinlichkeiten und der Viterbi-Pfad verwenden die ganze Historie und dienen nur der
Beschreibung.

# Argumente
- `data`: Tabelle (RFrame) mit Spalte `date` (Date oder umwandelbar) und den Kursspalten (Niveaus, keine
  Renditen); fehlende Kurse werden fortgeschrieben. Das Argument `data` von `plot()` wird nicht verwendet.
- `columns`: Zeichenvektor der Kursspalten (eine oder mehrere; bei mehreren ein multivariates Modell mit
  Kovarianzmatrix je Zustand).
- `k`: Anzahl Zustände (ganze Zahl >= 2, Standard 2); es werden mindestens `50 * k` Perioden benötigt. Spalten
  ohne Schwankung (z. B. konstante Kurse) sind ein Fehler.
  Seit 1.6.4 höchstens 10^8.
- `frequency`: Periodenlänge der Renditen: `"week"` (Standard, ISO-Wochen), `"day"` oder `"month"`. Bei
  `"day"` entfallen Tage, an denen alle Renditen 0 sind (z. B. fortgeschriebene Wochenenden).
- `n_start`: Anzahl Startwerte (ganze Zahl, Standard 5): der erste aus Quantilen einer rollierenden
  Volatilität, die übrigen zufällig; es zählt das Ergebnis mit der höchsten Log-Likelihood.
  Seit 1.6.4 höchstens 10^8.
- `max_iter`, `tol`: Höchstzahl Baum-Welch-Iterationen je Start (Standard 300) und relative Abbruchschranke:
  Abbruch, wenn sich die Log-Likelihood um weniger als `tol * (1 + |logL|)` ändert (Standard 1e-7).
  Seit 1.6.4 max_iter eine ganze Zahl von 0 bis 10^8, tol eine Zahl ≥ 0.
- `seed`: Startwert (Standard 1) für die zufälligen Startzuordnungen (nur bei `n_start > 1`). Mit Startwert
  (ganze Zahl, |seed| < 2^53) ist das Ergebnis reproduzierbar und der Zufallszustand von SimLev bleibt
  unverändert; mit `nothing` wird genau einmal ein Startwert aus dem Zufallszustand von SimLev gezogen (siehe
  `simlev_seed()`), wiederholte Aufrufe liefern dann verschiedene Ergebnisse. `set.seed()` wirkt nicht.

# Rückgabe
Objekt der Klasse `SimLevHMM`, eine Liste mit

- `transition`: Übergangsmatrix k x k (Zeile = von, Spalte = nach; Namen `Z1`, ..., `Zk`).
- `means`: Matrix Zustand x Spalte: mittlere Log-Rendite, annualisiert (mal `ppy`), in Prozent p. a.
- `volatility`: Matrix Zustand x Spalte: Volatilität, annualisiert (mal √(ppy)), in Prozent p. a.
- `correlation`: Liste der Korrelationsmatrizen je Zustand.
- `filtered`, `smoothed`: Matrizen Perioden x Zustand der gefilterten bzw. geglätteten Wahrscheinlichkeiten
  (Anteil).
- `viterbi`: wahrscheinlichster Zustandspfad (ganze Zahlen 1 bis k).
- `dates`: Perioden-Enddaten (eine je Zeile von `filtered`).
- `columns`, `k`, `frequency`: Einstellungen.
- `loglik`, `bic`: Log-Likelihood und BIC zu den gelieferten Parametern (nach dem letzten M-Schritt neu
  berechnet, ebenso `filtered` und `smoothed`).
- `initial`: Startverteilung der Zustände (Anteile).
- `duration`: erwartete Dauer je Zustand in Perioden, 1 / (1 - p_jj).
- `ppy`: Perioden je Jahr, geschätzt als (Anzahl Perioden - 1) / (Zeitspanne in Tagen / 365.25).
- `share`: mittlere geglättete Wahrscheinlichkeit je Zustand (Anteil).

`print()` fasst die Zustände zusammen, `plot()` zeichnet die gefilterte Wahrscheinlichkeit des unruhigsten
Zustands.

# Details
Eingabe ist ein Tabelle (RFrame) mit Kursniveaus; geschätzt wird auf den Log-Renditen von Periodenende zu
Periodenende. Die Zustände werden danach mit `regime_states()` auf einen Tageskalender gelegt, z. B. als
Signal oder als Bedingung für `regime_subset()` und `dependence_analysis()`.

# Quellen und Abweichungen
Angelehnt an Hamilton (1989): gefilterte Wahrscheinlichkeiten wie im Hamilton-Filter; abweichend: Gauß'sches
HMM ohne autoregressiven Teil (eigener Mittelwert und eigene Kovarianzmatrix je Zustand), geschätzt mit dem
EM-Verfahren nach Baum u. a. (1970) statt durch numerische Maximierung der Likelihood.
Vorwärts-Rückwärts-Rekursion mit Skalierung, Neuschätzung der Startverteilung und Viterbi-Pfad nach Rabiner
(1989) bzw. Viterbi (1967); BIC nach Schwarz (1978) mit k - 1 + k(k - 1) + kd + kd(d + 1)/2 Parametern. Eigene
Festlegungen von SimLev: Ridge-Zuschlag auf die Kovarianzmatrizen, Startwerte aus einer Rangeinteilung der
rollierenden Volatilität und zufälligen Zuordnungen, Sortierung der Zustände nach Volatilität. Anwendung auf
Regime-Allokation wie bei Nystrup u. a. (2015); abweichend werden die Parameter einmal auf der ganzen Historie
geschätzt (dort adaptiv), die gefilterten Wahrscheinlichkeiten sind also nur bei gegebenen Parametern frei von
Zukunftsinformation.

# Literatur
Hamilton, J. D. (1989), A new approach to the economic analysis of nonstationary time series and the business
cycle, Econometrica 57(2), 357-384, doi:10.2307/1912559; Baum, L. E., Petrie, T., Soules, G. & Weiss, N.
(1970), Annals of Mathematical Statistics 41(1), 164-171, doi:10.1214/aoms/1177697196; Rabiner, L. R. (1989),
A tutorial on hidden Markov models and selected applications in speech recognition, Proceedings of the IEEE
77(2), 257-286, doi:10.1109/5.18626; Viterbi, A. J. (1967), IEEE Transactions on Information Theory 13(2),
260-269, doi:10.1109/TIT.1967.1054010; Schwarz, G. (1978), Estimating the dimension of a model, Annals of
Statistics 6(2), 461-464, doi:10.1214/aos/1176344136; Nystrup, P., Hansen, B. W., Madsen, H. & Lindström, E.
(2015), Regime-based versus static asset allocation: Letting the data speak, Journal of Portfolio Management
42(1), 103-109, doi:10.3905/jpm.2015.42.1.103.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 2920
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
vol = repeat([fill(0.006, 500); fill(0.02, 200)], 5)[1:n]   # ruhig / turbulent
d["aktien"] = 100 .* exp.(cumsum(2e-4 .+ vol .* randn(rng, n)))
hmm = regime_hmm(d, "aktien"; k = 2)
println(hmm["volatility"])
```
"""
function regime_hmm(data, columns; k = 2, frequency = ("week", "day", "month"), n_start = 5, max_iter = 300,
                    tol = 1e-7, seed = 1)
    D = _D()
    frequency = D._match_arg(frequency, ("week", "day", "month"))
    fn = "regime_hmm"                                          # seit 1.6.4 vor der Rechnung (K42 E4)
    (!D._e4_isfactor(k) && _isint_scalar(k)) || error("regime_hmm: k muss eine ganze Zahl >= 2 sein; ein Zustand wäre " *
                              "eine einzige Normalverteilung ohne Regime.")   # seit 1.6.4 ohne Wert
    SimLev.chk_max(SimLev.chk_scalar(k), SimLev.SL_MAX_N, fn, "k")   # B-054
    columns = D._e4_names(columns, fn, "columns")
    D._e4_data(data, columns, fn)                              # B-015
    data = SimLev.as_rframe(data)
    n_start = D._e4_count(n_start, fn, "n_start")              # B-032
    max_iter = D._e4_count(max_iter, fn, "max_iter"; lo = 0)
    tol = SimLev.chk_num1(tol, fn, "tol"; lo = 0)
    k = Int(Float64(k isa AbstractVector ? k[1] : k))
    rd = D._dep_returns(data, columns, nothing, frequency)
    X = reduce(hcat, [_fvec(rd[c]) for c in columns])
    Tn, d = size(X)
    Tn < 50 * k && chk_stop("c.m_regime_hmm_4", Tn, 50 * k)
    flat = [columns[j] for j in 1:d if SimLev.r_sd(X[:, j]) == 0]
    isempty(flat) || error("regime_hmm: Spalte(n) $(join(["'$f'" for f in flat], ", ")) ohne Schwankung (alle Periodenrenditen " *
                           "gleich, z. B. konstante Kurse); kein Modell schätzbar.")
    dd = D._days(rd["date"])
    ppy = (Tn - 1) / ((dd[Tn] - dd[1]) / 365.25)
    rv = 1e-10 + 1e-6 * SimLev.r_mean([SimLev.r_var(X[:, j]) for j in 1:d])
    ridge = zeros(d, d)
    for i in 1:d
        ridge[i, i] = rv
    end
    lg = SimLev.RLibm.log
    win = max(4.0, D._r_round(ppy / 12))
    rs = n_start >= 2 ? SimLev.SLib.main_stream(seed, "regime_hmm") : nothing   # Hauptstrom, nur bei Zufallsstarts
    inits = Any[]
    for s in 1:Int(n_start)
        if s == 1
            push!(inits, _hmm_init_rank(X, k, win, ridge))
        else
            cl = Vector{Int}(SimLev.SLib.sample(k, Tn; replace = true, stream = rs))
            push!(inits, _hmm_init_cl(X, cl, k, ridge))
        end
    end
    fits = Any[]
    n_failed = 0
    for i in inits
        f = try
            _hmm_em(X, k, i, max_iter, tol, ridge)
        catch e
            e isa InterruptException && rethrow()
            nothing
        end
        f === nothing ? (n_failed += 1) : push!(fits, f)   # seit 1.6.5 (K34, CR2-E-11)
    end
    isempty(fits) && chk_stop("c.m_regime_hmm_3")
    f = fits[_which_max([fi.ll for fi in fits])]
    converged = f.iter < Int(max_iter)
    converged || @warn SimLev.chk_msg("c.hmm_grenze", fn, Int(max_iter))
    vol = [sqrt(SimLev.r_mean([s[i, i] for i in 1:d])) for s in f.S]
    o = D._order(vol)
    A = f.A[o, o]; mu = f.mu[o, :]; S = f.S[o]
    lB = f.lB[:, o]
    path = _hmm_viterbi(lB, lg.(A), lg.(f.p0[o]))
    npar = k - 1 + k * (k - 1) + k * d + k * d * (d + 1) / 2
    zn = ["Z$j" for j in 1:k]
    vols = Matrix{Float64}(undef, k, d)
    for j in 1:k, c in 1:d
        vols[j, c] = sqrt(S[j][c, c] * ppy) * 100
    end
    out = RList(; class = ["SimLevHMM"])
    out["transition"] = NamedMat(A; rownames = zn, colnames = zn)
    out["means"] = NamedMat(mu .* ppy .* 100; rownames = zn, colnames = columns)
    out["volatility"] = NamedMat(vols; rownames = zn, colnames = columns)
    out["correlation"] = Any[NamedMat(_cov2cor(s); rownames = columns, colnames = columns) for s in S]
    out["filtered"] = f.filtered[:, o]
    out["smoothed"] = f.smoothed[:, o]
    out["viterbi"] = path
    out["dates"] = collect(rd["date"])
    out["columns"] = columns
    out["k"] = k
    out["loglik"] = f.ll
    out["bic"] = -2 * f.ll + npar * lg(Float64(Tn))
    out["initial"] = RVector(f.p0[o]; names = zn)
    out["duration"] = RVector([1 / (1 - A[i, i]) for i in 1:k]; names = zn)
    out["frequency"] = frequency
    out["ppy"] = ppy
    out["share"] = D._colmeans(f.smoothed[:, o])
    out["iterations"] = Int(f.iter)            # seit 1.6.5 (K34)
    out["converged"] = converged
    out["n_failed"] = n_failed
    out
end

function _print_hmm(io::IO, x)
    D = _D()
    k = Int(x["k"])
    print(io, D._sprintf("Hidden-Markov-Modell: %d Zustände auf %s (%s), %d Perioden, logL %.1f, BIC %.1f", k,
                         join(x["columns"], ", "), x["frequency"], length(x["dates"]), x["loglik"], x["bic"]) * "\n\n")
    mu = _fmat(x["means"]); vo = _fmat(x["volatility"]); share = _fvec(x["share"]); dur = _fvec(x["duration"])
    for j in 1:k
        print(io, D._sprintf("  Z%d: Anteil %.0f %%, erwartete Dauer %.1f Perioden, Rendite %s %% p. a., Vola %s %%", j,
                             100 * share[j], dur[j], join(D._sprintf_vec("%.1f", mu[j, :]), "/"),
                             join(D._sprintf_vec("%.1f", vo[j, :]), "/")) * "\n")
    end
    if haskey(x, "iterations")                 # seit 1.6.5 (K34): Schritte der Schätzung
        nf = Int(x["n_failed"])
        print(io, D._sprintf("  Schritte: %d%s%s", Int(x["iterations"]), x["converged"] === true ? "" : " (Grenze erreicht)",
                             nf > 0 ? D._sprintf(", %d Startwert(e) verworfen", nf) : "") * "\n")
    end
    print(io, "\nÜbergangsmatrix\n")
    T = x["transition"]
    D._ln(io, D._print_matrix(D._r_round(_fmat(T), 3), T.rownames, T.colnames))
    F = _fmat(x["filtered"])
    last = F[size(F, 1), :]
    print(io, D._sprintf("\nAktueller Zustand (gefiltert): Z%d mit %.0f %%", _which_max(last), 100 * D._rmax(last)) * "\n")
    nothing
end

function _plot_hmm(x; data = nothing, width = 900, height = 380)   # data: wie R angenommen, ungenutzt
    D = _D()
    k = Int(x["k"])
    top = _fmat(x["filtered"])[:, k]
    data = SimLev.RList("filtered" => SimLev.RFrame("date" => collect(Date, x["dates"]), "probability" => top))
    svg = _grid_svg(["p"], _ -> ((c, box) -> _grid_lines!(c, box, [(D._days(x["dates"]), top, "#B5562B", "P(Z$k | bis t)")];
                                                       ylim = (0.0, 1.0), hline = [(0.5, "grey")], dates = true,
                                                       ylabel = "P(Z$k | bis t)",
                                                       title = "Gefilterte Wahrscheinlichkeit des unruhigsten Zustands (Z$k)"));
                width = width, height = height)
    return (svg, data)
end

"""
    regime_states(x, dates; type = "filtered", output = "state", state_prob = x["k"], lag = 1)

Regime auf einen Tageskalender legen.

Ordnet jedem Tag den Zustand bzw. die Wahrscheinlichkeit zu, die zum Ende der letzten abgeschlossenen Periode
(plus `lag` Tage) bekannt war. Mit `type = "filtered"` (Standard) enthält das Ergebnis keine
Zukunftsinformation und kann als Signal oder Bedingung dienen.

# Argumente
- `x`: Objekt der Klasse `SimLevHMM` aus `regime_hmm()`.
- `dates`: Zieldaten: Date-Vektor (oder umwandelbar) oder Tabelle (RFrame) mit Spalte `date`, z. B. derselbe
  Datensatz wie in `regime_hmm()`.
- `type`: `"filtered"` (Standard), `"smoothed"` oder `"viterbi"` (die beiden letzten nutzen die ganze Historie
  - nur zur Beschreibung; es erscheint eine Warnung).
- `output`: `"state"` (Standard: Nummer 1 bis k des wahrscheinlichsten Zustands bzw. Viterbi-Zustand) oder
  `"probability"` (Wahrscheinlichkeit von `state_prob` als Anteil; nicht mit `type = "viterbi"`).
- `state_prob`: Zustandsnummer (1 bis k) für `output = "probability"`; Standard `x["k"]`, der unruhigste
  Zustand.
  Seit 1.6.4 eine ganze Zahl von 1 bis k.
- `lag`: Verzögerung in Kalendertagen (Standard 1): Der Wert einer Periode gilt ab Periodenende + `lag` Tage;
  0 = schon am Periodenende.
  Seit 1.6.4 eine ganze Zahl ≥ 0.

# Rückgabe
Vektor mit einem Wert je Datum in `dates`: ganze Zahlen (Zustand) bzw. Wahrscheinlichkeiten als Anteil; `NA`
vor dem ersten Periodenende + `lag`.

# Beispiel
```julia
using SimLev, Dates, Random
rng = MersenneTwister(1)
n = 2920
d = RFrame("date" => Date(2010, 1, 1) .+ Day.(0:n-1))
vol = repeat([fill(0.006, 500); fill(0.02, 200)], 5)[1:n]
d["aktien"] = 100 .* exp.(cumsum(2e-4 .+ vol .* randn(rng, n)))
hmm = regime_hmm(d, "aktien"; k = 2)
s = regime_states(hmm, d)
println(count(isequal(2), s))
```
"""
function regime_states(x, dates; type = ("filtered", "smoothed", "viterbi"), output = ("state", "probability"),
                       state_prob = nothing, lag = 1)
    D = _D()
    type = D._match_arg(type, ("filtered", "smoothed", "viterbi"))
    output = D._match_arg(output, ("state", "probability"))
    fn = "regime_states"                                       # seit 1.6.4 vor der Rechnung (K42 E4)
    SimLev.inherits(x, "SimLevHMM") || SimLev.chk_stop("klasse", fn, "x", "regime_hmm()")
    state_prob === nothing && (state_prob = x["k"])
    dates isa RFrame && SimLev.chk_cols(dates, ["date"], fn)  # B-054
    _e4_dates(dates isa RFrame ? dates["date"] : dates, fn)
    state_prob = SimLev.chk_int1(state_prob, fn, "state_prob"; lo = 1, hi = x["k"])   # B-007
    lag = SimLev.chk_int1(lag, fn, "lag"; lo = 0)              # B-012
    type != "filtered" && @warn chk_msg("c.m_regime_states")
    src = D._is_frame(dates) ? D._as_frame(dates)["date"] : dates
    d = D._to_date(src isa AbstractVector ? src : [src], "regime_states: dates")
    P = type == "filtered" ? x["filtered"] : type == "smoothed" ? x["smoothed"] : nothing
    prob = output == "probability"
    if prob
        P === nothing && chk_stop("c.m_regime_states_2")
        v = _fmat(P)[:, Int(state_prob)]
    elseif P === nothing
        v = Vector{Union{Missing,Int}}(collect(x["viterbi"]))
    else
        v = _max_col_first(P)
    end
    dv = D._days(collect(d))
    ref = D._days(x["dates"]) .+ lag
    out = prob ? fill(_NA, length(dv)) : Vector{Union{Missing,Int}}(missing, length(dv))
    for i in eachindex(dv)
        isnan(dv[i]) && continue
        kk = searchsortedlast(ref, dv[i])
        kk > 0 && (out[i] = v[kk])
    end
    out
end

function __init__()
    SimLev.register_print!("SimLevHMM", _print_hmm)
    SimLev.register_plot!("SimLevHMM", SimLev._plot_method(_plot_hmm, "SimLevHMM"))
end

end # module
