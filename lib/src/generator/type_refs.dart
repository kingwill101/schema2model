part of 'package:schemamodeschema/src/generator.dart';

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

class ListTypeRef extends TypeRef {
  const ListTypeRef(this.itemType);

  final TypeRef itemType;

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
  String get identity => 'list:${itemType.identity}';
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
