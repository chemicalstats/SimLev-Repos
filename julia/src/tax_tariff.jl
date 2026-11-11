# ─────────────────────────────────────────────────────────────────────────────
# Einkommensteuertarif und Solidaritätszuschlag als Datei (Gegenstück zu tax_tariff.R)
#
#   tax_tariff(file = nothing)  → RList der Klasse "SimLevTaxTariff"
#                                      (zones::RFrame, soli::RList, geltung, file)
#   tarifliche ESt und Soli rechnet der Tarifkern core/tariff_core_impl.h (_tariff_income_tax und
#   _tariff_soli sind als ungenutzt entfallen)
# ─────────────────────────────────────────────────────────────────────────────

"Pfad der mitgelieferten Tarifdatei (R: `system.file(\"extdata\", \"steuertarif.csv\")`)."
default_tariff_file() = normpath(joinpath(@__DIR__, "..", "data", "steuertarif.csv"))

# Felder einer CSV-Zeile wie read.csv(strip.white = TRUE): nur Leerzeichen und Tabulatoren ausserhalb der
# Anfuehrungszeichen werden abgeschnitten; seit 1.6.5 (CR2-X16-1) bleibt der Inhalt eines Felds in
# Anfuehrungszeichen unveraendert (bis 1.6.4 auch gekuerzt)
function _split_csv_line(line::AbstractString)
    out = String[]; cur = Char[]; q = false
    quoted = false; qend = 0
    ws = (' ', '\t')
    field() = quoted ? String(cur[1:qend]) * String(rstrip(String(cur[qend+1:end]), ws)) : String(strip(String(cur), ws))
    cs = collect(line)
    i = 1
    while i <= length(cs)
        ch = cs[i]
        if q
            if ch == '"'
                if i < length(cs) && cs[i+1] == '"'
                    push!(cur, '"'); i += 1
                else
                    q = false
                    qend = length(cur)
                end
            else
                push!(cur, ch)
            end
        elseif ch == '"'
            (!quoted && isempty(strip(String(cur), ws))) && empty!(cur)   # Leerraum vor dem oeffnenden Anfuehrungszeichen
            q = true
            quoted = true
        elseif ch == ','
            push!(out, field())
            cur = Char[]; quoted = false; qend = 0
        else
            push!(cur, ch)
        end
        i += 1
    end
    push!(out, field())
    return out
end

