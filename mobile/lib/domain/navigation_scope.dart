/// Captured UI authority, never a grant of server access or a write basis.
/// No credential or recipient identity is exposed to a route.
class NavigationScope {
  const NavigationScope(this._current);

  final bool Function() _current;
  bool get isCurrent => _current();
}
