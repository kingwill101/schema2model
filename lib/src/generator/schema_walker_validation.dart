part of 'package:schema2model/src/generator.dart';

const IrHelper _validationHelper = IrHelper(
  name: 'ValidationError',
  code: '''
import 'dart:convert';

String appendJsonPointer(String pointer, String token) {
  final escaped = token.replaceAll('~', '~0').replaceAll('/', '~1');
  if (pointer.isEmpty) return '/' + escaped;
  return pointer + '/' + escaped;
}

String uniqueItemKey(Object? value) => jsonEncode(value);

Never throwValidationError(String pointer, String keyword, String message) =>
    throw ValidationError(pointer: pointer, keyword: keyword, message: message);

class ValidationAnnotation {
  const ValidationAnnotation({
    required this.keyword,
    required this.value,
    this.schemaPointer,
  });

  final String keyword;
  final Object? value;
  final String? schemaPointer;
}

class ValidationContext {
  ValidationContext();

  final Map<String, List<ValidationAnnotation>> annotations = <String, List<ValidationAnnotation>>{};
  final Map<String, Set<String>> evaluatedProperties = <String, Set<String>>{};
  final Map<String, Set<int>> evaluatedItems = <String, Set<int>>{};

  void annotate(
    String pointer,
    String keyword,
    Object? value, {
    String? schemaPointer,
  }) {
    final list = annotations.putIfAbsent(pointer, () => <ValidationAnnotation>[]);
    list.add(
      ValidationAnnotation(
        keyword: keyword,
        value: value,
        schemaPointer: schemaPointer,
      ),
    );
  }

  void markProperty(String pointer, String property) {
    evaluatedProperties.putIfAbsent(pointer, () => <String>{}).add(property);
  }

  void markItem(String pointer, int index) {
    evaluatedItems.putIfAbsent(pointer, () => <int>{}).add(index);
  }

  void mergeFrom(ValidationContext other) {
    for (final entry in other.annotations.entries) {
      final list = annotations.putIfAbsent(entry.key, () => <ValidationAnnotation>[]);
      list.addAll(entry.value);
    }
    for (final entry in other.evaluatedProperties.entries) {
      evaluatedProperties.putIfAbsent(entry.key, () => <String>{}).addAll(entry.value);
    }
    for (final entry in other.evaluatedItems.entries) {
      evaluatedItems.putIfAbsent(entry.key, () => <int>{}).addAll(entry.value);
    }
  }
}

class ValidationError implements Exception {
  ValidationError({
    required this.pointer,
    required this.keyword,
    required this.message,
  });

  final String pointer;
  final String keyword;
  final String message;

  @override
  String toString() => 'ValidationError(' + keyword + ' @ ' + pointer + ': ' + message + ')';
}

bool isValidFormat(String format, String value) {
  switch (format) {
    case 'date-time':
      return _dateTimePattern.hasMatch(value);
    case 'date':
      return _datePattern.hasMatch(value);
    case 'time':
      return _timePattern.hasMatch(value);
    case 'duration':
      return _durationPattern.hasMatch(value);
    case 'email':
    case 'idn-email':
      return _emailPattern.hasMatch(value);
    case 'hostname':
    case 'idn-hostname':
      return _isHostname(value);
    case 'ipv4':
      return _ipv4Pattern.hasMatch(value);
    case 'ipv6':
      return _isIpv6(value);
    case 'uri':
      return _isUri(value, requireScheme: true);
    case 'uri-reference':
      return _isUri(value, requireScheme: false);
    case 'iri':
      return _isIri(value, requireScheme: true);
    case 'iri-reference':
      return _isIri(value, requireScheme: false);
    case 'uri-template':
      return _isUriTemplate(value);
    case 'json-pointer':
      return _isJsonPointer(value);
    case 'relative-json-pointer':
      return _isRelativeJsonPointer(value);
    case 'regex':
      return _isValidRegex(value);
    default:
      return true;
  }
}

final RegExp _dateTimePattern = RegExp(
  r'^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})\$',
);
final RegExp _datePattern = RegExp(r'^\\d{4}-\\d{2}-\\d{2}\$');
final RegExp _timePattern = RegExp(
  r'^\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})?\$',
);
final RegExp _durationPattern = RegExp(
  r'^P(?!\$)(?:\\d+Y)?(?:\\d+M)?(?:\\d+W)?(?:\\d+D)?(?:T(?:\\d+H)?(?:\\d+M)?(?:\\d+(?:\\.\\d+)?S)?)?\$',
);
final RegExp _emailPattern =
    RegExp(r'^[^\\s@]+@[^\\s@]+\\.[^\\s@]+\$');
final RegExp _ipv4Pattern = RegExp(
  r'^(25[0-5]|2[0-4]\\d|1?\\d?\\d)(\\.(25[0-5]|2[0-4]\\d|1?\\d?\\d)){3}\$',
);

bool _isIpv6(String value) {
  if (!RegExp(r'^[0-9A-Fa-f:]+\$').hasMatch(value)) {
    return false;
  }
  final parts = value.split(':');
  if (parts.length < 3 || parts.length > 8) {
    return false;
  }
  for (final part in parts) {
    if (part.isEmpty) {
      continue;
    }
    if (part.length > 4) {
      return false;
    }
  }
  return true;
}

bool _isUri(String value, {required bool requireScheme}) {
  final uri = Uri.tryParse(value);
  if (uri == null) {
    return false;
  }
  if (requireScheme && !uri.hasScheme) {
    return false;
  }
  return true;
}

bool _isIri(String value, {required bool requireScheme}) {
  return _isUri(value, requireScheme: requireScheme);
}

bool _isUriTemplate(String value) {
  if (value.contains(RegExp(r'\\s'))) {
    return false;
  }
  var depth = 0;
  for (final rune in value.runes) {
    if (rune == 123) {
      depth++;
    } else if (rune == 125) {
      depth--;
      if (depth < 0) {
        return false;
      }
    }
  }
  return depth == 0;
}

bool _isHostname(String value) {
  if (value.isEmpty || value.length > 253) {
    return false;
  }
  final labels = value.split('.');
  final labelPattern = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\$');
  for (final label in labels) {
    if (label.isEmpty || label.length > 63) {
      return false;
    }
    if (!labelPattern.hasMatch(label)) {
      return false;
    }
  }
  return true;
}

bool _isJsonPointer(String value) {
  if (value.isEmpty) {
    return true;
  }
  if (!value.startsWith('/')) {
    return false;
  }
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) == 126) {
      if (i + 1 >= value.length) {
        return false;
      }
      final next = value.codeUnitAt(i + 1);
      if (next != 48 && next != 49) {
        return false;
      }
      i++;
    }
  }
  return true;
}

bool _isRelativeJsonPointer(String value) {
  final match = RegExp(r'^(0|[1-9]\\d*)(.*)\$').firstMatch(value);
  if (match == null) {
    return false;
  }
  final suffix = match.group(2)!;
  if (suffix.isEmpty || suffix == '#') {
    return true;
  }
  if (suffix.startsWith('/')) {
    return _isJsonPointer(suffix);
  }
  return false;
}

bool _isValidRegex(String value) {
  try {
    RegExp(value);
    return true;
  } catch (_) {
    return false;
  }
}
''',
);
String _elementClassName(String base) {
  // Use the improved singularize function
  final singularized = _SchemaWalker._singularize(base);
  
  // Only add 'Item' suffix if singularization didn't change the word
  // (meaning it wasn't a plural form)
  if (singularized == base) {
    return '${base}Item';
  }
  
  return singularized;
}
