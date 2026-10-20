# ─────────────────────────────────────────────────────────────────────────────
# Einkommensteuertarif und Solidaritätszuschlag als Datei (Port von tax_tariff.R)
#
#   read_tax_tariff(file = nothing)  → RList der Klasse "SimLevTaxTariff"
#                                      (zones::RFrame, soli::RList, geltung, file)
#   _tariff_income_tax(tariff, zve)   tarifliche ESt (§ 32a Abs. 1 EStG), volle Euro
#   _tariff_soli(tariff, est)         Soli (§§ 3, 4 SolZG)
# ─────────────────────────────────────────────────────────────────────────────

"Pfad der mitgelieferten Tarifdatei (R: `system.file(\"extdata\", \"steuertarif.csv\")`)."
default_tariff_file() = normpath(joinpath(@__DIR__, "..", "data", "steuertarif.csv"))

function _split_csv_line(line::AbstractString)
    out = String[]; cur = IOBuffer(); q = false
    cs = collect(line)
    i = 1
    while i <= length(cs)
        ch = cs[i]
        if q
            if ch == '"'
                if i < length(cs) && cs[i+1] == '"'
                    write(cur, '"'); i += 1
                else
                    q = false
                end
            else
                write(cur, ch)
            end
        elseif ch == '"'
            q = true
        elseif ch == ','
            push!(out, String(take!(cur)))
        else
            write(cur, ch)
        end
        i += 1
    end
    push!(out, String(take!(cur)))
    return [String(strip(x)) for x in out]
end

