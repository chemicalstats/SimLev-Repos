# Übersetzungsanweisungen für den Paket-Cache (J15b), eingebunden von precompile.jl nach der Arbeitslast.
#
# Die Arbeitslast führt die Hauptfunktionen aus; Methoden, die sie nur über Laufzeit-Dispatch erreicht
# (Aufrufer mit @nospecialize, Any-typisierte Felder in RList/RFrame) und deren Signatur nur Typen aus Base,
# Core, Dates oder Printf enthält, übernimmt Julia aber nicht in den Cache (geprüft mit Julia 1.13); ebenso
# fehlen Varianten, die die Arbeitslast mit anderen Argumenttypen trifft. Diese Liste nennt sie ausdrücklich.
# Herkunft: `julia --trace-compile=stderr --trace-compile-timing` beim ersten Aufruf der Hauptfunktionen in
# einem frischen Prozess (Bench-Aufgaben bench.jl und je Modul eine weitere Hauptfunktion), nach
# der Arbeitslast; übernommen nur allgemeine Signaturen: ohne die NamedTuple der Daten des Aufrufers, ohne
# Main, ohne Closures und Schlüsselwort-Rümpfe (`var"#…"`, Namen ändern sich mit dem Code) und ohne den
# Messrahmen (Umleitung der Ausgabe, Logger). Sortiert nach Übersetzungszeit im Trace (absteigend).
# Veraltete Einträge schaden nicht: Jede Anweisung steht in `try`, ein Fehlschlag wird übergangen.