"""
    tax_tariff(file = nothing)

Einkommensteuertarif (§ 32a Abs. 1 EStG) und Soli (§§ 3, 4 SolZG) aus einer CSV-Datei lesen.

Liest den Einkommensteuertarif (§ 32a Abs. 1 EStG) und den Solidaritätszuschlag (§§ 3, 4 SolZG) aus einer
CSV-Datei, prüft sie und liefert ein Objekt für `simulation(tax = tax_profile(income =
income_tariff(taxable_income, tariff)))`. Mitgeliefert wird die Rechtslage ab VZ 2026 (Einzelveranlagung,
Grundtarif; kein Splitting). Für eine künftige Rechtslage genügt es, die Datei auszutauschen bzw. eine eigene
Datei anzugeben; der Code bleibt unverändert.

# Argumente
- `file`: Zeichenkette oder nothing. Pfad der Tarifdatei; nothing = mitgelieferte Datei
  `system.file("extdata", "steuertarif.csv", package = "SimLev")`.
  Zahlen der Datei seit 1.6.4 nur mit ASCII-Ziffern und -Leerzeichen, unabhängig von der Spracheinstellung (z. B. ein
  geschütztes Leerzeichen ist ein Fehler); ein UTF-8-BOM am Anfang wird übergangen.

# Rückgabe
Objekt der Klasse "SimLevTaxTariff" (Liste) mit `zones` (Tabelle (RFrame) ab, bezug, teiler, a, b, c), `soli`
(Liste freigrenze, satz, milderung; Sätze in Prozent), `geltung` (Text aus der Datei) und `file` (Pfad).
print() zeigt Geltung, Zonen und Soli.

# Details
Dateiformat (Basis-R lesbar mit `read.csv(file, comment.char = "#")`; Komma als Trennzeichen, Punkt als
Dezimalzeichen; Zeilen mit `#` sind Kommentare, eine Kommentarzeile `# Geltung: ...` wird als Geltung
angezeigt). Spalten `art, ab, bezug, teiler, a, b, c`:

- art = "zone": Tarifzone: gilt für x ≥ `ab` (x = zu versteuerndes Einkommen, auf volle Euro abgerundet);
  Steuer (a u + b) u + c mit u = (x - bezug) / teiler, danach auf volle Euro abgerundet. Lineare Zonen: `a =
  0, bezug = 0, teiler = 1`, `b` = Satz als Anteil, `c` = Abzugsbetrag.
- art = "soli": genau eine Zeile: `ab` = Freigrenze in EUR Einkommensteuer, `a` = Zuschlagsatz in Prozent, `b`
  = Milderungssatz in Prozent.

Einheiten: `ab`, `bezug`, `teiler` und `c` in EUR; bei Progressionszonen (`teiler = 10000`, u dimensionslos)
auch `a`, `b` in EUR; bei linearen Zonen (`a = 0, bezug = 0, teiler = 1`) ist `b` der Grenzsteuersatz als
Anteil (`0.42` für 42 %, nicht 42); die Soli-Sätze dagegen in Prozent (`5.5` für 5,5 %).

Geprüft wird (seit 1.6.4 auch: kein Ordner, Kodierung UTF-8, ein UTF-8-BOM am Anfang wird übergangen,
geschlossene Anführungszeichen, keine Pflichtspalte doppelt, Zahlen nur mit ASCII-Ziffern): Komma als Trennzeichen (wird nur eine Spalte gelesen, z. B. Semikolon-CSV, bzw. hat eine Zeile
mehr Felder als die Kopfzeile, z. B. Dezimalkomma: Fehler mit Hinweis), Pflichtspalten vorhanden, `art` nur
"zone" oder "soli", alle benötigten Werte numerisch und endlich, `teiler > 0`, Zonen streng aufsteigend mit
erster Zone ab 0, genau eine soli-Zeile mit Sätzen von 0 bis 100. Plausibilität: Der Grenzsteuersatz jeder
Zone (Ableitung (2 a u + b) / teiler) muss an beiden Rändern (Zonenbeginn und letzter Euro der Zone; letzte
Zone: bei 10 Mio. EUR) zwischen 0 und 1 liegen, und die Steuer darf an diesen Stellen das Einkommen nicht
übersteigen (T(x) ≤ x); sonst Fehler mit Zeile, Wert und Hinweis auf die Einheiten. Springt der Tarif an einer
Zonengrenze um mehr als 1 EUR (Formel der vorigen und der neuen Zone an der Grenze), wird gewarnt.

Rechenregeln (intern): tarifliche ESt T(x): x auf volle Euro abrunden (negativ: 0), Formel der Zone mit dem
größten `ab <= x`, Ergebnis auf volle Euro abrunden. Soli S(E) auf die ESt E: 0, wenn E die Freigrenze nicht
übersteigt, sonst min(a / 100 · E, b / 100 · (E - Freigrenze)) (Milderungszone), Bruchteile eines Cents
bleiben außer Ansatz.

Mitgelieferter Tarif (ab VZ 2026): bis 12 348 EUR 0; 12 349 bis 17 799: (914,51 y + 1 400) y; 17 800 bis 69
878: (173,10 z + 2 397) z + 1 034,87; 69 879 bis 277 825: 0,42 x - 11 135,63; ab 277 826: 0,45 x - 19 470,38
mit y = (x - 12 348) / 10 000, z = (x - 17 799) / 10 000. Soli 5,5 % über der Freigrenze 20 350 EUR, höchstens
11,9 % des Mehrbetrags.

# Beispiel
```julia
using SimLev
println(tax_tariff())
```
"""
function tax_tariff(file_pos = nothing; file = file_pos)
    if file === nothing
        file = default_tariff_file()
        isfile(file) || chk_stop("a.m_tax_tariff")
        # seit 1.6.3 je Prozess gemerkt (wie R und Python): Schlüssel Pfad, Größe, Änderungszeit; nur ohne Warnung;
        # je Aufruf eine Kopie
        stt = stat(file); key = (file, stt.size, stt.mtime)
        hit = lock(_TT_LOCK) do
            c = _TT_CACHE[]
            c !== nothing && c[1] == key ? c[2] : nothing
        end
        hit === nothing || return deepcopy(hit)
        out, warned = _tax_tariff_read(file)
        warned || lock(() -> (_TT_CACHE[] = (key, deepcopy(out))), _TT_LOCK)
        return out
    end
    return _tax_tariff_read(file)[1]
end

const _TT_CACHE = Ref{Any}(nothing)   # (Schlüssel, Ergebnis) der mitgelieferten Datei
const _TT_LOCK = ReentrantLock()