"""
    read_tax_tariff(file = nothing)

Einkommensteuertarif (§ 32a Abs. 1 EStG) und Soli (§§ 3, 4 SolZG) aus einer
CSV-Datei lesen (Standard: mitgelieferte Datei, Rechtslage ab VZ 2026). Format
und Prüfungen wie `read_tax_tariff()` im R-Paket. Ergebnis: `RList` der Klasse
`SimLevTaxTariff` mit `zones` (RFrame ab, bezug, teiler, a, b, c), `soli`
(freigrenze, satz, milderung; Sätze in Prozent), `geltung` und `file`.
"""
function read_tax_tariff(file_pos = nothing; file = file_pos)
    if file === nothing
        file = default_tariff_file()
        isfile(file) || error("read_tax_tariff: Die mitgelieferte Datei extdata/steuertarif.csv wurde nicht gefunden (Paket unvollständig installiert?).")
    end
    (file isa AbstractString) || error("read_tax_tariff: 'file' muss ein einzelner Dateipfad (Zeichenkette) oder NULL sein.")
    file = String(file)
    isfile(file) || error("read_tax_tariff: Datei '$file' nicht gefunden.")
    raw = readlines(file)
    gl = [ln for ln in raw if occursin(r"^#\s*Geltung\s*:", ln)]
    geltung = isempty(gl) ? missing : String(strip(replace(gl[1], r"^#\s*Geltung\s*:" => "")))
    body = [String(strip(replace(ln, r"#.*$" => ""))) for ln in raw]
    body = [ln for ln in body if !isempty(ln)]
    if !isempty(body)
        nf = [count(==(','), ln) + 1 for ln in body]
        if nf[1] == 1
            error("read_tax_tariff: In '$file' wurde nur eine Spalte gelesen (Kopfzeile '$(body[1])'). Erwartet wird Komma als Trennzeichen" *
                  (occursin(';', body[1]) ? " (die Datei verwendet offenbar Semikolon, z. B. aus deutschem Excel)" : "") *
                  " und Punkt als Dezimalzeichen, z. B. 'zone,69879,0,1,0,0.42,-11135.63'.")
        end
        for i in 2:length(nf)
            nf[i] != nf[1] && error("read_tax_tariff: In '$file' hat die Zeile '$(body[i])' $(nf[i]) Felder, die Kopfzeile $(nf[1]). Dezimalzeichen ist der Punkt (0.42, nicht 0,42); Komma nur als Trennzeichen.")
        end
    end
    isempty(body) && error("read_tax_tariff: Datei '$file' ist keine lesbare CSV-Datei (no lines available in input).")
    header = _split_csv_line(body[1])
    rws = [_split_csv_line(ln) for ln in body[2:end]]
    d = Dict{String,Vector{String}}(h => String[j <= length(r) ? r[j] : "" for r in rws] for (j, h) in enumerate(header))
    need = ["art", "ab", "bezug", "teiler", "a", "b", "c"]
    miss = [c for c in need if !haskey(d, c)]
    isempty(miss) || error("read_tax_tariff: In '$file' fehlen die Spalten $(join(miss, ", ")) (erwartet: $(join(need, ","))).")
    art = lowercase.(d["art"])
    bad = findfirst(a -> !(a in ("zone", "soli")), art)
    bad === nothing || error("read_tax_tariff: Datenzeile $bad hat art = '$(d["art"][bad])'; erlaubt sind \"zone\" und \"soli\".")
    function num(col, rows)
        v = Float64[r_as_numeric(d[col][i]) for i in rows]
        nb = findfirst(x -> !isfinite(x), v)
        if nb !== nothing
            i = rows[nb]
            error("read_tax_tariff: Spalte '$col' in Datenzeile $i (art = $(art[i])) ist nicht numerisch bzw. nicht endlich ('$(d[col][i])').")
        end
        v
    end
    zr = findall(==("zone"), art); sr = findall(==("soli"), art)
    isempty(zr) && error("read_tax_tariff: Die Datei enthält keine Tarifzone (art = \"zone\").")
    length(sr) == 1 || error("read_tax_tariff: Es muss genau eine soli-Zeile geben (gefunden: $(length(sr))).")
    zd = Dict(c => num(c, zr) for c in ("ab", "bezug", "teiler", "a", "b", "c"))
    ab = zd["ab"]
    ab[1] != 0 && error("read_tax_tariff: Die erste Zone muss bei ab = 0 beginnen (ist $(r_format1(ab[1]))).")
    for k in 1:length(ab)-1
        ab[k+1] - ab[k] <= 0 && error("read_tax_tariff: Die Zonen müssen streng aufsteigend sein (Zone $(k + 1) ab $(r_format1(ab[k+1])) folgt auf ab $(r_format1(ab[k]))).")
    end
    k0 = findfirst(<=(0), zd["teiler"])
    k0 === nothing || error("read_tax_tariff: teiler muss > 0 sein (Zone ab $(r_format1(ab[k0]))).")
    soli = RList("freigrenze" => num("ab", sr)[1], "satz" => num("a", sr)[1], "milderung" => num("b", sr)[1])
    soli["freigrenze"] < 0 && error("read_tax_tariff: Die Soli-Freigrenze (ab) darf nicht negativ sein.")
    for s in ("satz", "milderung")
        (soli[s] < 0 || soli[s] > 100) &&
            error("read_tax_tariff: Soli-$(s == "satz" ? "Zuschlagsatz (a)" : "Milderungssatz (b)") muss zwischen 0 und 100 Prozent liegen (ist $(r_format1(soli[s]))).")
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
                error("read_tax_tariff: Zone ab $(r_format1(ab[k]; scientific = false)) EUR (Datenzeile $(zr[k])): Grenzsteuersatz $(r_format1(r_signif(m, 6))) bei x = $(r_format1(x; scientific = false)) EUR liegt nicht zwischen 0 und 1 (0 bis 100 %). $unit_hint.")
            end
            if f(k, x) > x + 1e-9
                error(r_sprintf("read_tax_tariff: Zone ab %s EUR (Datenzeile %d): Steuer %.2f EUR bei x = %s EUR übersteigt das Einkommen. %s.",
                                r_format1(ab[k]; scientific = false), zr[k], f(k, x), r_format1(x; scientific = false), unit_hint))
            end
        end
    end
    for k in 2:nz
        jump = f(k, ab[k]) - f(k - 1, ab[k])
        abs(jump) > 1 && @warn r_sprintf("read_tax_tariff: Der Tarif springt an der Zonengrenze %s EUR um %.2f EUR (vorige Zone %.2f, neue Zone %.2f EUR); Tarifdatei prüfen.",
                                         r_format1(ab[k]; scientific = false), jump, f(k - 1, ab[k]), f(k, ab[k]))
    end
    return out
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

"Tarifliche Einkommensteuer T(x) in vollen EUR (R: `.tariff_income_tax`)."
function _tariff_income_tax(tariff, zve::Float64)
    z = tariff["zones"]
    ab = z["ab"]
    x = r_max2(0.0, floor(zve + 1e-9))
    k = findlast(<=(x), ab)
    u = (x - z["bezug"][k]) / z["teiler"][k]
    return r_max2(0.0, floor(r_round((z["a"][k] * u + z["b"][k]) * u + z["c"][k], 6)))
end

"Solidaritätszuschlag S(E) auf die ESt (R: `.tariff_soli`)."
function _tariff_soli(tariff, est::Float64)
    s = tariff["soli"]
    est > s["freigrenze"] || return 0.0
    v = r_min2(s["satz"] / 100 * est, s["milderung"] / 100 * (est - s["freigrenze"]))
    return floor(r_round(v * 100, 6)) / 100
end
register_print!("SimLevTaxTariff", _print_tax_tariff)