"Übersetzungsanweisungen ausführen (nur beim Vorkompilieren; gibt die Zahl der fehlgeschlagenen zurück)."
function _precompile_statements()
    nfail = 0
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(/)), Tuple{Array{Float64, 2}, Array{Float64, 2}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(|)), Tuple{Base.BitArray{1}, Base.BitArray{1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize!), Base.BitArray{1}, Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(&)), Tuple{Base.BitArray{1}, Base.BitArray{1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Dates.Date, 1}, Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.setindex_widen_up_to), Array{Pair{String, String}, 1}, Pair{String, Float64}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.diff), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(*)), Tuple{Array{Float64, 2}, Array{Float64, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.vcat), Array{Float64, 2}, Array{Float64, 2}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(/)), Tuple{Array{Float64, 2}, Array{Float64, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(!)), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.isfinite), Tuple{Array{Float64, 2}}}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Float64, 2}, Array{Int64, 1}, Function}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.append!), Array{Float64, 1}, Tuple{Float64, Float64, Float64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Float64, 2}, Int64, Function}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.any), Function, Base.UnitRange{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Type{Int32}, Bool, Bool, Bool, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.abs), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(-)), Tuple{Array{Float64, 2}, Array{Float64, 2}}}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.Withdrawal._period_ends), Array{Dates.Date, 1}, String}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.abs), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(-)), Tuple{Array{Float64, 1}, Int64}}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.diff), Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(/)), Tuple{Array{Float64, 1}, Array{Float64, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(*)), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(/)), Tuple{Array{Float64, 1}, Float64}}, Int64}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Base.Dict{String, Any}}, Array{Pair{String, _A} where _A, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(&)), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(>)), Tuple{Array{Float64, 1}, Float64}}, Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(<=)), Tuple{Array{Float64, 1}, Float64}}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Float64, 2}, Base.UnitRange{Int64}, Function}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Float64, 2}, Function, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.copy), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.any), Function, Base.SubArray{Float64, 1, Array{Float64, 2}, Tuple{Int64, Base.Slice{Base.OneTo{Int64}}}, true}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.collect), Base.UnitRange{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Array{Dates.Date, 1}}, Array{Dates.Date, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Array{Float64, 1}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(-)), Tuple{Array{Float64, 2}, Float64}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Printf.format), Printf.Format{Base.CodeUnits{UInt8, String}, Tuple{Printf.Spec{Base.Val{reinterpret(Char, 0x58000000)}}}}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.collect), Type{String}, Array{Any, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.reduce), typeof(Base.vcat), Array{Array{String, 1}, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.any), Function, Base.OneTo{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.size), Array{Float64, 2}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.merge), NamedTuple{(:start_value, :risk_free, :fractions, :liquidate, :details, :io), Tuple{Float64, Int64, Bool, Bool, Bool, Base.DevNull}}, Array{Pair{Symbol, Any}, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(*)), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(*)), Tuple{Array{Float64, 2}, Float64}}, Int64}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.any), Function, Array{Float64, 2}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Printf.format), Printf.Format{Base.CodeUnits{UInt8, String}, Tuple{Printf.Spec{Base.Val{reinterpret(Char, 0x66000000)}}}}, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.trues), Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(<=)), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.abs), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(-)), Tuple{Array{Float64, 1}, Float64}}}}, Float64}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.findnext), typeof(Base.isnan), Array{Float64, 1}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.prod), Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.any), Function, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.findfirst), Function, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Base.LinearIndices{N, R} where R<:Tuple{Vararg{Base.AbstractUnitRange{Int64}, N}} where N}, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(*)), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(*)), Tuple{Int64, Array{Float64, 1}}}, Base.StepRangeLen{Float64, Base.TwicePrecision{Float64}, Base.TwicePrecision{Float64}, Int64}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.setindex!), Array{Float64, 1}, Float64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.reduce), typeof(Base.vcat), Array{Array{Int64, 1}, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize!), Base.SubArray{String, 1, Array{String, 1}, Tuple{Base.UnitRange{Int64}}, true}, Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.identity), Tuple{Array{String, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.__cat), Base.BitArray{1}, Tuple{Int64}, Tuple{Bool}, Base.BitArray{1}, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(/)), Tuple{Array{Float64, 1}, Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.sqrt), Tuple{Array{Float64, 1}}}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.length), Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize!), Base.SubArray{Float64, 1, Array{Float64, 1}, Tuple{Base.UnitRange{Int64}}, true}, Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.identity), Tuple{Array{Float64, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.log), Tuple{Array{Float64, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.findall), Base.Fix{2, typeof(Base.:(!=)), Int64}, Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.hcat), Array{Float64, 1}, Array{Float64, 1}, Array{Float64, 1}, Vararg{Array{Float64, 1}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(SimLev.Bootstrap._days), Tuple{Array{Dates.Date, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Float64, 2}, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.reduce), typeof(Base.vcat), Array{Array{Float64, 1}, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Float64, 2}, Function, Array{Bool, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.all), Function, Base.OneTo{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Float64, 2}, Function, Base.UnitRange{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Base.Iterators.Enumerate{Array{String, 1}}, Tuple{Int64, Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(<=)), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(-)), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(+)), Tuple{Array{Int64, 1}, Int64}}, Int64}}, Int64}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Base.Iterators.Enumerate{Array{String, 1}}, Tuple{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.push!), Base.Set{Any}, Tuple{Float64, Float64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.findall), Base.Fix{2, typeof(Base.:(!=)), String}, Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(>)), Int64, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(<=)), Tuple{Array{Dates.Date, 1}, Base.RefValue{Dates.Date}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.repeat), Array{Int64, 1}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.isfinite), Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.Withdrawal._wd_zve), Int64, Int64, Nothing}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.in), String, Tuple{String, String, String}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.eachindex), Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(|)), Base.BitArray{1}, Base.BitArray{1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Dates.Date, 1}, Array{Bool, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.setindex_widen_up_to), Array{Array{Float64, 1}, 1}, Array{String, 1}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.in), String, Tuple{String, String}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.collect), Type{Dates.Date}, Array{Dates.Date, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.hcat), Array{Int64, 1}, Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(&)), Base.BitArray{1}, Base.BitArray{1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.setindex!), Array{Float64, 2}, Float64, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.length), Tuple{Array{Array{T, 1} where T, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(>)), Float64, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.vcat), Array{Float64, 1}, Float64, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.length), Tuple{Array{Array{Float64, 1}, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:nrow,), Tuple{Int64}}, Type{SimLev.RFrame}, Pair{String, Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Pair{A, B} where B where A}, String, Base.Dict{String, Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.max), Tuple{Array{Int64, 1}, Int64}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Iterators.enumerate), Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._any), Base.Fix{2, typeof(Base.:(<=)), Int64}, Array{Float64, 2}, Base.Colon}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(/)), Array{Float64, 2}, Array{Float64, 2}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Array{Float64, 2}, 1}, Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.findnext), Base.ComposedFunction{typeof(Base.:(!)), typeof(Base.isfinite)}, Array{Float64, 1}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.merge), NamedTuple{(:start_value, :risk_free, :fractions, :liquidate, :details, :io), Tuple{Float64, Int64, Bool, Bool, Bool, Base.DevNull}}, NamedTuple{(:order_fee, :dca_fee, :dca_mode, :dca_value, :dca_span, :dca_days, :dca_unit, :dca_anchor, :dca_start, :dca_skip, :balance_dca, :balance_mode, :balance_span, :balance_days, :balance_unit, :balance_anchor, :balance_start, :balance_skip, :balance_thresh, :balance_thresh_type, :event_col, :event_mode, :event_weight, :tax_mode, :tax_rate, :church_tax, :sparer_pauschbetrag, :use_sparer_pauschbetrag, :private_sale_threshold, :base_rate, :base_rate_flex, :base_rate_data, :use_guenstigerpruefung), Tuple{Nothing, Nothing, Bool, Int64, Int64, Nothing, String, String, Nothing, Bool, Bool, Bool, Nothing, Nothing, String, String, Nothing, Bool, Nothing, String, Nothing, String, Nothing, String, Float64, Int64, Int64, Bool, Int64, Int64, Bool, Nothing, Bool}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.merge), NamedTuple{(:start_value, :risk_free, :fractions, :liquidate, :details, :io), Tuple{Int64, Int64, Bool, Bool, Bool, Base.DevNull}}, NamedTuple{(:order_fee, :dca_fee, :balance_mode, :balance_span, :balance_days, :balance_unit, :balance_anchor, :balance_start, :balance_skip, :balance_thresh, :balance_thresh_type, :event_col, :event_mode, :event_weight), Tuple{Nothing, Nothing, Bool, Int64, Nothing, String, String, Nothing, Bool, Float64, String, Nothing, String, Nothing}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.setindex!), Array{Float64, 1}, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.maximum), Array{Dates.Date, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.view), Array{Float64, 2}, Function, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Dates.Date, 1}, Base.BitArray{1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.setindex!), Array{Float64, 1}, Array{Float64, 1}, Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, Type{Int64}, Tuple{Array{Float64, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.pointer), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.lastindex), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.cat_similar), Base.BitArray{1}, Type, Tuple{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.in), Tuple{Float64, Float64}, Base.Set{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.vcat), Float64, Float64, Float64, Vararg{Union{Number, AbstractArray{T, N} where N where T}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.append!), Array{Float64, 1}, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.collect), Tuple{String, String}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.indexed_iterate), Tuple{String, Int64}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(-)), Int64, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.__cat_offset!), Array{Float64, 1}, Tuple{Int64}, Tuple{Bool}, Tuple{Int64}, Array{Float64, 1}, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.cconvert), Type{Ptr{Float64}}, Ptr{Float64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.indexed_iterate), Tuple{String, Int64}, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.unsafe_convert), Type{Ptr{Float64}}, Ptr{Float64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(-)), Float64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.sym_in), Symbol, NTuple{23, Symbol}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.ceil), Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._cat_t), Base.Val{1}, Type{Bool}, Base.BitArray{1}, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.axes), Array{Float64, 2}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{String, 1}, Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.minimum), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.__cat_offset!), Array{Float64, 1}, Tuple{Int64}, Tuple{Bool}, Tuple{Int64}, Float64, Float64, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.collect), NTuple{5, String}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.collect), NTuple{4, String}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{SimLev.RList}, Pair{String, Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.abs), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(-)), Tuple{Array{Float64, 1}, Int64}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.typed_vcat), Type{Float64}, Array{Float64, 1}, Array{Float64, 1}, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.size), Array{Float64, 2}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._cshp), Int64, Tuple{Bool}, Tuple{}, Tuple{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{SimLev.RList}, Pair{String, SimLev.NamedMat{Float64}}, Vararg{Pair{String, SimLev.NamedMat{Float64}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.vec), Array{Float64, 2}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.get), Base.Dict{Dates.Date, Int64}, Dates.Date, Nothing}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Float64, 2}, Function, Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(*)), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(/)), Tuple{Array{Float64, 1}, Float64}}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.sym_in), Symbol, NTuple{33, Symbol}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.eachindex), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.merge), NamedTuple{(:start_value, :risk_free, :fractions, :liquidate, :details, :io), Tuple{Int64, Int64, Bool, Bool, Bool, Base.DevNull}}, NamedTuple{(:order_fee, :dca_fee), Tuple{Nothing, Nothing}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.setindex!), Array{String, 1}, String, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.collect), Base.StepRange{Int64, Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.merge), NamedTuple{(:start_value, :risk_free, :fractions, :liquidate, :details, :io), Tuple{Float64, Int64, Bool, Bool, Bool, Base.DevNull}}, NamedTuple{(:order_fee, :dca_fee, :dca_mode, :dca_value, :dca_span, :dca_days, :dca_unit, :dca_anchor, :dca_start, :dca_skip, :balance_dca, :tax_mode, :tax_rate, :church_tax, :sparer_pauschbetrag, :use_sparer_pauschbetrag, :private_sale_threshold, :base_rate, :base_rate_flex, :base_rate_data, :use_guenstigerpruefung, :taxable_income, :tax_tariff), Tuple{Nothing, Nothing, Bool, Int64, Int64, Nothing, String, String, Nothing, Bool, Bool, String, Float64, Int64, Int64, Bool, Int64, Int64, Bool, Nothing, Bool, Int64, Nothing}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.Withdrawal._dfcol), SimLev.RFrame, String}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(>=)), Float64, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.all), Function, Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{SimLev.Cfg}, String, Float64, Float64, Nothing, Float64, Float64, Float64, Nothing, Float64, Float64, Bool, Bool, Nothing, Nothing, Bool, Nothing, Bool, Float64, Nothing, Bool, Nothing, Nothing, String, Int64, Int64, Bool, Bool, Nothing, Base.BitArray{1}, Array{Pair{String, Base.Dict{String, Any}}, 1}, Array{String, 1}, Nothing}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.merge), NamedTuple{(:start_value, :risk_free, :fractions, :liquidate, :details, :io), Tuple{Int64, Int64, Bool, Bool, Bool, Base.DevNull}}, NamedTuple{(:order_fee, :dca_fee, :balance_mode, :balance_span, :balance_days, :balance_unit, :balance_anchor, :balance_start, :balance_skip, :balance_thresh, :balance_thresh_type, :event_col, :event_mode, :event_weight), Tuple{Nothing, Nothing, Bool, Nothing, Nothing, String, String, Nothing, Bool, Nothing, String, String, String, SimLev.RList}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.length), Base.BitArray{1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.ones), Type{Float64}, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(-)), Int64, Base.StepRangeLen{Float64, Base.TwicePrecision{Float64}, Base.TwicePrecision{Float64}, Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev._sim_fset!), Array{Pair{String, Any}, 1}, String, String}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.any), Function, Base.SubArray{Float64, 1, Array{Float64, 2}, Tuple{Base.Slice{Base.OneTo{Int64}}, Int64}, true}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.Withdrawal._dfnames), SimLev.RFrame}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{SimLev.RList}, Pair{String, NamedTuple{(:buys, :sells, :taxes), Tuple{Array{SimLev.Lot, 1}, Array{SimLev.SellEntry, 1}, Array{SimLev.TaxEntry, 1}}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.view), Array{Float64, 2}, Base.UnitRange{Int64}, Function}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.__cat), Array{Float64, 1}, Tuple{Int64}, Tuple{Bool}, Array{Float64, 1}, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Array{Bool, 1}}, Array{Bool, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(/)), Array{Float64, 2}, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Base.Iterators.Zip{Is} where Is<:Tuple}, Tuple{Array{Any, 1}, Array{Bool, 1}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{SimLev.Cfg}, String, Float64, Float64, Nothing, Float64, Float64, Float64, SimLev.TariffEnv, Float64, Float64, Bool, Bool, Nothing, Nothing, Bool, Nothing, Bool, Float64, Nothing, Bool, Nothing, Nothing, String, Int64, Int64, Bool, Bool, Nothing, Base.BitArray{1}, Array{Pair{String, Base.Dict{String, Any}}, 1}, Array{String, 1}, Nothing}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.isempty), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._any), typeof(Base.isfinite), Base.SubArray{Float64, 1, Array{Float64, 2}, Tuple{Base.Slice{Base.OneTo{Int64}}, Int64}, true}, Base.Colon}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.hashindex), Tuple{Float64, Float64}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Base.Iterators.Flatten{Array{Array{Float64, 1}, 1}}, Tuple{Int64, Array{Float64, 1}, Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.filter), typeof(Base.isfinite), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Base.Iterators.Flatten{Array{Array{Float64, 1}, 1}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.indexed_iterate), Pair{String, Any}, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getproperty), Base.MappingRF{typeof(Base.identity), typeof(Base.mul_prod)}, Symbol}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getproperty), Pair{String, Any}, Symbol}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Base.SubString{String}, 1}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.to_indices), Array{Float64, 2}, Tuple{Base.OneTo{Int64}}, Tuple{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Iterators.zip), Array{Any, 1}, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Float64, 2}, Array{Bool, 1}, Function}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(+)), Int64, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.occursin), Char, String}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.any), Function, Array{Pair{String, String}, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.__cat), Array{Float64, 1}, Tuple{Int64}, Tuple{Bool}, Float64, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:tariff_on,), Tuple{Bool}}, typeof(SimLev._tax_rates), Float64, Int64, Bool, Nothing, Bool, Float64, String}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.any), Function, Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(*)), Array{Float64, 2}, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.all), Function, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:tariff_on,), Tuple{Bool}}, typeof(SimLev._tax_rates), Float64, Int64, Bool, Int64, Bool, Int64, String}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.collect), Type{Bool}, Array{Bool, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Int64, 1}, Base.UnitRange{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._cat_t), Base.Val{1}, Type{Float64}, Array{Float64, 1}, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._minimum), Array{Float64, 1}, Base.Colon}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.isfinite), Array{Float64, 2}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.ParamSearch._is_atomic), Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._cat_t), Base.Val{1}, Type{Float64}, Float64, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(!)), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.isfinite), Tuple{Array{Float64, 2}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.view), Array{Float64, 2}, Int64, Function}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:class,), Tuple{Array{String, 1}}}, Type{SimLev.RFrame}, Pair{String, Any}, Vararg{Pair{String, Any}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.reshape), Array{Int64, 1}, Int64, Base.Colon}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.indexed_iterate), Pair{String, Any}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Base.Iterators.Enumerate{Array{Union{Base.Missing, Bool}, 1}}, Tuple{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Sort.searchsortedfirst), Array{Float64, 1}, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Base.Iterators.Enumerate{Array{Union{Base.Missing, Bool}, 1}}, Tuple{Int64, Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.maybeview), Array{Float64, 1}, Base.UnitRange{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._cat_size_shape), Tuple{Bool}, Tuple{Int64}, Float64, Float64, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.round), Type{Int64}, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.all), Array{Bool, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Base.UnitRange{Int64}, Base.UnitRange{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.log), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Base.LinearIndices{N, R} where R<:Tuple{Vararg{Base.AbstractUnitRange{Int64}, N}} where N}, Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.permutedims), Array{Float64, 2}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.push!), Array{Array{Int64, 1}, 1}, Array{Int64, 1}, Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.map), Function, Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Array{NamedTuple{(:m, :err, :date, :ret), Tuple{Tuple{Array{String, 1}, Array{Float64, 1}}, Base.Missing, Array{Dates.Date, 1}, Array{Float64, 1}}}, 1}}, UndefInitializer, Tuple{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getproperty), Pair{String, Int64}, Symbol}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.promote_eltypeof), Float64, Float64, Float64, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.split), String, String}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{NamedTuple{(:n, :seed, :progress, :path_length, :cores), T} where T<:Tuple}, Tuple{Int64, Int64, Bool, Int64, Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:start_value, :base_rate, :cost_basis, :tax), Tuple{Float64, Float64, Int64, SimLev.RList}}, typeof(SimLev.Withdrawal.withdrawal_simulation), Array{Float64, 2}, SimLev.RList}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._array_for), Type{Any}, Array{Array{Float64, 2}, 1}, Base.HasShape{1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(*)), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(*)), Tuple{Int64, Array{Float64, 1}}}, Base.StepRangeLen{Float64, Base.TwicePrecision{Float64}, Base.TwicePrecision{Float64}, Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{NamedTuple{(:value, :span), T} where T<:Tuple}, Tuple{Int64, Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.cat_size_shape), Tuple{Bool}, Float64, Float64, Vararg{Any}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Pair{Int64, Int64}}, Any, Any}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(/)), Array{Float64, 1}, Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.sqrt), Tuple{Array{Float64, 1}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.merge), NamedTuple{(:start_value, :risk_free, :fractions, :liquidate, :details, :io), Tuple{Float64, Int64, Bool, Bool, Bool, Base.DevNull}}, NamedTuple{(:order_fee, :dca_fee, :dca_mode, :dca_value, :dca_span, :dca_days, :dca_unit, :dca_anchor, :dca_start, :dca_skip, :balance_dca), Tuple{Nothing, Nothing, Bool, Float64, Int64, Nothing, String, String, Nothing, Bool, Bool}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:class,), Tuple{String}}, Type{SimLev.RList}, Pair{String, Any}, Vararg{Pair{String, Any}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.vect), Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.cat_size_shape), Tuple{Bool}, Array{Float64, 1}, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(-)), Array{Float64, 2}, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(SimLev.Bootstrap._days), Array{Dates.Date, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(*)), Float64, Base.UnitRange{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.floor), Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(*)), Int64, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._array_for), Type{Bool}, Base.OneTo{Int64}, Base.HasShape{1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.empty), Base.Dict{Any, Any}, Type{String}, Type{Array{Float64, 1}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.unsafe_convert), Type{Ptr{Float64}}, GenericMemoryRef{:not_atomic, Float64, Core.AddrSpace{Core}(0x00)}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.findfirst), Function, Array{Dates.Date, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(<=)), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.abs), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(-)), Tuple{Array{Float64, 1}, Float64}}}}, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(&)), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(>)), Tuple{Array{Float64, 1}, Float64}}, Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(<=)), Tuple{Array{Float64, 1}, Float64}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.cconvert), Type{Ptr{Float64}}, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.Withdrawal._fill_locf), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Array{UInt8, 1}}, UndefInitializer, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:start_value,), Tuple{Float64}}, typeof(SimLev.Withdrawal.withdrawal_simulation), Array{Float64, 2}, SimLev.RList}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.identity), Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Array{Pair{String, String}, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.occursin), Base.Regex, String}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._prechecked_iterate), Base.OneTo{Int64}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.materialize!), Base.SubArray{Float64, 2, Array{Float64, 2}, Tuple{Base.UnitRange{Int64}, Base.Slice{Base.OneTo{Int64}}}, false}, Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{0}, Nothing, typeof(Base.identity), Tuple{Float64}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{SimLev.RList}, Pair{String, SimLev.RFrame}, Vararg{Pair{String, SimLev.RFrame}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.indexed_iterate), Tuple{UInt64, Bool}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(*)), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(*)), Tuple{Array{Float64, 2}, Float64}}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.length), Array{Array{T, 1} where T, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.max), Array{Int64, 1}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:class,), Tuple{String}}, Type{SimLev.RList}, Pair{String, Array{Float64, 2}}, Vararg{Pair{A, B} where B where A}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Iterators.enumerate), Array{Union{Base.Missing, Bool}, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.setindex!), Array{Pair{String, Any}, 1}, Pair{String, String}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.all), Function, Base.UnitRange{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._array_for), Type{Pair{String, Any}}, Array{Pair{String, String}, 1}, Base.HasShape{1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(-)), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(+)), Tuple{Array{Int64, 1}, Int64}}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.abs), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{2}, Nothing, typeof(Base.:(-)), Tuple{Array{Float64, 2}, Array{Float64, 2}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.indexed_iterate), Pair{String, String}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.iterate), Array{Pair{String, String}, 1}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._nt_names), Type{NamedTuple{(:order_fee, :dca_fee, :dca_mode, :dca_value, :dca_span, :dca_days, :dca_unit, :dca_anchor, :dca_start, :dca_skip, :balance_dca, :balance_mode, :balance_span, :balance_days, :balance_unit, :balance_anchor, :balance_start, :balance_skip, :balance_thresh, :balance_thresh_type, :event_col, :event_mode, :event_weight, :tax_mode, :tax_rate, :church_tax, :sparer_pauschbetrag, :use_sparer_pauschbetrag, :private_sale_threshold, :base_rate, :base_rate_flex, :base_rate_data, :use_guenstigerpruefung), Tuple{Nothing, Nothing, Bool, Int64, Int64, Nothing, String, String, Nothing, Bool, Bool, Bool, Nothing, Nothing, String, String, Nothing, Bool, Nothing, String, Nothing, String, Nothing, String, Float64, Int64, Int64, Bool, Int64, Int64, Bool, Nothing, Bool}}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{NamedTuple{(:leverage,), T} where T<:Tuple}, Tuple{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.getindex), Array{Array{T, 1} where T, 1}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.length), Array{Array{Float64, 1}, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:years,), Tuple{Int64}}, typeof(SimLev.Withdrawal.withdrawal_cohorts), SimLev.RFrame}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._any), typeof(Base.isnothing), Array{Int64, 1}, Base.Colon}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(+)), Int64, Int64, Int64, Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:S,), Tuple{Int64}}, typeof(SimLev.Overfitting.overfit_pbo), Array{Float64, 2}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Base.:(<=)), Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(-)), Tuple{Base.Broadcast.Broadcasted{Base.Broadcast.DefaultArrayStyle{1}, Nothing, typeof(Base.:(+)), Tuple{Array{Int64, 1}, Int64}}, Int64}}, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.indexed_iterate), Tuple{UInt64, Bool}, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Iterators.flatten), Array{Array{Float64, 1}, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base._array_for), Type{Float64}, Base.Iterators.Flatten{Array{Array{Float64, 1}, 1}}, Base.SizeUnknown}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(>)), Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.vec), Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.top_set_bit), UInt64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), Type{Int64}, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.convert), Type{Pair{String, Any}}, Pair{String, Array{String, 1}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(!=)), Float64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.split_sign), Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.get!), Base.Dict{String, Array{Float64, 1}}, String, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:replace, :stream), Tuple{Bool, SimLev.SLib.Stream}}, typeof(SimLev.SLib.sample), Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.Broadcast.broadcasted), typeof(Dates.day), Array{Dates.Date, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Base.Iterators.Zip{Is} where Is<:Tuple}, Tuple{Array{String, 1}, Array{Array{Float64, 1}, 1}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{Base.Iterators.Zip{Is} where Is<:Tuple}, Tuple{Array{String, 1}, Array{Array{T, 1} where T, 1}}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.trunc), Float64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.Dependence.copula_fit), Array{Float64, 1}, Array{Float64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.size), Array{Int64, 2}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:n_grid, :n_sim, :seed), Tuple{Int64, Int64, Int64}}, typeof(SimLev.Planning.planning_goal), Array{Float64, 2}, Float64, Float64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.indexed_iterate), Pair{String, String}, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:alg,), Tuple{Base.Sort.MergeSortAlg}}, typeof(Base.sortperm), Array{Int64, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.:(*)), Int64, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.as_rframe), SimLev.RFrame}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{NamedTuple{(:start_value,), T} where T<:Tuple}, Tuple{Float64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.ParamSearch._ps_levels), Array{String, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.unsigned), UInt64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.lastindex), Array{Bool, 1}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Dates.year), Dates.Date}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{NamedTuple{(:base_rate,), T} where T<:Tuple}, Tuple{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Dates.month), Dates.Date}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.abs), UInt64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{NamedTuple{(:k,), T} where T<:Tuple}, Tuple{Int64}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.clamp), Int64, Int64, Int64}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{Type{NamedTuple{(:benchmark,), T} where T<:Tuple}, Tuple{String}}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(SimLev.MsGarch._ms_garch_fit), Array{Float64, 1}, Int64, String}) || (nfail += 1); catch; nfail += 1; end
    try; precompile(Tuple{typeof(Base.string), Int64}) || (nfail += 1); catch; nfail += 1; end
    return nfail
end
