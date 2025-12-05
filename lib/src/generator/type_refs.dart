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

class ObjectTypeRef extends TypeRef {
  const ObjectTypeRef(this.spec);

  final IrClass spec;

  @override
  String dartType({bool nullable = false}) =>
      nullable ? '${spec.name}?' : spec.name;

  @override
  String deserializeInline(String sourceExpression, {required bool required}) {
    final mapCast = '($sourceExpression as Map).cast<String, dynamic>()';
    if (required) {
      return '${spec.name}.fromJson($mapCast)';
    }
    return '$sourceExpression == null ? null : ${spec.name}.fromJson($mapCast)';
  }

  @override
  String serializeInline(String valueExpression, {required bool required}) {
    if (required) {
      return '$valueExpression.toJson()';
    }
    return '$valueExpression?.toJson()';
  }

  @override
  bool get requiresConversionOnSerialize => true;

  @override
  String get identity => 'object:${spec.name}';
}

class EnumTypeRef extends TypeRef {
  const EnumTypeRef(this.spec);

  final IrEnum spec;

  @override
  String dartType({bool nullable = false}) =>
      nullable ? '${spec.name}?' : spec.name;

  @override
  String deserializeInline(String sourceExpression, {required bool required}) {
    final invocation =
        '${spec.extensionName}.fromJson($sourceExpression as String)';
    if (required) {
      return invocation;
    }
    return '$sourceExpression == null ? null : $invocation';
  }

  @override
  String serializeInline(String valueExpression, {required bool required}) {
    if (required) {
      return '$valueExpression.toJson()';
    }
    return '$valueExpression?.toJson()';
  }

  @override
  bool get requiresConversionOnSerialize => true;

  @override
  String get identity => 'enum:${spec.name}';
}

class MixedEnumTypeRef extends TypeRef {
  const MixedEnumTypeRef(this.spec);

  final IrMixedEnum spec;

  @override
  String dartType({bool nullable = false}) =>
      nullable ? '${spec.name}?' : spec.name;

  @override
  String deserializeInline(String sourceExpression, {required bool required}) {
    final invocation = '${spec.name}.fromJson($sourceExpression)';
    if (required) {
      return invocation;
    }
    return '$sourceExpression == null ? null : $invocation';
  }

  @override
  String serializeInline(String valueExpression, {required bool required}) {
    if (required) {
      return '$valueExpression.toJson()';
    }
    return '$valueExpression?.toJson()';
  }

  @override
  bool get requiresConversionOnSerialize => true;

  @override
  String get identity => 'mixedenum:${spec.name}';
}

class ListTypeRef extends TypeRef {
  const ListTypeRef({
    required this.itemType,
    this.prefixItemTypes = const <TypeRef>[],
    this.containsType,
    this.minContains,
    this.maxContains,
    this.unevaluatedItemsType,
    this.disallowUnevaluatedItems = false,
    this.allowAdditionalItems = true,
    this.itemsEvaluatesAdditionalItems = false,
  });

  final TypeRef itemType;
  final List<TypeRef> prefixItemTypes;
  final TypeRef? containsType;
  final int? minContains;
  final int? maxContains;
  final TypeRef? unevaluatedItemsType;
  final bool disallowUnevaluatedItems;
  final bool allowAdditionalItems;
  final bool itemsEvaluatesAdditionalItems;

  @override
  String dartType({bool nullable = false}) {
    final suffix = nullable ? '?' : '';
    return 'List<${itemType.dartType()}>$suffix';
  }

  @override
  String deserializeInline(String sourceExpression, {required bool required}) {
    final mapper = itemType.deserializeInline('e', required: true);
    if (required) {
      return '($sourceExpression as List).map((e) => $mapper).toList()';
    }
    return '$sourceExpression == null ? null : ($sourceExpression as List).map((e) => $mapper).toList()';
  }

  @override
  String serializeInline(String valueExpression, {required bool required}) {
    if (!itemType.requiresConversionOnSerialize) {
      return valueExpression;
    }
    final mapper = itemType.serializeInline('e', required: true);
    if (required) {
      return '$valueExpression.map((e) => $mapper).toList()';
    }
    return '$valueExpression == null ? null : $valueExpression!.map((e) => $mapper).toList()';
  }

  @override
  bool get requiresConversionOnSerialize =>
      itemType.requiresConversionOnSerialize;

  @override
  bool get isList => true;

  @override
  String get identity {
    final buffer = StringBuffer('list:${itemType.identity}');
    if (prefixItemTypes.isNotEmpty) {
      buffer.write(':prefix[');
      buffer.write(
        prefixItemTypes.map((type) => type.identity).join(','),
      );
      buffer.write(']');
    }
    if (containsType != null) {
      buffer.write(':contains=${containsType!.identity}');
    }
    if (minContains != null) {
      buffer.write(':minContains=$minContains');
    }
    if (maxContains != null) {
      buffer.write(':maxContains=$maxContains');
    }
    if (unevaluatedItemsType != null) {
      buffer.write(':unevaluated=${unevaluatedItemsType!.identity}');
    }
    if (disallowUnevaluatedItems) {
      buffer.write(':disallowUnevaluated');
    }
    if (!allowAdditionalItems) {
      buffer.write(':noAdditional');
    }
    if (itemsEvaluatesAdditionalItems) {
      buffer.write(':itemsEvaluates');
    }
    return buffer.toString();
  }
}

class FormatTypeRef extends TypeRef {
  const FormatTypeRef({
    required this.format,
    required this.typeName,
    required String Function(String source) deserialize,
    required String Function(String value) serialize,
    this.helperTypeName,
  }) : _deserialize = deserialize,
       _serialize = serialize;

  final String format;
  final String typeName;
  final String? helperTypeName;
  final String Function(String source) _deserialize;
  final String Function(String value) _serialize;

  @override
  String dartType({bool nullable = false}) =>
      nullable ? '$typeName?' : typeName;

  @override
  String deserializeInline(String sourceExpression, {required bool required}) {
    final casted = '($sourceExpression as String)';
    final parsed = _deserialize(casted);
    if (required) {
      return parsed;
    }
    return '$sourceExpression == null ? null : ${_deserialize('($sourceExpression as String)')}';
  }

  @override
  String serializeInline(String valueExpression, {required bool required}) {
    return _serialize(valueExpression);
  }

  @override
  bool get requiresConversionOnSerialize => true;

  @override
  String get identity => 'format:$format:$typeName';
}
