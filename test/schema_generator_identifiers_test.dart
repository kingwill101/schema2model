import 'package:schemamodeschema/src/generator.dart';
import 'package:test/test.dart';

SchemaGenerator _createGenerator({
  SchemaDocumentLoader? documentLoader,
  Uri? baseUri,
}) {
  return SchemaGenerator(
    options: SchemaGeneratorOptions(
      sourcePath: 'memory://identifiers',
      documentLoader: documentLoader,
      baseUri: baseUri,
      onWarning: (_) {},
    ),
  );
}

void main() {
  group('identifier resolution', () {
    test('resolves local anchor references', () {
      final generator = _createGenerator(
        baseUri: Uri.parse('https://example.com/root'),
      );
      final schema = <String, dynamic>{
        r'$id': 'https://example.com/root',
        'type': 'object',
        'properties': <String, dynamic>{
          'step': <String, dynamic>{
            r'$anchor': 'step',
            'type': 'string',
          },
          'useAnchor': <String, dynamic>{r'$ref': '#step'},
        },
      };

      final ir = generator.buildIr(schema);
      final root = ir.rootClass;
      final step = root.properties.singleWhere((prop) => prop.fieldName == 'step');
      final useAnchor =
          root.properties.singleWhere((prop) => prop.fieldName == 'useAnchor');

      expect(step.typeRef, isA<PrimitiveTypeRef>());
      expect(useAnchor.typeRef, isA<PrimitiveTypeRef>());
      expect(
        (useAnchor.typeRef as PrimitiveTypeRef).identity,
        equals((step.typeRef as PrimitiveTypeRef).identity),
      );
    });

    test('resolves dynamicRef using dynamic scope stack', () {
      final generator = _createGenerator(
        baseUri: Uri.parse('https://example.com/root'),
      );
      final schema = <String, dynamic>{
        r'$id': 'https://example.com/root',
        'type': 'object',
        'properties': <String, dynamic>{
          'child': <String, dynamic>{
            r'$dynamicAnchor': 'node',
            'type': 'object',
            'properties': <String, dynamic>{
              'value': <String, dynamic>{'type': 'integer'},
            },
          },
          'useDynamic': <String, dynamic>{r'$dynamicRef': '#node'},
        },
      };

      final ir = generator.buildIr(schema);
      final root = ir.rootClass;
      final child =
          root.properties.singleWhere((prop) => prop.fieldName == 'child');
      final useDynamic =
          root.properties.singleWhere((prop) => prop.fieldName == 'useDynamic');

      expect(child.typeRef, isA<ObjectTypeRef>());
      expect(useDynamic.typeRef, isA<ObjectTypeRef>());
      expect(
        (useDynamic.typeRef as ObjectTypeRef).spec,
        same((child.typeRef as ObjectTypeRef).spec),
      );
    });

    test('fallbacks to pointer resolution when anchor missing', () {
      final generator = _createGenerator(
        baseUri: Uri.parse('https://example.com/root'),
      );
      final schema = <String, dynamic>{
        r'$id': 'https://example.com/root',
        'type': 'object',
        'properties': <String, dynamic>{
          'refObject': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'name': <String, dynamic>{'type': 'string'},
            },
          },
          'usePointer': <String, dynamic>{
            r'$ref': '#/properties/refObject',
          },
        },
      };

      final ir = generator.buildIr(schema);
      final root = ir.rootClass;
      final refObject =
          root.properties.singleWhere((prop) => prop.fieldName == 'refObject');
      final usePointer =
          root.properties.singleWhere((prop) => prop.fieldName == 'usePointer');

      expect(refObject.typeRef, isA<ObjectTypeRef>());
      expect(usePointer.typeRef, isA<ObjectTypeRef>());
      expect(
        (usePointer.typeRef as ObjectTypeRef).spec,
        same((refObject.typeRef as ObjectTypeRef).spec),
      );
    });

    test('resolves cross-document pointer references', () {
      final documents = <String, Map<String, dynamic>>{
        'https://example.com/root': <String, dynamic>{
          r'$id': 'https://example.com/root',
          'type': 'object',
          'properties': <String, dynamic>{
            'external': <String, dynamic>{
              r'$ref': 'https://example.com/external.json#/properties/name',
            },
          },
        },
        'https://example.com/external.json': <String, dynamic>{
          r'$id': 'https://example.com/external.json',
          'type': 'object',
          'properties': <String, dynamic>{
            'name': <String, dynamic>{'type': 'string'},
          },
        },
      };

      Map<String, dynamic> loader(Uri uri) {
        final key = uri.toString();
        final doc = documents[key];
        if (doc == null) {
          throw StateError('Unexpected URI $uri');
        }
        return doc;
      }

      final generator = _createGenerator(
        documentLoader: loader,
        baseUri: Uri.parse('https://example.com/root'),
      );

      final ir = generator.buildIr(documents['https://example.com/root']!);
      final root = ir.rootClass;
      final external =
          root.properties.singleWhere((prop) => prop.fieldName == 'external');

      expect(external.typeRef, isA<PrimitiveTypeRef>());
      expect((external.typeRef as PrimitiveTypeRef).typeName, 'String');
    });

    test('resolves cross-document dynamic references', () {
      final documents = <String, Map<String, dynamic>>{
        'https://example.com/root': <String, dynamic>{
          r'$id': 'https://example.com/root',
          'type': 'object',
          'properties': <String, dynamic>{
            'useDynamic': <String, dynamic>{
              r'$dynamicRef': 'https://example.com/external.json#node',
            },
          },
        },
        'https://example.com/external.json': <String, dynamic>{
          r'$id': 'https://example.com/external.json',
          r'$dynamicAnchor': 'node',
          'type': 'object',
          'properties': <String, dynamic>{
            'value': <String, dynamic>{'type': 'integer'},
          },
        },
      };

      Map<String, dynamic> loader(Uri uri) {
        final key = uri.toString();
        final doc = documents[key];
        if (doc == null) {
          throw StateError('Unexpected URI $uri');
        }
        return doc;
      }

      final generator = _createGenerator(
        documentLoader: loader,
        baseUri: Uri.parse('https://example.com/root'),
      );

      final ir = generator.buildIr(documents['https://example.com/root']!);
      final root = ir.rootClass;
      final useDynamic =
          root.properties.singleWhere((prop) => prop.fieldName == 'useDynamic');

      expect(useDynamic.typeRef, isA<ObjectTypeRef>());
      final spec = (useDynamic.typeRef as ObjectTypeRef).spec;
      expect(spec.properties.map((p) => p.fieldName), contains('value'));
    });

    test('throws on duplicate anchors', () {
      final generator = _createGenerator(
        baseUri: Uri.parse('https://example.com/root'),
      );
      final schema = <String, dynamic>{
        r'$id': 'https://example.com/root',
        'type': 'object',
        'properties': <String, dynamic>{
          'first': <String, dynamic>{
            r'$anchor': 'dup',
            'type': 'string',
          },
          'second': <String, dynamic>{
            r'$anchor': 'dup',
            'type': 'string',
          },
        },
      };

      expect(
        () => generator.buildIr(schema),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Duplicate "\$anchor" "dup"'),
          ),
        ),
      );
    });

    test('throws on empty anchor', () {
      final generator = _createGenerator(
        baseUri: Uri.parse('https://example.com/root'),
      );
      final schema = <String, dynamic>{
        r'$id': 'https://example.com/root',
        'type': 'object',
        'properties': <String, dynamic>{
          'bad': <String, dynamic>{
            r'$anchor': '',
            'type': 'string',
          },
        },
      };

      expect(
        () => generator.buildIr(schema),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('must be a non-empty string'),
          ),
        ),
      );
    });

    test('throws on duplicate ids', () {
      final generator = _createGenerator(
        baseUri: Uri.parse('https://example.com/root'),
      );
      final schema = <String, dynamic>{
        r'$id': 'https://example.com/root',
        'type': 'object',
        r'$defs': <String, dynamic>{
          'first': <String, dynamic>{
            r'$id': 'https://example.com/shared',
            'type': 'string',
          },
          'second': <String, dynamic>{
            r'$id': 'https://example.com/shared',
            'type': 'string',
          },
        },
      };

      expect(
        () => generator.buildIr(schema),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Duplicate "\$id" "https://example.com/shared"'),
          ),
        ),
      );
    });

    test('throws when id includes fragment', () {
      final generator = _createGenerator(
        baseUri: Uri.parse('https://example.com/root'),
      );
      final schema = <String, dynamic>{
        r'$id': 'https://example.com/root#fragment',
        'type': 'object',
      };

      expect(
        () => generator.buildIr(schema),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('must not include a fragment'),
          ),
        ),
      );
    });

    test('throws on empty dynamicAnchor', () {
      final generator = _createGenerator(
        baseUri: Uri.parse('https://example.com/root'),
      );
      final schema = <String, dynamic>{
        r'$id': 'https://example.com/root',
        'type': 'object',
        'properties': <String, dynamic>{
          'bad': <String, dynamic>{
            r'$dynamicAnchor': '',
            'type': 'object',
          },
        },
      };

      expect(
        () => generator.buildIr(schema),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('must be a non-empty string'),
          ),
        ),
      );
    });
  });
}
