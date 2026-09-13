// Spike (a), second half. Throwaway.
//
// Question: does the Dart `html` package support the CSS selectors a source extension would
// realistically need to scrape a catalogue page?
//
// The fixture below is synthetic. It is written to have the *shape* of a catalogue listing —
// cards, links, pagination, metadata rows, a table of chapters — without being taken from, or
// modelled on, any real service. Nothing here targets a specific site.
//
// Run: dart run bin/probe.dart

import 'package:html/parser.dart' show parse;

const fixture = '''
<!doctype html>
<html>
<body>
  <nav class="pager">
    <a class="page" href="/browse?p=1">1</a>
    <a class="page current" href="/browse?p=2">2</a>
    <a class="page" href="/browse?p=3">3</a>
    <a class="next" href="/browse?p=3" rel="next">Next</a>
  </nav>

  <ul id="results">
    <li class="card featured" data-id="a1" data-lang="en">
      <a class="cover" href="/book/a1"><img src="/img/a1.jpg" alt="Cover"></a>
      <h3 class="title"><a href="/book/a1">First Title</a></h3>
      <span class="author">Author One</span>
      <span class="duration" data-seconds="3600">1h 00m</span>
      <span class="badge new"></span>
    </li>
    <li class="card" data-id="a2" data-lang="en-gb">
      <a class="cover" href="/book/a2"><img src="/img/a2.jpg" alt="Cover"></a>
      <h3 class="title"><a href="/book/a2">Second Title</a></h3>
      <span class="author">Author Two</span>
      <span class="duration" data-seconds="7200">2h 00m</span>
    </li>
    <li class="card" data-id="a3" data-lang="fr">
      <h3 class="title"><a href="/book/a3">Third Title</a></h3>
      <span class="author">Author Three</span>
      <span class="duration" data-seconds="1800">0h 30m</span>
    </li>
  </ul>

  <table class="chapters">
    <tbody>
      <tr class="row"><td class="n">1</td><td class="ch">Chapter One</td><td class="len">10:00</td></tr>
      <tr class="row alt"><td class="n">2</td><td class="ch">Chapter Two</td><td class="len">12:30</td></tr>
      <tr class="row"><td class="n">3</td><td class="ch">Chapter Three</td><td class="len">09:45</td></tr>
    </tbody>
  </table>

  <div class="meta">
    <dl>
      <dt>Narrator</dt><dd>A Narrator</dd>
      <dt>Published</dt><dd>2019</dd>
    </dl>
  </div>
</body>
</html>
''';

class Probe {
  final String group;
  final String selector;
  final int expected;
  const Probe(this.group, this.selector, this.expected);
}

const probes = <Probe>[
  // The basics. If any of these fail, nothing else matters.
  Probe('basic', 'li.card', 3),
  Probe('basic', '#results', 1),
  Probe('basic', 'h3.title a', 3),
  Probe('basic', 'ul#results > li', 3),
  Probe('basic', 'a.page, a.next', 4),

  // Combinators. Sibling combinators matter for "the value next to this label" scraping,
  // which is how definition lists and metadata rows are usually read.
  Probe('combinator', 'dt + dd', 2),
  Probe('combinator', 'li.featured ~ li', 2),
  Probe('combinator', 'td.n + td.ch', 3),

  // Attribute operators. Extensions lean on these constantly for link filtering.
  Probe('attribute', 'a[href]', 9),
  Probe('attribute', 'a[rel="next"]', 1),
  Probe('attribute', 'a[href^="/book/"]', 5),
  Probe('attribute', 'img[src\$=".jpg"]', 2),
  Probe('attribute', 'a[href*="browse"]', 4),
  Probe('attribute', 'li[data-lang|="en"]', 2),
  Probe('attribute', 'li[class~="featured"]', 1),

  // Structural pseudo-classes.
  Probe('pseudo', 'li.card:first-child', 1),
  Probe('pseudo', 'li.card:last-child', 1),
  Probe('pseudo', 'tr.row:nth-child(2)', 1),
  Probe('pseudo', 'tr.row:nth-child(odd)', 2),
  Probe('pseudo', 'tr.row:nth-child(2n+1)', 2),
  Probe('pseudo', 'td:nth-of-type(3)', 3),
  Probe('pseudo', 'span.badge:empty', 1),
  Probe('pseudo', 'ul#results:only-of-type', 1),

  // Negation and relational. :has() is the modern one and the most useful for
  // "cards that actually have a cover image".
  Probe('negation', 'li.card:not(.featured)', 2),
  Probe('relational', 'li.card:has(img)', 2),
  Probe('relational', 'li.card:has(> a.cover)', 2),

  // Realistic composites, the shape an extension actually writes.
  Probe('composite', 'ul#results > li.card > h3.title > a[href^="/book/"]', 3),
  Probe('composite', 'li.card:not(.featured) span.duration[data-seconds]', 2),
];

void main() {
  final doc = parse(fixture);
  final results = <String, List<String>>{};
  var supported = 0;
  var wrong = 0;
  var unsupported = 0;

  for (final p in probes) {
    String status;
    String detail;
    try {
      final found = doc.querySelectorAll(p.selector);
      if (found.length == p.expected) {
        status = 'OK';
        detail = 'matched ${found.length}';
        supported++;
      } else {
        status = 'WRONG';
        detail = 'expected ${p.expected}, matched ${found.length}';
        wrong++;
      }
    } catch (e) {
      status = 'UNSUPPORTED';
      final text = e.toString().replaceAll('\n', ' ');
      detail = text.length > 90 ? '${text.substring(0, 90)}...' : text;
      unsupported++;
    }
    results
        .putIfAbsent(p.group, () => [])
        .add('  [$status] ${p.selector}  ::  $detail');
  }

  print(
    '--- spike (a) second half: CSS selector coverage in package:html ---\n',
  );
  for (final entry in results.entries) {
    print('${entry.key}:');
    entry.value.forEach(print);
    print('');
  }
  print(
    '--- $supported correct, $wrong wrong, $unsupported unsupported '
    '(of ${probes.length}) ---',
  );

  // A wrong result is more dangerous than an unsupported one: an extension that silently matches
  // the wrong number of elements produces a corrupted library rather than a visible failure.
  if (wrong > 0) {
    print(
      '\nNOTE: "WRONG" means the selector parsed but matched a different set than CSS '
      'requires. That fails silently in production, which is worse than throwing.',
    );
  }
}
