/// `html`: parsing and querying a page the host fetched (§3.5).
///
/// "Implemented by the host with a Dart HTML parser (selector coverage checked in Phase 0);
/// read-only; page scripts never execute." The parser is `package:html`, and page scripts are not
/// run because nothing here runs them: a parsed document is a tree, not a browser.
///
/// **Refused selectors.** Phase 0 measured what `package:html` gets wrong
/// (`spikes/html_selectors/`): `:has()`, `:nth-of-type()` and `:nth-child(an+b)` raise
/// `UnimplementedError`, while `:empty`, `:nth-child(odd)` and `:nth-child(n)` on indented HTML
/// **silently match nothing**. The silent half is the dangerous one: an extension author tests
/// against a minified sample, ships, and their users quietly lose chapters. So SourceAPI 1.0 makes
/// `select` and `selectFirst` **throw** for `:has()`, `:nth-child()`, `:nth-last-child()`,
/// `:nth-of-type()`, `:only-of-type` and `:empty`, and that is what happens here, with a message
/// naming the selector. A later minor version may add them once the app implements them correctly,
/// which is additive.
///
/// **Handles, not trees.** Only plain data crosses to an extension, so a document and its nodes
/// cross as numbers and the tree stays here. Nothing in the contract frees a document, so the
/// runtime says when a call is over and the documents parsed during it go with it.
library;

import 'dart:async';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import '../extension/extension_runtime.dart';
import 'host_bridge.dart';

/// The `html` module of one extension's host API.
final class HtmlBridge implements HostBridge, CallScopedBridge {
  HtmlBridge({this.maxDocuments = 16});

  /// How many documents one extension may hold at once. A scraper parses a page, reads it and
  /// moves on; sixteen is more than any of them needs and few enough to bound the memory a runtime
  /// can hold in parsed trees.
  final int maxDocuments;

  final _documents = <int, _ParsedDocument>{};
  var _nextDocument = 1;

  @override
  String get module => 'html';

  @override
  FutureOr<Object?> call(String method, List<Object?> arguments) {
    if (method == 'parse') {
      return _parse(
        arguments.stringAt(0, 'the text to parse'),
        arguments.optionalStringAt(1, 'a base URL'),
      );
    }
    final document = _documentOf(arguments.intAt(0, 'a document'));
    final node = document.nodeAt(arguments.intAt(1, 'an element'));
    switch (method) {
      case 'select':
        return document.handlesOf(_select(node, arguments, all: true));
      case 'selectFirst':
        final found = _select(node, arguments, all: false);
        return found.isEmpty ? null : document.handleOf(found.first);
      case 'text':
        return _collapse(node.text ?? '');
      case 'attr':
        return node.attributes[arguments.stringAt(2, 'an attribute name')];
      case 'absUrl':
        return document.absoluteUrl(
          node.attributes[arguments.stringAt(2, 'an attribute name')],
        );
      case 'html':
        // The element's contents, as jsoup's html() gives them, and the whole page for the
        // document itself, which has no inside of its own.
        return switch (node) {
          final dom.Element element => element.innerHtml,
          final dom.Document document => document.outerHtml,
          _ => '',
        };
      default:
        throw HostCallException('there is no html.$method');
    }
  }

  int _parse(String text, String? baseUrl) {
    if (_documents.length >= maxDocuments) {
      throw HostCallException(
        'this extension is holding $maxDocuments parsed documents at once; '
        'parse a page, read it, and let it go',
      );
    }
    final handle = _nextDocument++;
    _documents[handle] = _ParsedDocument(
      parser.parse(text),
      baseUrl == null ? null : Uri.tryParse(baseUrl),
    );
    return handle;
  }

  _ParsedDocument _documentOf(int handle) {
    final document = _documents[handle];
    if (document == null) {
      throw const HostCallException(
        'that document has been let go; a parsed document lives until the call that parsed it ends',
      );
    }
    return document;
  }

