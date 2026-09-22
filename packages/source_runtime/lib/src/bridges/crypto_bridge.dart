/// `crypto`: hashes, HMAC, Base64 and AES decryption, for reading a site's own responses (§3.5).
///
/// **What it is for.** Sites sign and obfuscate their own API responses — a signed query parameter,
/// a token hashed from a timestamp, a JSON body wrapped in AES with the key in the page. An
/// extension needs these to read what the site sends its own web player. Nothing here touches
/// media, and nothing here is for DRM: §7.1 is not negotiable, and an extension that used this to
/// strip protection from audio would be removed from the official repository rather than
/// accommodated. The app never hands media bytes to an extension in the first place — the download
/// engine fetches them itself (§5.2) — so this cannot reach them.
///
/// **Shapes.** A hash and an HMAC come back as lower-case hexadecimal, which is what a site's own
/// JavaScript compares against. `base64Decode` and `aesDecrypt` come back as bytes, which reach an
/// extension as an `ArrayBuffer`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:pointycastle/export.dart' as pc;

import 'host_bridge.dart';

/// The `crypto` module of one extension's host API.
final class CryptoBridge implements HostBridge {
  const CryptoBridge();

  @override
  String get module => 'crypto';

  @override
  FutureOr<Object?> call(String method, List<Object?> arguments) {
    switch (method) {
      case 'hash':
        final algorithm = arguments.stringAt(0, 'an algorithm');
        return _hex(
          _digestOf(algorithm, const [
            'md5',
            'sha1',
            'sha256',
            'sha512',
          ]).convert(_bytes(arguments, 1, 'the data to hash')).bytes,
        );
      case 'hmac':
        final algorithm = arguments.stringAt(0, 'an algorithm');
        final key = _bytes(arguments, 1, 'a key');
        final data = _bytes(arguments, 2, 'the data to sign');
        return _hex(
          hashes.Hmac(
            _digestOf(algorithm, const ['sha1', 'sha256', 'sha512']),
            key,
          ).convert(data).bytes,
        );
      case 'base64Encode':
        return base64.encode(_bytes(arguments, 0, 'the data to encode'));
      case 'base64Decode':
        return _decodeBase64(arguments.stringAt(0, 'base64 text'));
      case 'aesDecrypt':
        return _aesDecrypt(arguments.objectAt(0, 'the options'));
      default:
        throw HostCallException('there is no crypto.$method');
    }
  }

  /// Bytes as the extension passed them: an `ArrayBuffer`, or text, which is read as UTF-8.
  ///
  /// The contract takes `string | ArrayBuffer` everywhere bytes are wanted, because a site's own
  /// code does the same. Text is UTF-8, the one encoding the rest of the app uses.
  static Uint8List _bytes(List<Object?> arguments, int index, String what) {
    final value = index < arguments.length ? arguments[index] : null;
    return switch (value) {
      final String text => Uint8List.fromList(utf8.encode(text)),
      final Uint8List bytes => bytes,
      final List<Object?> numbers when numbers.every((n) => n is int) =>
        Uint8List.fromList(numbers.cast<int>()),
      _ => throw HostCallException('$what is text or bytes'),
    };
  }

  static hashes.Hash _digestOf(String algorithm, List<String> allowed) {
    if (!allowed.contains(algorithm)) {
      throw HostCallException(
        '"$algorithm" is not one of ${allowed.join(', ')}',
      );
    }
    return switch (algorithm) {
      'md5' => hashes.md5,
      'sha1' => hashes.sha1,
      'sha256' => hashes.sha256,
      _ => hashes.sha512,
    };
  }

  static String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Base64 as a site writes it: with or without padding, standard or URL-safe.
  ///
  /// A strict decoder would refuse half the tokens found in the wild for a missing `=`, and an
  /// extension cannot fix what the site sent.
  static Uint8List _decodeBase64(String text) {
    final trimmed = text.replaceAll(RegExp(r'\s'), '');
    final standard = trimmed.replaceAll('-', '+').replaceAll('_', '/');
    final padded = standard.padRight(
      standard.length + (4 - standard.length % 4) % 4,
      '=',
    );
    try {
      return base64.decode(padded);
    } on FormatException catch (error) {
      throw HostCallException('that is not base64: ${error.message}');
    }
  }

  /// AES-CBC, AES-CTR or AES-GCM, decrypting only.
  ///
  /// GCM takes the authentication tag appended to the ciphertext, as the Web Crypto API and every
  /// site's own JavaScript produce it, and a tag that does not match fails the call: a response
  /// that was tampered with is not a response.
  static Uint8List _aesDecrypt(Map<Object?, Object?> options) {
    final mode = options['mode'];
    final key = _fieldBytes(options, 'key');
    final iv = _fieldBytes(options, 'iv');
    final data = _fieldBytes(options, 'data');
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      throw HostCallException(
        'an AES key is 16, 24 or 32 bytes, not ${key.length}',
      );
    }
    try {
      switch (mode) {
        case 'cbc':
          _requireIv(iv, 16, 'cbc');
          final cipher =
              pc.PaddedBlockCipherImpl(
                pc.PKCS7Padding(),
                pc.CBCBlockCipher(pc.AESEngine()),
              )..init(
                false,
                pc.PaddedBlockCipherParameters<pc.CipherParameters, Null>(
                  pc.ParametersWithIV(pc.KeyParameter(key), iv),
                  null,
                ),
              );
          return cipher.process(data);
        case 'ctr':
          _requireIv(iv, 16, 'ctr');
          final cipher = pc.CTRStreamCipher(pc.AESEngine())
            ..init(false, pc.ParametersWithIV(pc.KeyParameter(key), iv));
          return cipher.process(data);
        case 'gcm':
          if (iv.isEmpty) {
            throw const HostCallException('gcm needs a nonce');
          }
          final cipher = pc.GCMBlockCipher(pc.AESEngine())
            ..init(
              false,
              pc.AEADParameters(pc.KeyParameter(key), 128, iv, Uint8List(0)),
            );
          return cipher.process(data);
        default:
          throw HostCallException(
            'the mode is "cbc", "ctr" or "gcm", not ${mode == null ? 'nothing' : '"$mode"'}',
          );
      }
    } on HostCallException {
      rethrow;
    } catch (error) {
      // Bad padding, a tag that does not match, a length that is not a whole number of blocks:
      // every one of them means the key, the data or the mode was wrong, and none of them should
      // reach the app as a crash.
      throw HostCallException('the data could not be decrypted: $error');
    }
  }

  static void _requireIv(Uint8List iv, int length, String mode) {
    if (iv.length != length) {
      throw HostCallException(
        '$mode needs an iv of $length bytes, not ${iv.length}',
      );
    }
  }

  static Uint8List _fieldBytes(Map<Object?, Object?> options, String name) {
    final value = options[name];
    return switch (value) {
      final Uint8List bytes => bytes,
      final String text => Uint8List.fromList(utf8.encode(text)),
      final List<Object?> numbers when numbers.every((n) => n is int) =>
        Uint8List.fromList(numbers.cast<int>()),
      _ => throw HostCallException('$name is bytes'),
    };
  }
}
