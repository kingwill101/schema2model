import 'dart:convert';
import 'dart:io';

import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  group('reference resolution', () {
    test('resolves relative file references via additional documents', () {
      final schemaFile = File('test/fixtures/references/order.schema.json');
      final schema =
          jsonDecode(schemaFile.readAsStringSync()) as Map<String, dynamic>;
      final generator = SchemaGenerator(
        options: SchemaGeneratorOptions(sourcePath: schemaFile.path),
      );

      final generated = generator.generate(schema);

      expect(generated, contains('class Order {'));
      expect(generated, contains('final Address? billingAddress;'));
      expect(generated, contains('class Address {'));
      expect(generated, contains('required this.shippingAddress,'));
    });

    test('supports relative JSON pointers', () {
      final schemaFile = File('test/fixtures/references/relative.schema.json');
      final schema =
          jsonDecode(schemaFile.readAsStringSync()) as Map<String, dynamic>;
      final generator = SchemaGenerator(
        options: SchemaGeneratorOptions(sourcePath: schemaFile.path),
      );

      final ir = generator.buildIr(schema);
      final wrapper = ir.rootClass;
      final valueProperty = wrapper.properties.firstWhere(
        (property) => property.jsonName == 'value',
      );
      final valueType = valueProperty.typeRef as ObjectTypeRef;
      final valueClass = valueType.spec;
      final aliasProperty = valueClass.properties.firstWhere(
        (property) => property.jsonName == 'alias',
      );

      expect(aliasProperty.dartType, equals('String?'));
      expect(valueClass.properties.map((p) => p.dartType), contains('String'));
    });

    test('collects definitions and conditional keywords', () {
      final schemaFile = File('example/schemas/github_action/schema.json');
      final schema =
          jsonDecode(schemaFile.readAsStringSync()) as Map<String, dynamic>;
      final generator = SchemaGenerator(
        options: SchemaGeneratorOptions(sourcePath: schemaFile.path),
      );

      final ir = generator.buildIr(schema);

      expect(
        ir.classes.map((c) => c.name),
        containsAll(<String>['RunsJavascript', 'RunsComposite', 'RootSchema']),
      );

      final rootClass = ir.rootClass;
      final propertyNames = rootClass.properties
          .map((property) => property.jsonName)
          .toSet();
      expect(propertyNames, containsAll(<String>['name', 'runs', 'inputs']));
    });
  });
}
