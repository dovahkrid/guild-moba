/// Elements a hero/field/auto can apply. APPEND-ONLY: `.index` is serialized in
/// the status field. Pyro/Hydro are the slice's two; Electro/Cryo/Anemo append
/// later. (Anemo will never be a *stored* status — it only reads/consumes.)
enum Element { pyro, hydro }

/// Reactions detonated when a different element meets a stored status.
/// APPEND-ONLY: `.index` rides `ReactionTriggered.reaction`. Vaporize is the
/// slice's only reaction; Melt/Overload/etc. append later.
enum Reaction { vaporize }
