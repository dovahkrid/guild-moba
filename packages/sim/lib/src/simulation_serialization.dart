part of 'simulation.dart';

/// One serialized per-Entity *body* field, in wire order. The SINGLE source of
/// truth for the entity body layout: canonicalBytes / snapshotBytes /
/// restoreFromSnapshot and Simulation.peekEntityPos all derive from
/// [_entityBodyCodecs], so adding a serialized field (e.g. Plan 7 XP/level) is a
/// one-row edit. The identity prefix (id, kind, teamId) is NOT here — it is read/
/// written explicitly (id is the lookup key; kind/teamId are construction-only).
final class _EntityFieldCodec {
  final void Function(ByteWriter w, Entity e) write;
  final void Function(ByteReader r, Entity e) readInto;

  /// Decode this field (advancing the reader) WITHOUT an Entity — for
  /// peekEntityPos, which only inspects pos. Returns the decoded value.
  final Object Function(ByteReader r) read;

  /// True for fields present only in snapshotBytes (netcode wire + restore) and
  /// absent from canonicalBytes (the determinism hash). Currently: `target`.
  final bool snapshotOnly;

  const _EntityFieldCodec({
    required this.write,
    required this.readInto,
    required this.read,
    this.snapshotOnly = false,
  });
}

_EntityFieldCodec _i32Codec(int Function(Entity) get, void Function(Entity, int) set) =>
    _EntityFieldCodec(
      write: (w, e) => w.i32(get(e)),
      readInto: (r, e) => set(e, r.i32()),
      read: (r) => r.i32(),
    );

_EntityFieldCodec _fixedCodec(Fixed Function(Entity) get, void Function(Entity, Fixed) set) =>
    _EntityFieldCodec(
      write: (w, e) => w.fixed(get(e)),
      readInto: (r, e) => set(e, r.fixed()),
      read: (r) => r.fixed(),
    );

_EntityFieldCodec _fvecCodec(FVec2 Function(Entity) get, void Function(Entity, FVec2) set,
        {bool snapshotOnly = false}) =>
    _EntityFieldCodec(
      write: (w, e) {
        final v = get(e);
        w.fixed(v.x);
        w.fixed(v.y);
      },
      readInto: (r, e) => set(e, FVec2(r.fixed(), r.fixed())),
      read: (r) => FVec2(r.fixed(), r.fixed()),
      snapshotOnly: snapshotOnly,
    );

/// The pos codec is referenced directly by Simulation.peekEntityPos (the only
/// field it returns); it is also the first entry in [_entityBodyCodecs].
final _EntityFieldCodec _posCodec =
    _fvecCodec((e) => e.pos, (e, v) => e.pos = v);

/// The per-Entity body, in EXACT wire order. Must match the pre-DRY layout
/// byte-for-byte (pos, vel, hp, maxHp, attackCooldown, gold, respawnTimer,
/// attackTargetId, statusElement, statusTimer, reactionIcd, abilityCooldown,
/// ultCooldown, target[snapshot-only]).
final List<_EntityFieldCodec> _entityBodyCodecs = List.unmodifiable([
  _posCodec,
  _fvecCodec((e) => e.vel, (e, v) => e.vel = v),
  _fixedCodec((e) => e.hp, (e, v) => e.hp = v),
  _fixedCodec((e) => e.maxHp, (e, v) => e.maxHp = v),
  _i32Codec((e) => e.attackCooldown, (e, v) => e.attackCooldown = v),
  _i32Codec((e) => e.gold, (e, v) => e.gold = v),
  _i32Codec((e) => e.respawnTimer, (e, v) => e.respawnTimer = v),
  _i32Codec((e) => e.attackTargetId, (e, v) => e.attackTargetId = v),
  _i32Codec((e) => e.statusElement, (e, v) => e.statusElement = v),
  _i32Codec((e) => e.statusTimer, (e, v) => e.statusTimer = v),
  _i32Codec((e) => e.reactionIcd, (e, v) => e.reactionIcd = v),
  _i32Codec((e) => e.abilityCooldown, (e, v) => e.abilityCooldown = v),
  _i32Codec((e) => e.ultCooldown, (e, v) => e.ultCooldown = v),
  _fvecCodec((e) => e.target, (e, v) => e.target = v, snapshotOnly: true),
]);

