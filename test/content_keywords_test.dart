import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  group('Content keywords', () {
    test('base64 encoding generates Uint8List type', () {
      final schema = {
        'type': 'object',
        'properties': {
          'avatar': {
            'type': 'string',
            'contentMediaType': 'image/png',
            'contentEncoding': 'base64',
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'User',
          enableContentKeywords: true,
        ),
      );

      final ir = generator.buildIr(schema);
      final avatarProp = ir.rootClass.properties
          .firstWhere((p) => p.fieldName == 'avatar');

      // Check IR has content metadata
      expect(avatarProp.contentMediaType, 'image/png');
      expect(avatarProp.contentEncoding, 'base64');

      // Check type is ContentEncodedTypeRef (Uint8List)
      expect(avatarProp.typeRef, isA<ContentEncodedTypeRef>());
      expect((avatarProp.typeRef as ContentEncodedTypeRef).encoding, 'base64');
      expect(avatarProp.dartType, 'Uint8List?');
    });

    test('base64 encoding generates correct serialization code', () {
      final schema = {
        'type': 'object',
        'properties': {
          'data': {
            'type': 'string',
            'contentEncoding': 'base64',
          },
        },
        'required': ['data'],
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'BinaryData',
          enableContentKeywords: true,
        ),
      );

      final code = generator.generate(schema);

      // Should use Uint8List type
      expect(code, contains('final Uint8List data;'));

      // Should decode base64 in fromJson
      expect(code, contains('base64Decode'));

      // Should encode to base64 in toJson
      expect(code, contains('base64Encode'));

      // Should import dart:convert for base64
      expect(code, contains("import 'dart:convert';"));

      // Should import dart:typed_data for Uint8List
      expect(code, contains("import 'dart:typed_data';"));
    });

    test('disabled by default - backward compatibility', () {
      final schema = {
        'type': 'object',
        'properties': {
          'data': {
            'type': 'string',
            'contentEncoding': 'base64',
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'Data',
          // enableContentKeywords: false (default)
        ),
      );

      final ir = generator.buildIr(schema);
      final dataProp = ir.rootClass.properties
          .firstWhere((p) => p.fieldName == 'data');

      // Should NOT extract content keywords when disabled
      expect(dataProp.contentEncoding, isNull);

      // Should remain String type
      expect(dataProp.typeRef, isA<PrimitiveTypeRef>());
      expect(dataProp.dartType, 'String?');
    });

    test('content without encoding stays as String', () {
      final schema = {
        'type': 'object',
        'properties': {
          'html': {
            'type': 'string',
            'contentMediaType': 'text/html',
            // No contentEncoding
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'Document',
          enableContentKeywords: true,
        ),
      );

      final ir = generator.buildIr(schema);
      final htmlProp = ir.rootClass.properties
          .firstWhere((p) => p.fieldName == 'html');

      // Should capture media type
      expect(htmlProp.contentMediaType, 'text/html');
      expect(htmlProp.contentEncoding, isNull);

      // Should remain String (no encoding)
      expect(htmlProp.typeRef, isA<PrimitiveTypeRef>());
      expect(htmlProp.dartType, 'String?');
    });

    test('contentSchema is captured in IR', () {
      final schema = {
        'type': 'object',
        'properties': {
          'metadata': {
            'type': 'string',
            'contentMediaType': 'application/json',
            'contentEncoding': 'base64',
            'contentSchema': {
              'type': 'object',
              'properties': {
                'version': {'type': 'string'},
              },
            },
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'Data',
          enableContentKeywords: true,
        ),
      );

      final ir = generator.buildIr(schema);
      final metadataProp = ir.rootClass.properties
          .firstWhere((p) => p.fieldName == 'metadata');

      // Should capture all content keywords
      expect(metadataProp.contentMediaType, 'application/json');
      expect(metadataProp.contentEncoding, 'base64');
      expect(metadataProp.contentSchema, isNotNull);
      expect(metadataProp.contentSchema!['type'], 'object');
    });

    test('nullable base64 property', () {
      final schema = {
        'type': 'object',
        'properties': {
          'optionalImage': {
            'type': 'string',
            'contentEncoding': 'base64',
          },
        },
        // optionalImage not in required
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'Media',
          enableContentKeywords: true,
        ),
      );

      final code = generator.generate(schema);

      // Should be nullable Uint8List
      expect(code, contains('final Uint8List? optionalImage;'));

      // Should handle null in deserialization
      expect(code, contains('!= null'));
    });

    test('required base64 property', () {
      final schema = {
        'type': 'object',
        'properties': {
          'requiredData': {
            'type': 'string',
            'contentEncoding': 'base64',
          },
        },
        'required': ['requiredData'],
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'Data',
          enableContentKeywords: true,
        ),
      );

      final code = generator.generate(schema);

      // Should be non-nullable Uint8List
      expect(code, contains('final Uint8List requiredData;'));

      // Constructor should require it
      expect(code, contains('required this.requiredData'));
    });

    test('base16 encoding generates Uint8List with helpers', () {
      final schema = {
        'type': 'object',
        'properties': {
          'hexData': {
            'type': 'string',
            'contentEncoding': 'base16',
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'HexData',
          enableContentKeywords: true,
        ),
      );

      final code = generator.generate(schema);

      // Should use Uint8List type
      expect(code, contains('final Uint8List? hexData;'));

      // Should use base16 helpers
      expect(code, contains('_base16Decode'));
      expect(code, contains('_base16Encode'));

      // Should include helper functions
      expect(code, contains('Uint8List _base16Decode(String input)'));
      expect(code, contains('String _base16Encode(Uint8List bytes)'));
    });

    test('base32 encoding generates Uint8List with helpers', () {
      final schema = {
        'type': 'object',
        'properties': {
          'b32Data': {
            'type': 'string',
            'contentEncoding': 'base32',
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'Base32Data',
          enableContentKeywords: true,
        ),
      );

      final code = generator.generate(schema);

      // Should use Uint8List type
      expect(code, contains('final Uint8List? b32Data;'));

      // Should use base32 helpers
      expect(code, contains('_base32Decode'));
      expect(code, contains('_base32Encode'));

      // Should include helper functions
      expect(code, contains('Uint8List _base32Decode(String input)'));
      expect(code, contains('String _base32Encode(Uint8List bytes)'));
    });

    test('quoted-printable encoding generates Uint8List with helpers', () {
      final schema = {
        'type': 'object',
        'properties': {
          'qpData': {
            'type': 'string',
            'contentEncoding': 'quoted-printable',
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'QPData',
          enableContentKeywords: true,
        ),
      );

      final code = generator.generate(schema);

      // Should use Uint8List type
      expect(code, contains('final Uint8List? qpData;'));

      // Should use quoted-printable helpers
      expect(code, contains('_quotedPrintableDecode'));
      expect(code, contains('_quotedPrintableEncode'));

      // Should include helper functions
      expect(code, contains('Uint8List _quotedPrintableDecode(String input)'));
      expect(
        code,
        contains('String _quotedPrintableEncode(Uint8List bytes)'),
      );
    });

    test('multiple encodings in same schema', () {
      final schema = {
        'type': 'object',
        'properties': {
          'base64Field': {
            'type': 'string',
            'contentEncoding': 'base64',
          },
          'base16Field': {
            'type': 'string',
            'contentEncoding': 'base16',
          },
          'base32Field': {
            'type': 'string',
            'contentEncoding': 'base32',
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'MultiEncoding',
          enableContentKeywords: true,
        ),
      );

      final code = generator.generate(schema);

      // Should have all types
      expect(code, contains('final Uint8List? base64Field;'));
      expect(code, contains('final Uint8List? base16Field;'));
      expect(code, contains('final Uint8List? base32Field;'));

      // Should use appropriate functions
      expect(code, contains('base64Decode'));
      expect(code, contains('_base16Decode'));
      expect(code, contains('_base32Decode'));

      // Should include necessary helpers (but not all)
      expect(code, contains('Uint8List _base16Decode'));
      expect(code, contains('Uint8List _base32Decode'));
      expect(code, isNot(contains('_quotedPrintableDecode'))); // Not used
    });

    test('unsupported encoding stays as String', () {
      final schema = {
        'type': 'object',
        'properties': {
          'data': {
            'type': 'string',
            'contentEncoding': 'unknown-encoding',
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'Data',
          enableContentKeywords: true,
        ),
      );

      final ir = generator.buildIr(schema);
      final dataProp = ir.rootClass.properties
          .firstWhere((p) => p.fieldName == 'data');

      // Should remain String for unsupported encoding
      expect(dataProp.typeRef, isA<PrimitiveTypeRef>());
      expect(dataProp.dartType, 'String?');
    });

    test('contentSchema type is resolved when validation is enabled', () {
      final schema = {
        'type': 'object',
        'properties': {
          'metadata': {
            'type': 'string',
            'contentMediaType': 'application/json',
            'contentSchema': {
              'type': 'object',
              'properties': {
                'version': {'type': 'string'},
              },
            },
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          rootClassName: 'Data',
          enableContentValidation: true,
        ),
      );

      final ir = generator.buildIr(schema);
      final metadataProp = ir.rootClass.properties
          .firstWhere((p) => p.fieldName == 'metadata');

      expect(metadataProp.contentSchemaTypeRef, isNotNull);
    });

    test('emits contentSchema validation when enabled', () {
      final schema = {
        'type': 'object',
        'properties': {
          'payload': {
            'type': 'string',
            'contentMediaType': 'application/json',
            'contentSchema': {
              'type': 'object',
              'properties': {
                'name': {'type': 'string'},
              },
            },
          },
        },
        'required': ['payload'],
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          emitValidationHelpers: true,
          enableContentValidation: true,
        ),
      );

      final code = generator.generate(schema);

      expect(code, contains('jsonDecode'));
      expect(code, contains('contentSchema'));
      expect(code, contains("import 'dart:convert';"));
    });
  });
}
