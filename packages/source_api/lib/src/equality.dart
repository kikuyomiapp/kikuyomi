/// Value equality for the lists and maps the contract's types hold. Internal to the package.
library;

bool listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final MapEntry(:key, :value) in a.entries) {
    if (!b.containsKey(key) || b[key] != value) return false;
  }
  return true;
}

/// A hash of [map] that does not depend on the order of its entries, as [mapEquals] does not.
int mapHash<K, V>(Map<K, V> map) => Object.hashAllUnordered([
  for (final MapEntry(:key, :value) in map.entries) Object.hash(key, value),
]);
