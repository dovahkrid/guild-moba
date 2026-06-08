import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/render/entity_view.dart';

void main() {
  test('faces right on positive dx, left on negative dx', () {
    expect(facingFor(0.5, 1), 1);
    expect(facingFor(-0.5, 1), -1);
  });

  test('holds previous facing inside the deadzone', () {
    expect(facingFor(0.0, -1), -1);
    expect(facingFor(0.01, 1), 1);
  });

  test('defaults to right when previous facing is 0', () {
    expect(facingFor(0.0, 0), 1);
  });
}
