/// Reading plain data with a path, so that a refusal names the field that broke a rule.
///
/// Extension authors read these messages in the in-app console (§3.5), so every one of them says
/// where the bad value is, in the notation an author would use to reach it, and what is wrong with
/// it: `items[3].title: longer than 1,000 characters`.
///
/// Internal to this package. The rules it applies are SourceAPI 1.0's, listed under "Reading
/// results" in the contract.
library;

import '../errors.dart';
import '../limits.dart';

/// Fails the call, naming the field at [path].
Never rejectAt(String path, String problem) => throw ParseException(
  path.isEmpty ? 'the result: $problem' : '$path: $problem',
);

/// What a value is, in the words the contract uses for plain data.
String describe(Object? value) {
  if (value == null) return 'nothing';
  if (value is String) return 'a string';
  if (value is bool) return 'a boolean';
  if (value is num) return 'a number';
  if (value is List) return 'an array';
  if (value is Map) return 'an object';
  return 'a value that is not plain data';
}

/// A number with thousands separators, as the limits are written.
String grouped(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// [text] as it can be shown inside a message: short, on one line, quoted.
String quote(String text) {
  final buffer = StringBuffer('"');
  for (var i = 0; i < text.length && i < 40; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x20 || unit == 0x7f) {
      buffer.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      buffer.writeCharCode(unit);
    }
  }
  if (text.length > 40) buffer.write('…');
  return (buffer..write('"')).toString();
}

/// The first control character in [text], or null.
///
/// Tabs and line breaks are control characters too, and are left to the caller: text keeps or folds
/// them, while a key or a header name may hold neither.
int? _controlIn(String text, {required bool allowBreaks}) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    final isBreak = unit == 0x09 || unit == 0x0a || unit == 0x0d;
    if ((unit < 0x20 && !(allowBreaks && isBreak)) || unit == 0x7f) return unit;
  }
  return null;
}

String _controlProblem(int unit) =>
    'holds a control character (U+${unit.toRadixString(16).toUpperCase().padLeft(4, '0')})';

/// A key exactly as the source wrote it: never trimmed or folded, because a key is an identity and
/// the app matches books and chapters by it (§4.4).
String readKey(Object? value, String path) {
  if (value is! String) {
    rejectAt(path, 'expected a string, got ${describe(value)}');
  }
  if (value.isEmpty) rejectAt(path, 'is empty; a key is 1 to 512 characters');
  if (value.length > SourceLimits.maxKeyLength) {
    rejectAt(
      path,
      'longer than ${grouped(SourceLimits.maxKeyLength)} characters',
    );
  }
  final control = _controlIn(value, allowBreaks: false);
  if (control != null) rejectAt(path, _controlProblem(control));
  return value;
}

/// Text as the app will store and show it, or null when the source gave nothing but whitespace.
///
/// Short text is one line: tabs and line breaks fold into spaces. A description keeps its line
/// breaks, with `\r\n` and `\r` written as `\n`. Both are trimmed, and any other control character
/// fails the call.
String? readText(
  Object? value,
  String path, {
  int max = SourceLimits.maxShortTextLength,
  bool multiline = false,
}) {
  if (value is! String) {
    rejectAt(path, 'expected a string, got ${describe(value)}');
  }
  final control = _controlIn(value, allowBreaks: true);
  if (control != null) rejectAt(path, _controlProblem(control));
  final folded = multiline
      ? value.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
      : value.replaceAll(_breaks, ' ');
  final text = folded.trim();
  if (text.isEmpty) return null;
  if (text.length > max) {
    rejectAt(path, 'longer than ${grouped(max)} characters');
  }
  return text;
}

final _breaks = RegExp(r'[\t\n\r]+');

/// Text the source must give: [readText], refusing an empty result.
String readRequiredText(
  Object? value,
  String path, {
  int max = SourceLimits.maxShortTextLength,
  bool multiline = false,
}) =>
    readText(value, path, max: max, multiline: multiline) ??
    rejectAt(path, 'is empty');

/// A string kept byte for byte, such as a request body: not folded, not trimmed.
String readRawText(Object? value, String path) {
  if (value is! String) {
    rejectAt(path, 'expected a string, got ${describe(value)}');
  }
  return value;
}

bool readFlag(Object? value, String path) {
  if (value is! bool) {
    rejectAt(path, 'expected true or false, got ${describe(value)}');
  }
  return value;
}

/// A whole number, as every number in the contract is except `series.index`.
///
/// JavaScript has one number type, so a whole number arrives as a double as readily as an int. An
/// integral double is read; a fraction, a NaN, an infinity, or a number too large for JavaScript to
/// hold exactly is refused, because none of them can mean what the field means.
int readWholeNumber(
  Object? value,
  String path, {
  int min = 0,
  int max = SourceLimits.maxSafeInteger,
  String? outOfRange,
}) {
  final int number;
  if (value is int) {
    number = value;
  } else if (value is double) {
    if (value.isNaN) rejectAt(path, 'is not a number (NaN)');
    if (value.isInfinite) rejectAt(path, 'is not a finite number');
    if (value != value.truncateToDouble()) {
      rejectAt(path, 'is not a whole number: $value');
    }
    if (value.abs() > SourceLimits.maxSafeInteger) {
      rejectAt(path, _unsafe);
    }
    number = value.toInt();
  } else {
    rejectAt(path, 'expected a number, got ${describe(value)}');
  }
  if (number.abs() > SourceLimits.maxSafeInteger) rejectAt(path, _unsafe);
  if (number < min || number > max) {
    rejectAt(
      path,
      outOfRange ??
          (number < 0 && min == 0
              ? 'is negative: $number'
              : 'is outside $min to ${grouped(max)}: $number'),
    );
  }
  return number;
}