"Tarifdatei lesen und prüfen (Rumpf von `tax_tariff`); `(Ergebnis, Warnung ausgegeben?)`."
function _tax_tariff_read(file)
    warned = false
    (file isa AbstractString) || chk_stop("a.m_tax_tariff_read")
    file = String(file)
    # seit 1.6.4 (A-071, A-037): Ordner, Kodierung und Anführungszeichen vorab mit Meldung; ein UTF-8-BOM am
    # Dateianfang (Excel "CSV UTF-8") wird übergangen
    isdir(file) && chk_stop("e1.tarif_ordner", "tax_tariff", file)
    isfile(file) || chk_stop("a.m_tax_tariff_read_2", file)
    txt = read(file, String)
    occursin('\0', txt) && chk_stop("a.tarif_nul", "tax_tariff", file)   # seit 1.6.5 (CR2-B-8), vor der Kodierung
    isvalid(txt) || chk_stop("e1.tarif_utf8", "tax_tariff", file)
    startswith(txt, "\ufeff") && (txt = txt[nextind(txt, 1):end])
    # seit 1.6.5 (CR2-B-8): Zeilenende LF, CRLF oder nur CR wie R's readLines (bis 1.6.4 nur LF/CRLF)
    raw = String.(split(txt, r"\r\n|\r|\n"))
    !isempty(raw) && isempty(raw[end]) && pop!(raw)
    gl = [ln for ln in raw if occursin(r"^#\s*Geltung\s*:", ln)]
    # seit 1.6.4 (K43 T1-N6) wie R's trimws nur [ \t\r\n] abschneiden (bis dahin auch Unicode-Leerraum,
    # Entscheidung 27)
    ws = (' ', '\t', '\r', '\n')
    geltung = isempty(gl) ? missing : String(strip(replace(gl[1], r"^#\s*Geltung\s*:" => ""), ws))
    body = [String(strip(replace(ln, r"#.*$" => ""), ws)) for ln in raw]
    body = [ln for ln in body if !isempty(ln)]
    if !isempty(body)
        any(ln -> isodd(count(==('"'), ln)), body) && chk_stop("e1.tarif_quote", "tax_tariff", file)
        nf = [count(==(','), ln) + 1 for ln in body]
        # seit 1.6.4 ohne die Zeileninhalte (Entscheidung 8); die Datenzeile bleibt als Ort
        if nf[1] == 1
            error("tax_tariff: In '$file' wurde nur eine Spalte gelesen. Erwartet wird Komma als Trennzeichen" *
                  (occursin(';', body[1]) ? " (die Datei verwendet offenbar Semikolon, z. B. aus deutschem Excel)" : "") *
                  " und Punkt als Dezimalzeichen, z. B. 'zone,69879,0,1,0,0.42,-11135.63'.")
        end
        for i in 2:length(nf)
            nf[i] != nf[1] && chk_stop("a.m_tax_tariff_read_6", file, i - 1, nf[i], nf[1])
        end
    end
    isempty(body) && chk_stop("a.m_tax_tariff_read_5", file)
    header = _split_csv_line(body[1])
    rws = [_split_csv_line(ln) for ln in body[2:end]]
    d = Dict{String,Vector{String}}(h => String[j <= length(r) ? r[j] : "" for r in rws] for (j, h) in enumerate(header))
    need = ["art", "ab", "bezug", "teiler", "a", "b", "c"]
    dup = [c for c in need if count(==(c), header) > 1]   # seit 1.6.4 (A-039): Pflichtspalte doppelt
    isempty(dup) || chk_stop("e1.tarif_doppelt", "tax_tariff", file, dup[1])
    miss = [c for c in need if !haskey(d, c)]
    isempty(miss) || error("tax_tariff: In '$file' fehlen die Spalten $(join(miss, ", ")) (erwartet: $(join(need, ","))).")
    art = lowercase.(d["art"])
    bad = findfirst(a -> !(a in ("zone", "soli")), art)
    bad === nothing || chk_stop("a.m_tax_tariff_read_7", bad)
    # seit 1.6.4 Felder mit Nicht-ASCII-Zeichen als NA (A-038, C-022; wie R für fremde Ziffern)
    function num(col, rows)
        v = Float64[chk_as_num(d[col][i]) for i in rows]   # nur ASCII (Entscheidung 27, gemeinsame Hilfe)
        nb = findfirst(x -> !isfinite(x), v)
        if nb !== nothing
            i = rows[nb]
            chk_stop("a.m_num_5", col, i, art[i])
        end
        v
    end
    zr = findall(==("zone"), art); sr = findall(==("soli"), art)
    isempty(zr) && chk_stop("a.m_num")
    length(sr) == 1 || chk_stop("a.m_num_6", length(sr))
    zd = Dict(c => num(c, zr) for c in ("ab", "bezug", "teiler", "a", "b", "c"))
    ab = zd["ab"]
    ab[1] != 0 && chk_stop("a.m_num_2")
    for k in 1:length(ab)-1
        ab[k+1] - ab[k] <= 0 && chk_stop("a.m_num_7", k + 1)
    end
    k0 = findfirst(<=(0), zd["teiler"])
    k0 === nothing || chk_stop("a.m_num_8", k0)
    soli = RList("freigrenze" => num("ab", sr)[1], "satz" => num("a", sr)[1], "milderung" => num("b", sr)[1])
    soli["freigrenze"] < 0 && chk_stop("a.m_num_3")
    for s in ("satz", "milderung")
        (soli[s] < 0 || soli[s] > 100) &&
            error("tax_tariff: Soli-$(s == "satz" ? "Zuschlagsatz (a)" : "Milderungssatz (b)") muss zwischen 0 und 100 Prozent liegen.")
    end
    zones = RFrame("ab" => zd["ab"], "bezug" => zd["bezug"], "teiler" => zd["teiler"], "a" => zd["a"],
                   "b" => zd["b"], "c" => zd["c"])
    out = RList("zones" => zones, "soli" => soli, "geltung" => geltung, "file" => realpath(abspath(file));
                class = ["SimLevTaxTariff"])
    f(j, x) = (u = (x - zd["bezug"][j]) / zd["teiler"][j]; (zd["a"][j] * u + zd["b"][j]) * u + zd["c"][j])
    unit_hint = "Einheiten prüfen: bei linearen Zonen (a = 0, bezug = 0, teiler = 1) ist b der Grenzsteuersatz als Anteil (0.42 für 42 %, nicht 42), die Soli-Sätze dagegen in Prozent (5.5); ab, bezug, c in EUR"
    nz = length(ab)
    for k in 1:nz
        x_hi = k < nz ? ab[k+1] - 1 : r_max2(ab[k], 1e7)
        xs = unique([ab[k], r_max2(ab[k], x_hi)])
        for x in xs
            u = (x - zd["bezug"][k]) / zd["teiler"][k]
            m = (2 * zd["a"][k] * u + zd["b"][k]) / zd["teiler"][k]
            if !isfinite(m) || m < -1e-12 || m > 1 + 1e-12
                error("tax_tariff: Zone ab $(r_format1(ab[k]; scientific = false)) EUR (Datenzeile $(zr[k])): Grenzsteuersatz $(r_format1(r_signif(m, 6))) bei x = $(r_format1(x; scientific = false)) EUR liegt nicht zwischen 0 und 1 (0 bis 100 %). $unit_hint.")
            end
            if f(k, x) > x + 1e-9
                error(r_sprintf("tax_tariff: Zone ab %s EUR (Datenzeile %d): Steuer %.2f EUR bei x = %s EUR übersteigt das Einkommen. %s.",
                                r_format1(ab[k]; scientific = false), zr[k], f(k, x), r_format1(x; scientific = false), unit_hint))
            end
        end
    end
    for k in 2:nz
        jump = f(k, ab[k]) - f(k - 1, ab[k])
        abs(jump) > 1 && (warned = true) && @warn r_sprintf("tax_tariff: Der Tarif springt an der Zonengrenze %s EUR um %.2f EUR (vorige Zone %.2f, neue Zone %.2f EUR); Tarifdatei prüfen.",
                                         r_format1(ab[k]; scientific = false), jump, f(k - 1, ab[k]), f(k, ab[k]))
    end
    return out, warned
