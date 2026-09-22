/// `http`: the only way an extension reaches the network (§3.5).
///
/// "Only manifest-declared domains; per-source rate limit; per-extension cookie jar;
/// host-controlled User-Agent; body size cap; timeout." The client holds the last four; this holds
/// the first, on the request the extension made and on every redirect hop, because a redirect is a
/// URL the extension never named and a site that redirects to another host must have declared it.
///
/// There is no global `fetch` in the prelude, so this is the whole of an extension's reach.
///
/// **What comes back.** Any status, including 404 and 500: the contract returns them rather than
/// throwing, because a source often reads a 404 as "the book is gone". Only a failure to connect is
/// a `Network` error. The body is text, JSON or bytes, as the extension asked.
library;

import 'dart:async';
import 'dart:convert';

import 'package:kikuyomi_networking/kikuyomi_networking.dart' as net;
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

import 'host_bridge.dart';

/// The `http` module of one extension's host API.
final class HttpBridge implements HostBridge {
  HttpBridge({required this.client, required this.domains})
    : _decoder = PlainDataDecoder(domains);

  /// This extension's view of the app's transport: its cookies, its rate limits.
  final net.SourceHttpClient client;

  /// The domains its manifest declared. Every URL, and every redirect, is held to them.
  final DomainAllowlist domains;

  final PlainDataDecoder _decoder;

  @override
  String get module => 'http';

  @override
  Future<Object?> call(String method, List<Object?> arguments) async {
    if (method != 'fetch') {
      throw HostCallException('there is no http.$method');
    }
    final asked = arguments.objectAt(0, 'a request');
    final HttpRequest request;
    try {
      // The same decoder that reads a source's results reads its requests: one URL rule, one set
      // of header rules, one place they are written down.
      request = _decoder.decodeHttpRequest(asked);
    } on SourceException catch (error) {
      return hostError('Parse', error.message);
    }
    final responseType = switch (asked['responseType']) {
      null || 'text' => _ResponseType.text,
      'json' => _ResponseType.json,
      'bytes' => _ResponseType.bytes,
      final Object other => throw HostCallException(
        'responseType is "text", "json" or "bytes", not "$other"',
      ),
    };

    final net.NetworkResponse response;
    try {
      response = await client.send(
        net.NetworkRequest(
          url: request.url,
          method: request.method == HttpMethod.post
              ? net.HttpMethod.post
              : net.HttpMethod.get,
          headers: request.headers,
          body: request.body,
        ),
        check: _allow,
      );
    } on net.NetworkFailure catch (failure) {
      return hostError('Network', failure.message);
    } on net.NetworkLimitReached catch (limit) {
      // The site answered; the app will not carry what it said. That is a limit of the contract's
      // Limits table, which fails a call as Parse.
      return hostError('Parse', limit.message);
    } on FormatException catch (error) {
      return hostError(
        'Network',
        'that request could not be sent: ${error.message}',
      );
    }

    final Object? body;
    switch (responseType) {
      case _ResponseType.bytes:
        body = response.body;
      case _ResponseType.text:
        body = _text(response);
      case _ResponseType.json:
        final text = _text(response);
        try {
          body = jsonDecode(text);
        } on FormatException catch (error) {
          return hostError(
            'Parse',
            'the answer from ${response.url.host} is not JSON: ${error.message}',
          );
        }
    }
    return {
      'status': response.status,
      'url': response.url.toString(),
      'headers': response.headers,
      'body': body,
    };
  }

  /// Every URL, including each redirect hop, held to the extension's declared domains.
  ///
  /// The permissions screen before install lists these domains, and the promise it makes is that
  /// they are every host the source can make the app contact. A redirect the extension did not
  /// name would break that promise quietly, so it stops here instead.
  void _allow(Uri url) {
    final problem = domains.problemWith(url);
    if (problem != null) {
      throw HostCallException('$url: $problem');
    }
  }

  /// The body as text, in the encoding the site said it used.
  ///
  /// UTF-8 unless the header says Latin-1, and malformed bytes become U+FFFD rather than failing:
  /// a page with one bad byte is still a page, and the contract's own reading rules keep the
  /// mojibake that produces rather than refusing the book.
  static String _text(net.NetworkResponse response) {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final latin1Named =
        contentType.contains('charset=iso-8859-1') ||
        contentType.contains('charset=latin-1') ||
        contentType.contains('charset=windows-1252');
    return latin1Named
        ? latin1.decode(response.body, allowInvalid: true)
        : utf8.decode(response.body, allowMalformed: true);
  }
}

enum _ResponseType { text, json, bytes }
