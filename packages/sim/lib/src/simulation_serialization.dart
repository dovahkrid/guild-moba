part of 'simulation.dart';

/// Binary serialization for [Simulation] (canonical determinism format +
/// netcode wire/restore format), split out of simulation.dart (cleaning phase).
/// Same library → retains private access; zero behavior change. Emitted bytes are
/// IDENTICAL to before (proven by the replay goldens + the 0x0fbfb7ac anchor).
extension SimulationSerialization on Simulation {
  /// Canonical, integer-only, ordered byte encoding of the full state.
  Uint8List canonicalBytes() {
    final w = ByteWriter();
    w.i32(kSchemaVersion);
    w.i32(tick);
    w.u32(_rng.stateLo); // RNG limbs are unsigned 32-bit; use u32 (see ByteWriter)
    w.u32(_rng.stateHi);
    w.i32(_winnerTeam);

    final ids = entityIdsSorted;
    w.i32(ids.length);
    for (final id in ids) {
      final e = _byId[id]!;
      w.i32(id);
      w.i32(e.kind.index);
      w.i32(e.teamId);
      w.fixed(e.pos.x);
      w.fixed(e.pos.y);
      w.fixed(e.vel.x);
      w.fixed(e.vel.y);
      w.fixed(e.hp);
      w.fixed(e.maxHp);
      w.i32(e.attackCooldown);
      w.i32(e.gold);
      w.i32(e.respawnTimer);
      w.i32(e.attackTargetId);
      w.i32(e.statusElement);
      w.i32(e.statusTimer);
      w.i32(e.reactionIcd);
      w.i32(e.abilityCooldown);
      // NOTE: target is intentionally NOT in the canonical format (snapshot-only).
    }
    w.i32(_fields.length);
    for (final f in _fields) {
      w.i32(f.ownerId);
      w.fixed(f.center.x);
      w.fixed(f.center.y);
      w.i32(f.element);
      w.i32(f.timer);
    }
    return w.toBytes();
  }

  int canonicalStateHash() => (FnvHasher()..addBytes(canonicalBytes())).hash;

  /// Netcode wire + restore format. Superset of canonicalBytes() that also
  /// carries Entity.target so reconciliation can resume authoritative seeking
  /// (esp. the opponent's target, which the client cannot re-derive). Distinct
  /// from canonicalBytes() so the Plan-1 determinism golden stays fixed.
  Uint8List snapshotBytes() {
    final w = ByteWriter();
    w.i32(kSnapshotVersion);
    w.i32(tick);
    w.u32(_rng.stateLo);
    w.u32(_rng.stateHi);
    w.i32(_winnerTeam);
    final ids = entityIdsSorted;
    w.i32(ids.length);
    for (final id in ids) {
      final e = _byId[id]!;
      w.i32(id);
      w.i32(e.kind.index);
      w.i32(e.teamId);
      w.fixed(e.pos.x);
      w.fixed(e.pos.y);
      w.fixed(e.vel.x);
      w.fixed(e.vel.y);
      w.fixed(e.hp);
      w.fixed(e.maxHp);
      w.i32(e.attackCooldown);
      w.i32(e.gold);
      w.i32(e.respawnTimer);
      w.i32(e.attackTargetId);
      w.i32(e.statusElement);
      w.i32(e.statusTimer);
      w.i32(e.reactionIcd);
      w.i32(e.abilityCooldown);
      w.fixed(e.target.x);
      w.fixed(e.target.y);
    }
    w.i32(_fields.length);
    for (final f in _fields) {
      w.i32(f.ownerId);
      w.fixed(f.center.x);
      w.fixed(f.center.y);
      w.i32(f.element);
      w.i32(f.timer);
    }
    return w.toBytes();
  }

  /// Overwrite this sim's entire state from snapshotBytes(). Reuses the existing
  /// Entity instances (ids are stable from create()). FVec2 is immutable, so we
  /// reassign the mutable fields: pos/vel/target plus hp/maxHp and the int
  /// combat/elemental fields (attackCooldown/gold/respawnTimer/attackTargetId/
  /// statusElement/statusTimer/reactionIcd/abilityCooldown). Also rebuilds the
  /// stationary elemental field list (_fields).
  void restoreFromSnapshot(Uint8List bytes) {
    final r = ByteReader(bytes);
    final version = r.i32();
    // A real throw (not assert) — asserts are stripped in release, and a
    // version-mismatched snapshot from a newer server must fail loud, not
    // silently corrupt state.
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
    for (var i = 0; i < count; i++) {
      final id = r.i32();
      final kindIndex = r.i32();
      final teamId = r.i32();
      final pos = FVec2(r.fixed(), r.fixed());
      final vel = FVec2(r.fixed(), r.fixed());
      final hp = r.fixed();
      final maxHp = r.fixed();
      final cooldown = r.i32();
      final gold = r.i32();
      final respawn = r.i32();
      final attackTargetId = r.i32();
      final statusElement = r.i32();
      final statusTimer = r.i32();
      final reactionIcd = r.i32();
      final abilityCooldown = r.i32();
      final target = FVec2(r.fixed(), r.fixed());
      seen.add(id);
      var e = _byId[id];
      if (e == null) {
        // Present on the authority but not locally — spawn it (id/kind/team
        // are immutable, so set via constructor; pos/hp/maxHp here are
        // overwritten by the unconditional apply block below).
        e = Entity(
          id: id,
          kind: EntityKind.values[kindIndex],
          teamId: teamId,
          pos: pos,
          hp: hp,
          maxHp: maxHp,
        );
        _entities.add(e);
        _byId[id] = e;
      }
      e.pos = pos;
      e.vel = vel;
      e.hp = hp;
      e.maxHp = maxHp;
      e.attackCooldown = cooldown;
      e.gold = gold;
      e.respawnTimer = respawn;
      e.attackTargetId = attackTargetId;
      e.statusElement = statusElement;
      e.statusTimer = statusTimer;
      e.reactionIcd = reactionIcd;
      e.abilityCooldown = abilityCooldown;
      e.target = target;
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