  List<dom.Element> _select(
    dom.Node node,
    List<Object?> arguments, {
    required bool all,
  }) {
    final selector = arguments.stringAt(2, 'a CSS selector');
    final refused = refusedSelector(selector);
    if (refused != null) {
      throw HostCallException(
        '$refused is not supported, and would match the wrong elements rather than say so: '
        'SourceAPI 1.0 refuses :has(), :nth-child(), :nth-last-child(), :nth-of-type(), '
        ':only-of-type and :empty',
      );
    }
    try {
      if (node case final dom.Element element) {
        return all
            ? element.querySelectorAll(selector)
            : [?element.querySelector(selector)];
      }
      final document = node as dom.Document;
      return all
          ? document.querySelectorAll(selector)
          : [?document.querySelector(selector)];
    } on HostCallException {
      rethrow;
    } catch (error) {
      // An unsupported selector the contract does not name, or one that does not parse. Either way
      // it is the extension's selector, and saying so beats an empty list.
      throw HostCallException('"$selector" could not be used: $error');
    }
  }

  /// Whitespace collapsed, as the contract says `text()` gives it.
  static String _collapse(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  @override
  void endOfCall() {
    _documents.clear();
  }
}

/// The pseudo-class in [selector] that SourceAPI 1.0 refuses, or null when it uses none.
///
/// Quoted strings are skipped, so an attribute selector such as `[data-note=":empty"]` is not a
/// refusal: what is inside quotes is a value, not a selector.
String? refusedSelector(String selector) {
  const refused = [
    ':has(',
    ':nth-child(',
    ':nth-last-child(',
    ':nth-of-type(',
    ':only-of-type',
    ':empty',
  ];
  final lower = selector.toLowerCase();
  var quote = '';
  for (var i = 0; i < lower.length; i++) {
    final character = lower[i];
    if (quote.isNotEmpty) {
      if (character == '\\') {
        i++;
      } else if (character == quote) {
        quote = '';
      }
      continue;
    }
    if (character == '"' || character == "'") {
      quote = character;
      continue;
    }
    if (character != ':') continue;
    for (final name in refused) {
      if (lower.startsWith(name, i)) {
        return name.endsWith('(')
            ? '${name.substring(0, name.length - 1)}()'
            : name;
      }
    }
  }
  return null;
}

/// One parsed page, and the handles its nodes are known by.
final class _ParsedDocument {
  _ParsedDocument(this.document, this.baseUrl);

  final dom.Document document;
  final Uri? baseUrl;

  /// Node 0 is the document itself, so that `html.parse` can hand back one handle for both.
  final _nodes = <dom.Node>[];
  final _handles = <dom.Node, int>{};

  dom.Node nodeAt(int handle) {
    if (handle == 0) return document;
    final index = handle - 1;
    if (index < 0 || index >= _nodes.length) {
      throw const HostCallException('that element is not from this document');
    }
    return _nodes[index];
  }

  int handleOf(dom.Node node) {
    final known = _handles[node];
    if (known != null) return known;
    _nodes.add(node);
    final handle = _nodes.length;
    _handles[node] = handle;
    return handle;
  }

  List<int> handlesOf(Iterable<dom.Node> nodes) => [
    for (final node in nodes) handleOf(node),
  ];

  /// An attribute read as an absolute URL, against the base the extension gave.
  ///
  /// Null when there is no such attribute, when there is no base to resolve against, or when what
  /// it holds is not a URL: `absUrl` is how an extension turns a page's `href` into something it
  /// can fetch, and a broken link on a page is not a reason to fail the call.
  String? absoluteUrl(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty) return null;
    final relative = Uri.tryParse(text);
    if (relative == null) return null;
    if (relative.hasScheme) return relative.toString();
    final base = baseUrl;
    if (base == null || !base.hasScheme) return null;
    return base.resolveUri(relative).toString();
  }
}