/// Binary serialization for [Simulation] (canonical determinism format +
/// netcode wire/restore format), split out of simulation.dart (cleaning phase).
/// Same library → retains private access; zero behavior change. Emitted bytes are
/// IDENTICAL to before (proven by the replay goldens + the 0xbedf4a43 anchor).
extension SimulationSerialization on Simulation {
  void _writeHeader(ByteWriter w, int version) {
    w.i32(version);
    w.i32(tick);
    w.u32(_rng.stateLo); // RNG limbs are unsigned 32-bit
    w.u32(_rng.stateHi);
    w.i32(_winnerTeam);
  }

  void _writeFields(ByteWriter w) {
    w.i32(_fields.length);
    for (final f in _fields) {
      w.i32(f.ownerId);
      w.fixed(f.center.x);
      w.fixed(f.center.y);
      w.i32(f.element);
      w.i32(f.timer);
    }
  }

  /// Canonical, integer-only, ordered byte encoding of the full state. Excludes
  /// snapshot-only fields (Entity.target) so the determinism golden never moves
  /// when the wire format evolves.
  Uint8List canonicalBytes() {
    final w = ByteWriter();
    _writeHeader(w, kSchemaVersion);
    final ids = entityIdsSorted;
    w.i32(ids.length);
    for (final id in ids) {
      final e = _byId[id]!;
      w.i32(id);
      w.i32(e.kind.index);
      w.i32(e.teamId);
      for (final c in _entityBodyCodecs) {
        if (c.snapshotOnly) continue;
        c.write(w, e);
      }
    }
    _writeFields(w);
    return w.toBytes();
  }

  int canonicalStateHash() => (FnvHasher()..addBytes(canonicalBytes())).hash;

  /// Netcode wire + restore format. Superset of canonicalBytes() that also
  /// carries snapshot-only fields (Entity.target) so reconciliation can resume
  /// authoritative seeking.
  Uint8List snapshotBytes() {
    final w = ByteWriter();
    _writeHeader(w, kSnapshotVersion);
    final ids = entityIdsSorted;
    w.i32(ids.length);
    for (final id in ids) {
      final e = _byId[id]!;
      w.i32(id);
      w.i32(e.kind.index);
      w.i32(e.teamId);
      for (final c in _entityBodyCodecs) {
        c.write(w, e);
      }
    }
    _writeFields(w);
    return w.toBytes();
  }

  /// Overwrite this sim's entire state from snapshotBytes(). Reuses existing
  /// Entity instances (ids are stable); spawns any present on the authority but
  /// absent locally (with placeholder pos/hp/maxHp immediately overwritten by the
  /// body codecs). Drops entities absent from the snapshot. Rebuilds _fields.
  void restoreFromSnapshot(Uint8List bytes) {
    final r = ByteReader(bytes);
    final version = r.i32();
    // A real throw (not assert) — asserts are stripped in release, and a
    // version-mismatched snapshot from a newer server must fail loud.
    if (version != kSnapshotVersion) {
      throw ArgumentError(
          'unsupported snapshot version $version (expected $kSnapshotVersion)');
    }
    tick = r.i32();
    final lo = r.u32();
    final hi = r.u32();
    _rng = DetRng.fromState(lo, hi);
    _winnerTeam = r.i32();
    final count = r.i32();
    final seen = <int>{};
    // A malformed snapshot can make a codec read throw mid-entity, leaving that
    // entity partially mutated. That is acceptable: a corrupt or version-
    // mismatched snapshot (see the version check above) is a fatal condition,
    // not a recoverable state.
    for (var i = 0; i < count; i++) {
      final id = r.i32();
      final kindIndex = r.i32();
      final teamId = r.i32();
      var e = _byId[id];
      if (e == null) {
        // id/kind/team are immutable → set via constructor; pos/hp/maxHp are
        // placeholders, overwritten by the body codecs below.
        e = Entity(
          id: id,
          kind: EntityKind.values[kindIndex],
          teamId: teamId,
          pos: FVec2.zero,
          hp: Fixed.zero,
          maxHp: Fixed.zero,
        );
        _entities.add(e);
        _byId[id] = e;
      }
      for (final c in _entityBodyCodecs) {
        c.readInto(r, e);
      }
      seen.add(id);
    }
    // Drop entities absent from the snapshot (despawned on the authority).
    _entities.removeWhere((e) => !seen.contains(e.id));
    _byId.removeWhere((id, e) => !seen.contains(id));
    final fieldCount = r.i32();
    _fields.clear();
    for (var i = 0; i < fieldCount; i++) {
      final ownerId = r.i32();
      final cx = r.fixed();
      final cy = r.fixed();
      final element = r.i32();
      final timer = r.i32();
      _fields.add(ElementalField(
          ownerId: ownerId, center: FVec2(cx, cy), element: element, timer: timer));
    }
    _lastDamager.clear();
  }
}
