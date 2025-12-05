part of 'package:schema2model/src/generator.dart';

/// Utility helpers for transforming schema identifiers into Dart-friendly names.
class _Naming {
  static String className(String input) {
    final sanitized = _sanitize(input, upperInitial: true);
    return sanitized.isEmpty ? 'Generated' : sanitized;
  }

  static String fieldName(String input) {
    final sanitized = _sanitize(input, upperInitial: false);
    final result = sanitized.isEmpty ? 'value' : sanitized;
    if (_reservedWords.contains(result)) {
      return '${result}_';
    }
    return result;
  }

  static String identifier(String input) {
    final sanitized = _sanitize(
      input,
      upperInitial: false,
      allowUnderscore: true,
    );
    final result = sanitized.isEmpty ? 'value' : sanitized;
    if (_reservedWords.contains(result)) {
      return '${result}_';
    }
    return result;
  }

  static String enumValue(String input) {
    final sanitized = _sanitize(
      input,
      upperInitial: false,
    );
    final result = sanitized.isEmpty ? 'value' : sanitized;
    if (_reservedWords.contains(result)) {
      return '${result}_';
    }
    return result;
  }

  static String fileNameFromType(String name) {
    final snake = name
        .replaceAllMapped(
          RegExp('([a-z0-9])([A-Z])'),
          (match) => '${match[1]}_${match[2]}',
        )
        .replaceAllMapped(
          RegExp('([A-Z])([A-Z][a-z])'),
          (match) => '${match[1]}_${match[2]}',
        )
        .toLowerCase();
    return snake.replaceAll(RegExp(r'__+'), '_');
  }

  static String _sanitize(
    String input, {
    required bool upperInitial,
    bool allowUnderscore = false,
  }) {
    if (input.trim().isEmpty) {
      return '';
    }

    final camelBreak = RegExp(r'([a-z0-9])([A-Z])');
    final normalized = input
        .replaceAllMapped(camelBreak, (match) => '${match[1]} ${match[2]}')
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), ' ')
        .trim();

    if (normalized.isEmpty) {
      return '';
    }

    final tokens = normalized
        .split(RegExp(r'\s+'))
        .map((token) => token.toLowerCase())
        .where((token) => token.isNotEmpty)
        .toList();

    if (tokens.isEmpty) {
      return '';
    }

    if (allowUnderscore) {
      final withUnderscore = tokens.join('_');
      if (withUnderscore.isEmpty) {
        return '';
      }
      final first = withUnderscore[0];
      if (!_isAlphabetic(first) && first != '_') {
        return '_$withUnderscore';
      }
      return withUnderscore;
    }

    final buffer = StringBuffer();
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (i == 0 && !upperInitial) {
        buffer.write(token);
      } else {
        buffer.write(token[0].toUpperCase());
        buffer.write(token.substring(1));
      }
    }

    if (buffer.isEmpty) {
      return '';
    }

    final result = buffer.toString();
    final firstChar = result[0];
    if (!_isAlphabetic(firstChar)) {
      return '${upperInitial ? 'Class' : '_'}$result';
    }
    return result;
  }

  static bool _isAlphabetic(String char) {
    final code = char.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }

  static const Set<String> _reservedWords = {
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'Function',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'of',
    'on',
    'operator',
    'part',
    'required',
    'rethrow',
    'return',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'while',
    'with',
    'yield',
  };
}