end

function _print_tax_tariff(io::IO, x)
    println(io, "Einkommensteuertarif (SimLev)")
    g = x["geltung"]
    println(io, "  Geltung: ", (g === missing || g === nothing) ? "(keine Angabe in der Datei)" : g)
    println(io, "  Datei:   ", x["file"])
    z = x["zones"]
    ab = collect(Float64, z["ab"])
    hi = [ab[2:end] .- 1; Inf]
    println(io, "  Zonen (x = zvE in EUR, auf volle Euro abgerundet; Steuer (a*u + b)*u + c, u = (x - bezug)/teiler):")
    for k in eachindex(ab)
        println(io, r_sprintf("    %10s - %-10s  bezug %9s  teiler %6s  a %8s  b %8s  c %10s",
                              r_format1(ab[k]; big_mark = " "), isfinite(hi[k]) ? r_format1(hi[k]; big_mark = " ") : "",
                              r_format1(z["bezug"][k]), r_format1(z["teiler"][k]), r_format1(z["a"][k]),
                              r_format1(z["b"][k]), r_format1(z["c"][k])))
    end
    s = x["soli"]
    print(io, r_sprintf("  Soli: %s %% der ESt, wenn die ESt %s EUR übersteigt (Freigrenze); höchstens %s %% des Mehrbetrags\n",
                        r_format1(s["satz"]), r_format1(s["freigrenze"]; big_mark = " ", scientific = false),
                        r_format1(s["milderung"])))
end

register_print!("SimLevTaxTariff", _print_tax_tariff)
