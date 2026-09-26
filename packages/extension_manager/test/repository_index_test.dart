// Reading what a repository publishes about itself and what it offers.
//
// A repository is the same third party the extension code is, reached over the same network, so its
// documents are read exactly as strictly as an extension's own output: every field checked, one bad
// entry failing the whole document, and a message that says what is wrong rather than that
// something is.

import 'dart:convert';

import 'package:kikuyomi_extension_manager/kikuyomi_extension_manager.dart';
import 'package:test/test.dart';

/// A 32-byte key, which is what Ed25519 uses.
final aKey = base64Encode(List.filled(32, 7));

const aHash =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

String repoJson({
  Map<String, Object?> changed = const {},
  List<String> removed = const [],
}) => jsonEncode(
  {
    'formatVersion': 1,
    'name': 'Kikuyomi official',
    'website': 'https://example.org/repo',
    'publicKey': aKey,
    ...changed,
  }..removeWhere((key, value) => removed.contains(key)),
);

/// One entry, carrying the manifest fields an index repeats plus the repository's own.
///
/// No `files`: those hashes describe a package's contents, not a listing, and an entry omitting
/// them is the case that proves the manifest decoder can serve both.
Map<String, Object?> entryData({
  Map<String, Object?> changed = const {},
  List<String> removed = const [],
}) => {
  'id': 'org.example.librivox',
  'name': 'LibriVox',
  'version': '1.4.0',
  'versionCode': 14,
  'apiVersion': '1.0',
  'minAppVersion': '1.0.0',
  'author': 'Example Maintainers',
  'contentRating': 'everyone',
  'domains': ['librivox.org', 'archive.org'],
  'capabilities': ['latest'],
  'sources': [
    {'key': 'librivox', 'name': 'LibriVox', 'lang': 'en', 'versionId': 1},
  ],
  'package': {
    'url': 'https://example.org/librivox-14.zip',
    'sha256': aHash,
    'size': 40960,
  },
  'iconUrl': 'https://example.org/librivox.png',
  'signature': base64Encode(List.filled(64, 1)),
  ...changed,
}..removeWhere((key, value) => removed.contains(key));

String indexJson({
  List<Map<String, Object?>>? extensions,
  int? formatVersion,
}) => jsonEncode({
  if (formatVersion != null) 'formatVersion': formatVersion,
  'extensions': extensions ?? [entryData()],
});

Matcher refuses(String naming) => throwsA(
  isA<RepositoryException>().having(
    (e) => e.message,
    'message',
    contains(naming),
  ),
);

