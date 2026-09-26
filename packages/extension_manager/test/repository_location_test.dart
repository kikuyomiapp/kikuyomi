// Working out where a repository's documents are from whatever the listener pasted.
//
// They paste what was in front of them: the project page, the raw index, a host with no scheme. All
// of those name the same repository, and making someone work out the raw URL of a GitHub file is
// asking them to know something they should not have to.

import 'package:kikuyomi_extension_manager/kikuyomi_extension_manager.dart';
import 'package:test/test.dart';

String baseOf(String typed) => RepositoryLocation.parse(typed).base.toString();

Matcher refuses(String naming) => throwsA(
  isA<RepositoryException>().having(
    (e) => e.message,
    'message',
    contains(naming),
  ),
);

void main() {
  group('an ordinary address', () {
    test('is the folder the documents sit in', () {
      expect(baseOf('https://example.org/repo/'), 'https://example.org/repo/');
    });

    test('gains the slash that makes it a folder', () {
      // Without it, resolving `repo.json` against it would replace the last segment rather than
      // sitting inside it.
      expect(baseOf('https://example.org/repo'), 'https://example.org/repo/');
    });

    test('at a bare host is that host', () {
      expect(baseOf('https://example.org'), 'https://example.org/');
    });

    test('gets https when the listener left the scheme off', () {
      // Nobody means http by leaving it out.
      expect(baseOf('example.org/repo'), 'https://example.org/repo/');
    });

    test('drops a query and a fragment', () {
      expect(
        baseOf('https://example.org/repo/?ref=x#top'),
        'https://example.org/repo/',
      );
    });
  });

  group('an address pointing at a document', () {
    test('is the folder around it', () {
      // What the address bar shows once someone has opened the index to check it is really there.
      expect(
        baseOf('https://example.org/repo/index.json'),
        'https://example.org/repo/',
      );
      expect(
        baseOf('https://example.org/repo/repo.json'),
        'https://example.org/repo/',
      );
    });

    test('however it was cased', () {
      expect(
        baseOf('https://example.org/repo/Index.JSON'),
        'https://example.org/repo/',
      );
    });

    test('and at the root of a host', () {
      expect(baseOf('https://example.org/index.json'), 'https://example.org/');
    });
  });

  group('a GitHub page', () {
    test('becomes the raw files behind it', () {
      // github.com serves HTML. A listener pasting the project page has named the right repository
      // and the wrong host.
      expect(
        baseOf('https://github.com/someone/extensions'),
        'https://raw.githubusercontent.com/someone/extensions/HEAD/',
      );
    });

    test('uses HEAD, so a repository not called main still resolves', () {
      expect(baseOf('https://github.com/someone/extensions'), contains('HEAD'));
    });

    test('keeps the branch and folder of a link into the tree', () {
      expect(
        baseOf('https://github.com/someone/extensions/tree/release/dist'),
        'https://raw.githubusercontent.com/someone/extensions/release/dist/',
      );
    });

    test('and of a link to the file itself', () {
      expect(
        baseOf('https://github.com/someone/extensions/blob/main/index.json'),
        'https://raw.githubusercontent.com/someone/extensions/main/',
      );
    });

    test('with a trailing slash, the same', () {
      expect(
        baseOf('https://github.com/someone/extensions/'),
        'https://raw.githubusercontent.com/someone/extensions/HEAD/',
      );
    });

    test('that names no repository is left alone', () {
      expect(
        baseOf('https://github.com/someone'),
        'https://github.com/someone/',
      );
    });

    test('and another host is never rewritten', () {
      expect(
        baseOf('https://example.org/someone/extensions'),
        'https://example.org/someone/extensions/',
      );
    });
  });

  group('an address that will not do', () {
    test('plain http is refused', () {
      // Everything a repository serves decides what code runs on the device, and there is no
      // version of that worth doing over a connection anyone on the path can rewrite.
      expect(() => baseOf('http://example.org/repo'), refuses('not https'));
    });

    test('so is nothing at all', () {
      expect(() => baseOf(''), refuses('needs an address'));
      expect(() => baseOf('   '), refuses('needs an address'));
    });

    test('and so is something that is not an address', () {
      expect(() => baseOf('https://'), refuses('is not an address'));
    });
  });

  group('the documents', () {
    test('sit inside the folder, not beside it', () {
      final at = RepositoryLocation.parse('https://example.org/repo');

      expect(at.repoJson.toString(), 'https://example.org/repo/repo.json');
      expect(at.indexJson.toString(), 'https://example.org/repo/index.json');
    });

    test('resolve the same however the listener got there', () {
      final typed = [
        'https://example.org/repo',
        'https://example.org/repo/',
        'https://example.org/repo/index.json',
        'example.org/repo',
      ];

      expect({
        for (final one in typed) RepositoryLocation.parse(one).indexJson,
      }, hasLength(1));
    });
  });

  test('two addresses for one place are one location', () {
    expect(
      RepositoryLocation.parse('https://example.org/repo'),
      RepositoryLocation.parse('https://example.org/repo/index.json'),
    );
  });
}
