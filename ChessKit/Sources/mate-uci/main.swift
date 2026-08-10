import ChessProtocol

// PersistentNegamaxEngine so the transposition table stays warm across the
// searches within one game (see PersistentNegamaxEngine.swift) — the right
// choice here since this process plays out real games move by move, unlike
// the value-type NegamaxEngine used where bit-for-bit reproducibility matters
// (e.g. EngineLab's bench/match tooling).
let engine = PersistentNegamaxEngine(name: "MateMate", author: "testtest126/chess", book: .large)
UCIEngine(engine: engine).run()