void main() {
  group('repo.json', () {
    test('says who the repository is and what it signs with', () {
      final info = RepositoryInfo.parse(repoJson());

      expect(info.name, 'Kikuyomi official');
      expect(info.website, 'https://example.org/repo');
      expect(info.publicKey, aKey);
    });

    test('a website is optional', () {
      expect(
        RepositoryInfo.parse(repoJson(removed: ['website'])).website,
        isNull,
      );
    });

    test('a name is not', () {
      expect(
        () => RepositoryInfo.parse(repoJson(removed: ['name'])),
        refuses('name'),
      );
      expect(
        () => RepositoryInfo.parse(repoJson(changed: {'name': '   '})),
        refuses('name'),
      );
    });

    group('the signing key', () {
      test('must be there', () {
        expect(
          () => RepositoryInfo.parse(repoJson(removed: ['publicKey'])),
          refuses('publicKey'),
        );
      });

      test('must be base64', () {
        expect(
          () => RepositoryInfo.parse(
            repoJson(changed: {'publicKey': 'not base64!!'}),
          ),
          refuses('publicKey'),
        );
      });

      test('must be the size an Ed25519 key is', () {
        // Finding this out now beats finding it out when the first signature fails to verify.
        expect(
          () => RepositoryInfo.parse(
            repoJson(changed: {'publicKey': base64Encode(List.filled(16, 7))}),
          ),
          refuses('32 bytes'),
        );
      });
    });

    group('its fingerprint', () {
      test('is the whole digest, in the form every other tool shows', () {
        final fingerprint = RepositoryInfo.parse(repoJson()).fingerprint;

        expect(fingerprint.split(':'), hasLength(32));
        expect(
          fingerprint,
          matches(RegExp(r'^([0-9A-F]{2}:){31}[0-9A-F]{2}$')),
        );
      });

      test('differs for a different key', () {
        // The whole use of a fingerprint is that comparing it means something.
        final mine = RepositoryInfo.parse(repoJson()).fingerprint;
        final theirs = RepositoryInfo.parse(
          repoJson(changed: {'publicKey': base64Encode(List.filled(32, 9))}),
        ).fingerprint;

        expect(mine, isNot(theirs));
      });
    });
  });

  group('index.json', () {
    test('reads an entry without downloading any code', () {
      final index = RepositoryIndex.parse(indexJson());
      final entry = index.entries.single;

      expect(entry.id, 'org.example.librivox');
      expect(entry.manifest.name, 'LibriVox');
      expect(entry.manifest.versionCode, 14);
      expect(entry.package.url, 'https://example.org/librivox-14.zip');
      expect(entry.package.sha256, aHash);
      expect(entry.package.sizeBytes, 40960);
      expect(entry.iconUrl, 'https://example.org/librivox.png');
      expect(entry.revoked, isFalse);
    });

    test('carries what the permissions summary needs', () {
      // §3.9's reason for repeating the metadata: the listener sees what an extension will contact
      // and how it is rated before anything of it is fetched.
      final entry = RepositoryIndex.parse(indexJson()).entries.single;

      expect(entry.manifest.domains.allowsHost('librivox.org'), isTrue);
      expect(entry.manifest.domains.allowsHost('example.com'), isFalse);
      expect(entry.manifest.contentRating, ExtensionContentRating.everyone);
      expect(entry.manifest.sources, hasLength(1));
    });

    test('an entry has no files, and that is not a failure', () {
      // The case that lets one decoder serve a manifest and an index entry alike.
      expect(
        RepositoryIndex.parse(indexJson()).entries.single.manifest.files,
        isEmpty,
      );
    });

    test('a bad manifest field fails the whole index, naming the entry', () {
      expect(
        () => RepositoryIndex.parse(
          indexJson(
            extensions: [
              entryData(removed: ['id']),
            ],
          ),
        ),
        refuses('extensions[0]'),
      );
    });

    test('one bad entry fails all of it rather than being skipped', () {
      // A listing that quietly dropped an extension would look like a repository that no longer
      // offers it.
      expect(
        () => RepositoryIndex.parse(
          indexJson(
            extensions: [
              entryData(),
              entryData(changed: {'version': 12}),
            ],
          ),
        ),
        refuses('extensions[1]'),
      );
    });

    test('the same extension twice is refused', () {
      // Which version is being offered would be a guess, and a trust boundary must not guess.
      expect(
        () => RepositoryIndex.parse(
          indexJson(extensions: [entryData(), entryData()]),
        ),
        refuses('listed more than once'),
      );
    });

    test('an empty repository is empty, not broken', () {
      expect(RepositoryIndex.parse(indexJson(extensions: [])).entries, isEmpty);
    });
  });

  group('a package location', () {
    Object? Function() parsing(Map<String, Object?> package) =>
        () => RepositoryIndex.parse(
          indexJson(
            extensions: [
              entryData(changed: {'package': package}),
            ],
          ),
        );

    test('is fetched over https, never plain http', () {
      // A plain-HTTP package on an HTTPS index is a downgrade, and there is no reason to take one.
      expect(
        parsing({'url': 'http://example.org/a.zip', 'sha256': aHash}),
        refuses('not https'),
      );
    });

    test('is a URL at all', () {
      expect(
        parsing({'url': 'not a url', 'sha256': aHash}),
        refuses('is not a URL'),
      );
    });

    test('names a real SHA-256', () {
      expect(
        parsing({'url': 'https://example.org/a.zip', 'sha256': 'abc'}),
        refuses('64 hex characters'),
      );
      expect(
        parsing({'url': 'https://example.org/a.zip', 'sha256': 'z' * 64}),
        refuses('64 hex characters'),
      );
    });

    test('takes a hash however it was cased', () {
      final entry = RepositoryIndex.parse(
        indexJson(
          extensions: [
            entryData(
              changed: {
                'package': {
                  'url': 'https://example.org/a.zip',
                  'sha256': aHash.toUpperCase(),
                },
              },
            ),
          ],
        ),
      ).entries.single;

      expect(entry.package.sha256, aHash);
    });

    test('a size is optional, and is a count of bytes when it is there', () {
      expect(
        RepositoryIndex.parse(
          indexJson(
            extensions: [
              entryData(
                changed: {
                  'package': {
                    'url': 'https://example.org/a.zip',
                    'sha256': aHash,
                  },
                },
              ),
            ],
          ),
        ).entries.single.package.sizeBytes,
        isNull,
      );
      expect(
        parsing({
          'url': 'https://example.org/a.zip',
          'sha256': aHash,
          'size': 0,
        }),
        refuses('size'),
      );
    });

    test('must be there at all', () {
      expect(
        () => RepositoryIndex.parse(
          indexJson(
            extensions: [
              entryData(removed: ['package']),
            ],
          ),
        ),
        refuses('package'),
      );
    });
  });

  group('a signature', () {
    test('is required by the format, even before it is checked', () {
      // ADR-0018: adding the field later would break every published repository, so it is required
      // from version 1 and verified when the install path lands.
      expect(
        () => RepositoryIndex.parse(
          indexJson(
            extensions: [
              entryData(removed: ['signature']),
            ],
          ),
        ),
        refuses('signature'),
      );
    });

    test('is base64', () {
      expect(
        () => RepositoryIndex.parse(
          indexJson(
            extensions: [
              entryData(changed: {'signature': 'not base64!!'}),
            ],
          ),
        ),
        refuses('signature'),
      );
    });
  });

  group('a withdrawn version (§3.8)', () {
    RepositoryIndex withRevoked() => RepositoryIndex.parse(
      indexJson(
        extensions: [
          entryData(changed: {'revoked': true}),
          entryData(
            changed: {
              'id': 'org.example.other',
              'sources': [
                {'key': 'other', 'name': 'Other', 'lang': 'en', 'versionId': 1},
              ],
            },
          ),
        ],
      ),
    );

    test('is still read and still listed', () {
      // "This version was withdrawn" is something to tell the listener, not to hide from them.
      expect(withRevoked().entries, hasLength(2));
      expect(withRevoked().entries.first.revoked, isTrue);
    });

    test('is left out of what may be installed', () {
      expect(
        [for (final entry in withRevoked().offered) entry.id],
        ['org.example.other'],
      );
    });

    test('is false when the index does not say', () {
      expect(
        RepositoryIndex.parse(indexJson()).entries.single.revoked,
        isFalse,
      );
    });
  });

  group('the format version', () {
    test('a newer document is refused, and says to update', () {
      // The reason for a version at all: a newer format may mean something different by a field of
      // the same name, so reading it hopefully is worse than refusing it.
      expect(
        () => RepositoryIndex.parse(indexJson(formatVersion: 99)),
        refuses('Update Kikuyomi'),
      );
      expect(
        () => RepositoryInfo.parse(repoJson(changed: {'formatVersion': 99})),
        refuses('Update Kikuyomi'),
      );
    });

    test('a document that does not say reads as the first version', () {
      // So the first indexes published without the field still work.
      expect(RepositoryIndex.parse(indexJson()).entries, hasLength(1));
      expect(
        RepositoryInfo.parse(repoJson(removed: ['formatVersion'])).name,
        isNotEmpty,
      );
    });
  });

  group('a document that is not one', () {
    test('is not JSON', () {
      expect(() => RepositoryIndex.parse('{oh dear'), refuses('not JSON'));
      expect(() => RepositoryInfo.parse('{oh dear'), refuses('not JSON'));
    });

    test('is JSON but not an object', () {
      expect(() => RepositoryIndex.parse('[]'), refuses('an object'));
      expect(
        () => RepositoryInfo.parse('"a repository"'),
        refuses('an object'),
      );
    });

    test('has no list of extensions', () {
      expect(() => RepositoryIndex.parse('{}'), refuses('extensions'));
      expect(
        () => RepositoryIndex.parse('{"extensions": {}}'),
        refuses('extensions'),
      );
    });
  });

  test('an entry can be found by id', () {
    final index = RepositoryIndex.parse(indexJson());

    expect(index.entryFor('org.example.librivox')?.manifest.name, 'LibriVox');
    expect(index.entryFor('org.example.nothing'), isNull);
  });
}