const _unsafe =
    'is outside the whole numbers JavaScript holds exactly (±9,007,199,254,740,991)';

/// A duration, size or bitrate. Zero is read as "not known", which is what a source that has no
/// figure for it usually means by it.
int? readAmount(Object? value, String path) {
  final amount = readWholeNumber(value, path);
  return amount == 0 ? null : amount;
}

/// A time in epoch milliseconds, as UTC.
DateTime readTime(Object? value, String path) =>
    DateTime.fromMillisecondsSinceEpoch(
      readWholeNumber(
        value,
        path,
        min: -SourceLimits.maxTimeMs,
        max: SourceLimits.maxTimeMs,
        outOfRange: 'is not a time in epoch milliseconds',
      ),
      isUtc: true,
    );

/// A number that need not be whole, such as a series index.
double readNumber(Object? value, String path, {double min = 0}) {
  if (value is! num) {
    rejectAt(path, 'expected a number, got ${describe(value)}');
  }
  final number = value.toDouble();
  if (number.isNaN) rejectAt(path, 'is not a number (NaN)');
  if (number.isInfinite) rejectAt(path, 'is not a finite number');
  if (number < min) rejectAt(path, 'is less than $min: $number');
  return number;
}

/// An array of at most [max] elements, which [what] names for the message.
List<Object?> readArray(
  Object? value,
  String path, {
  required String what,
  int? max,
}) {
  if (value is! List) {
    rejectAt(path, 'expected an array, got ${describe(value)}');
  }
  if (max != null && value.length > max) {
    rejectAt(
      path,
      'holds ${grouped(value.length)} $what; at most ${grouped(max)} are allowed',
    );
  }
  return value;
}

/// The fields of one plain-data object, and the path that leads to it.
final class Fields {
  const Fields._(this.map, this.path);

  /// Reads [value] as an object. Fails the call when it is anything else.
  factory Fields.of(Object? value, String path) {
    if (value is! Map) {
      rejectAt(path, 'expected an object, got ${describe(value)}');
    }
    return Fields._(value, path);
  }

  final Map<Object?, Object?> map;
  final String path;

  /// The path a message uses for the field [name] of this object.
  String pathOf(String name) => path.isEmpty ? name : '$path.$name';

  /// The raw value of [name]. Null when the field is absent, `undefined` or null: the contract
  /// treats all three as absent, because `undefined` reaches Dart as null.
  Object? operator [](String name) => map[name];

  String key(String name) => readKey(_required(name), pathOf(name));

  String? optionalKey(String name) {
    final value = map[name];
    return value == null ? null : readKey(value, pathOf(name));
  }

  String text(
    String name, {
    int max = SourceLimits.maxShortTextLength,
    bool multiline = false,
  }) => readRequiredText(
    _required(name),
    pathOf(name),
    max: max,
    multiline: multiline,
  );

  String? optionalText(
    String name, {
    int max = SourceLimits.maxShortTextLength,
    bool multiline = false,
  }) {
    final value = map[name];
    return value == null
        ? null
        : readText(value, pathOf(name), max: max, multiline: multiline);
  }

  String? optionalRawText(String name) {
    final value = map[name];
    return value == null ? null : readRawText(value, pathOf(name));
  }

  bool flag(String name) => readFlag(_required(name), pathOf(name));

  bool? optionalFlag(String name) {
    final value = map[name];
    return value == null ? null : readFlag(value, pathOf(name));
  }

  int? optionalAmount(String name) {
    final value = map[name];
    return value == null ? null : readAmount(value, pathOf(name));
  }

  int wholeNumber(
    String name, {
    int min = 0,
    int max = SourceLimits.maxSafeInteger,
  }) => readWholeNumber(_required(name), pathOf(name), min: min, max: max);

  int? optionalWholeNumber(String name, {int min = 0}) {
    final value = map[name];
    return value == null
        ? null
        : readWholeNumber(value, pathOf(name), min: min);
  }

  DateTime? optionalTime(String name) {
    final value = map[name];
    return value == null ? null : readTime(value, pathOf(name));
  }

  double? optionalNumber(String name, {double min = 0}) {
    final value = map[name];
    return value == null ? null : readNumber(value, pathOf(name), min: min);
  }

  /// The name of an enumerated value, such as a filter kind or a status, exactly as written.
  String? optionalName(String name) {
    final value = map[name];
    if (value == null) return null;
    if (value is! String) {
      rejectAt(pathOf(name), 'expected a string, got ${describe(value)}');
    }
    return value;
  }

  String name(String field) =>
      optionalName(field) ?? rejectAt(pathOf(field), _missing);

  List<Object?> array(String name, {required String what, int? max}) =>
      readArray(_required(name), pathOf(name), what: what, max: max);

  List<Object?> optionalArray(String name, {required String what, int? max}) {
    final value = map[name];
    return value == null
        ? const []
        : readArray(value, pathOf(name), what: what, max: max);
  }

  /// A list of names, such as authors or genres. An entry that is nothing but whitespace is left
  /// out, the way text that is nothing but whitespace is absent.
  List<String> textList(String name, {required bool required}) {
    final value = map[name];
    if (value == null) {
      if (required) rejectAt(pathOf(name), _missing);
      return const [];
    }
    final items = readArray(
      value,
      pathOf(name),
      what: 'names',
      max: SourceLimits.maxNames,
    );
    return [
      for (var i = 0; i < items.length; i++)
        ?readText(items[i], '${pathOf(name)}[$i]'),
    ];
  }

  Fields? optionalObject(String name) {
    final value = map[name];
    return value == null ? null : Fields.of(value, pathOf(name));
  }

  Object? _required(String name) =>
      map[name] ?? rejectAt(pathOf(name), _missing);

  static const _missing = 'is missing; the contract requires it';
}
