/// Working out where a repository's documents are from what the listener typed (§3.2).
///
/// "Users add repositories by URL or deep link." What they actually paste is whatever was in front
/// of them: the page they were reading, the raw index, a GitHub project, a host with no scheme on
/// it. All of those name the same repository, and asking a listener to work out the raw URL of a
/// GitHub file is asking them to do something they should not have to know about. Mihon does this
/// translation and so does this.
///
/// The one thing that is not forgiven is a plain-HTTP repository. Everything a repository serves
/// decides what code runs on the device, and there is no version of that worth doing over a
/// connection anyone on the path can rewrite.
library;

import 'index.dart';

/// Where a repository's `repo.json` and `index.json` are.
final class RepositoryLocation {
  const RepositoryLocation(this.base);

  /// What the listener typed, as somewhere to resolve documents against.
  ///
  /// Throws [RepositoryException] when it names nowhere, or nowhere safe.
  factory RepositoryLocation.parse(String typed) {
    final text = typed.trim();
    if (text.isEmpty) {
      throw const RepositoryException('a repository needs an address');
    }
    // A listener who types a host has typed an https one; nobody means http by leaving it out.
    final withScheme = text.contains('://') ? text : 'https://$text';
    final url = Uri.tryParse(withScheme);
    // A scheme and a host, checked separately rather than through `isAbsolute`, which is false for
    // any URI carrying a fragment — and a listener who copied the address bar has one.
    if (url == null || url.scheme.isEmpty || url.host.isEmpty) {
      throw RepositoryException('"$typed" is not an address');
    }
    if (url.scheme != 'https') {
      throw RepositoryException(
        '${url.scheme} is not https, and a repository decides what code runs '
        'on this device',
      );
    }
    return RepositoryLocation(_baseOf(_fromGitHub(url)));
  }

  /// The folder the documents sit in. Always ends in a slash, so resolving against it keeps the
  /// last path segment rather than replacing it.
  final Uri base;

  Uri get repoJson => base.resolve('repo.json');

  Uri get indexJson => base.resolve('index.json');

  @override
  String toString() => base.toString();

  @override
  bool operator ==(Object other) =>
      other is RepositoryLocation && other.base == base;

  @override
  int get hashCode => base.hashCode;
}

/// A GitHub page turned into the raw files behind it.
///
/// `github.com/user/repo` serves HTML; the files are at `raw.githubusercontent.com`. A listener
/// pasting the project page has named the right repository and the wrong host, and translating it
/// is the difference between a URL that works and one that returns a web page the parser then has to
/// explain is not JSON.
///
/// `HEAD` rather than `main`: a repository whose default branch is called something else still
/// resolves, and GitHub understands it.
Uri _fromGitHub(Uri url) {
  if (url.host.toLowerCase() != 'github.com') return url;
  final parts = [
    for (final part in url.pathSegments)
      if (part.isNotEmpty) part,
  ];
  if (parts.length < 2) return url;
  final user = parts[0];
  final repo = parts[1];

  // A link to a folder in the web view carries the branch and the path after it:
  // /user/repo/tree/<ref>/<path...>. A link to the file itself says `blob` and is otherwise the same.
  final linksIntoTree =
      parts.length > 3 && (parts[2] == 'tree' || parts[2] == 'blob');
  final ref = linksIntoTree ? parts[3] : 'HEAD';
  final within = linksIntoTree ? parts.sublist(4) : const <String>[];

  return Uri.https(
    'raw.githubusercontent.com',
    '/${[user, repo, ref, ...within].join('/')}',
  );
}

/// The folder [url] is in.
///
/// A listener may paste the index itself rather than the folder around it, which is what the address
/// bar shows once they have opened it to check it is really there.
Uri _baseOf(Uri url) {
  final segments = [
    for (final part in url.pathSegments)
      if (part.isNotEmpty) part,
  ];
  final named = segments.isNotEmpty ? segments.last.toLowerCase() : '';
  final folder = named == 'repo.json' || named == 'index.json'
      ? segments.sublist(0, segments.length - 1)
      : segments;
  // Built rather than `replace`d: passing null to `Uri.replace` keeps the original component, so a
  // query or a fragment the listener copied along with the address would survive into every
  // document URL resolved against this.
  return Uri(
    scheme: url.scheme,
    userInfo: url.userInfo,
    host: url.host,
    port: url.port,
    path: folder.isEmpty ? '/' : '/${folder.join('/')}/',
  );
}
