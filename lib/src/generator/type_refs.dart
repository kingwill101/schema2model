part of 'package:schema2model/src/generator.dart';

abstract class TypeRef {
  const TypeRef();

  String dartType({bool nullable = false});

  String deserializeInline(String sourceExpression, {required bool required});

  String serializeInline(String valueExpression, {required bool required});

  bool get requiresConversionOnSerialize;

  bool get isList => false;

  String get identity;
}

class PrimitiveTypeRef extends TypeRef {
  const PrimitiveTypeRef(this.typeName);

  final String typeName;

  @override
  String dartType({bool nullable = false}) =>
      nullable ? '$typeName?' : typeName;

  @override
  String deserializeInline(String sourceExpression, {required bool required}) {
    final castType = required ? typeName : '$typeName?';
    return '$sourceExpression as $castType';
  }

  @override
  String serializeInline(String valueExpression, {required bool required}) =>
      valueExpression;

  @override
  bool get requiresConversionOnSerialize => false;

  @override
  String get identity => 'primitive:$typeName';
}

class DynamicTypeRef extends PrimitiveTypeRef {
  const DynamicTypeRef() : super('dynamic');

  @override
  String dartType({bool nullable = false}) => 'dynamic';

  @override
  String deserializeInline(String sourceExpression, {required bool required}) =>
      sourceExpression;

  @override
  String get identity => 'dynamic';
}

/// Type reference for encoded binary content (Uint8List).
/// Supports: base64, base16, base32, quoted-printable
class ContentEncodedTypeRef extends TypeRef {
  const ContentEncodedTypeRef(this.encoding);

  final String encoding;

  @override
  String dartType({bool nullable = false}) =>
      nullable ? 'Uint8List?' : 'Uint8List';

  String _decoderFunction() {
    switch (encoding) {
      case 'base64':
        return 'base64Decode';
      case 'base16':
        return '_base16Decode';
      case 'base32':
        return '_base32Decode';
      case 'quoted-printable':
        return '_quotedPrintableDecode';
      default:
        return 'base64Decode'; // fallback
    }
  }

  String _encoderFunction() {
    switch (encoding) {
      case 'base64':
        return 'base64Encode';
      case 'base16':
        return '_base16Encode';
      case 'base32':
        return '_base32Encode';
      case 'quoted-printable':
        return '_quotedPrintableEncode';
      default:
        return 'base64Encode'; // fallback
    }
  }

  @override
  String deserializeInline(String sourceExpression, {required bool required}) {
    final decoder = _decoderFunction();
    if (required) {
      return '$decoder($sourceExpression as String)';
    }
    return '$sourceExpression != null ? $decoder($sourceExpression as String) : null';
  }

  @override
  String serializeInline(String valueExpression, {required bool required}) =>
      '${_encoderFunction()}($valueExpression)';

  @override
  bool get requiresConversionOnSerialize => true;

  @override
  String get identity => 'encoded:$encoding';
}

/// Legacy alias for backward compatibility
class Base64TypeRef extends ContentEncodedTypeRef {
  const Base64TypeRef() : super('base64');
}

class FalseTypeRef extends TypeRef {
  const FalseTypeRef();

  @override
  String dartType({bool nullable = false}) => nullable ? 'Object?' : 'Object?';

  @override
  String deserializeInline(
    String sourceExpression, {
    required bool required,
  }) =>
      sourceExpression;

  @override
  String serializeInline(String valueExpression, {required bool required}) =>
      valueExpression;

  @override
  bool get requiresConversionOnSerialize => false;

  @override
  String get identity => 'false';
}

class ValidatedTypeRef extends TypeRef {
  const ValidatedTypeRef(this.inner, this.validation);

  final TypeRef inner;
  final PropertyValidationRules validation;

  @override
  String dartType({bool nullable = false}) =>
      inner.dartType(nullable: nullable);

  @override
  String deserializeInline(String sourceExpression, {required bool required}) =>
      inner.deserializeInline(sourceExpression, required: required);

  @override
  String serializeInline(String valueExpression, {required bool required}) =>
      inner.serializeInline(valueExpression, required: required);

  @override
  bool get requiresConversionOnSerialize => inner.requiresConversionOnSerialize;

  @override
  bool get isList => inner.isList;

  @override
  String get identity => 'validated:${inner.identity}:${_rulesIdentity(validation)}';

  static String _rulesIdentity(PropertyValidationRules rules) {
    final parts = <String>[];
    if (rules.minLength != null) parts.add('minLength=${rules.minLength}');
    if (rules.maxLength != null) parts.add('maxLength=${rules.maxLength}');
    if (rules.minimum != null) {
      parts.add(
        rules.exclusiveMinimum
            ? 'exclusiveMinimum=${rules.minimum}'
            : 'minimum=${rules.minimum}',
      );
    }
    if (rules.maximum != null) {
      parts.add(
        rules.exclusiveMaximum
            ? 'exclusiveMaximum=${rules.maximum}'
            : 'maximum=${rules.maximum}',
      );
    }
    if (rules.pattern != null) parts.add('pattern=${rules.pattern}');
    if (rules.constValue != null) parts.add('const=${rules.constValue}');
    if (rules.allowedTypes != null && rules.allowedTypes!.isNotEmpty) {
      parts.add('types=${rules.allowedTypes!.join('|')}');
    }
    if (rules.format != null) {
      parts.add('format=${rules.format}');
    }
    if (rules.multipleOf != null) parts.add('multipleOf=${rules.multipleOf}');
    if (rules.minItems != null) parts.add('minItems=${rules.minItems}');
    if (rules.maxItems != null) parts.add('maxItems=${rules.maxItems}');
    if (rules.uniqueItems != null) parts.add('uniqueItems=${rules.uniqueItems}');
    if (rules.minProperties != null) {
      parts.add('minProperties=${rules.minProperties}');
    }
    if (rules.maxProperties != null) {
      parts.add('maxProperties=${rules.maxProperties}');
    }
    return parts.join(',');
  }
}

class ApplicatorTypeRef extends TypeRef {
  const ApplicatorTypeRef(this.inner, this.constraints);

  final TypeRef inner;
  final List<ApplicatorConstraint> constraints;

  @override
  String dartType({bool nullable = false}) =>
      inner.dartType(nullable: nullable);

  @override
  String deserializeInline(String sourceExpression, {required bool required}) =>
      inner.deserializeInline(sourceExpression, required: required);

  @override
  String serializeInline(String valueExpression, {required bool required}) =>
      inner.serializeInline(valueExpression, required: required);

  @override
  bool get requiresConversionOnSerialize => inner.requiresConversionOnSerialize;

  @override
  bool get isList => inner.isList;

  @override
  String get identity =>
      'applicator:${inner.identity}:${constraints.map((c) => c.keyword).join(',')}';
}
