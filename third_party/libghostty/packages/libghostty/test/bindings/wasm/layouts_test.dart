@Tags(['wasm'])
library;

import 'dart:convert';

import 'package:libghostty/src/bindings/types.dart' show RawCellData;
import 'package:libghostty/src/bindings/wasm/layouts.dart';
import 'package:libghostty/src/generated/libghostty_enums.g.dart';
import 'package:test/test.dart';

void main() {
  Map<String, dynamic> packedCellTypes() {
    Map<String, dynamic> bit(int lsb, int width, String type) => {
      'lsb': lsb,
      'width': width,
      'type': type,
    };

    Map<String, dynamic> arm(Map<String, dynamic> bits) => {
      'kind': 'packed',
      'width': 24,
      'bits': bits,
    };

    return {
      'GhosttyCell': {
        'kind': 'packed',
        'size': 8,
        'align': 8,
        'underlying': 'u64',
        'bits': {
          'content_tag': bit(0, 2, 'GhosttyCellContentTag'),
          'content': {
            'kind': 'union',
            'lsb': 2,
            'width': 24,
            'tag': 'content_tag',
            'arms': {
              'CODEPOINT': arm({'codepoint': bit(0, 21, 'u21')}),
              'CODEPOINT_GRAPHEME': arm({'codepoint': bit(0, 21, 'u21')}),
              'BG_COLOR_PALETTE': arm({
                'index': bit(0, 8, 'GhosttyColorPaletteIndex'),
              }),
              'BG_COLOR_RGB': arm({
                'r': bit(0, 8, 'u8'),
                'g': bit(8, 8, 'u8'),
                'b': bit(16, 8, 'u8'),
              }),
            },
          },
          'style_id': bit(26, 16, 'GhosttyStyleId'),
          'wide': bit(42, 2, 'GhosttyCellWide'),
          'protected': bit(44, 1, 'bool'),
          'hyperlink': bit(45, 1, 'bool'),
          'semantic_content': bit(46, 2, 'GhosttyCellSemanticContent'),
        },
      },
    };
  }

  int rawCell(
    Map<String, dynamic> types, {
    required int tag,
    required int codepoint,
    required int styleId,
    required int wide,
    bool isProtected = false,
    bool hasHyperlink = false,
    int semanticContent = 0,
  }) {
    final cell = types['GhosttyCell'] as Map<String, dynamic>;
    final bits = cell['bits'] as Map<String, dynamic>;
    int field(String name, int value) {
      final descriptor = bits[name] as Map<String, dynamic>;
      var scale = 1;
      final lsb = descriptor['lsb'] as int;
      for (var i = 0; i < lsb; i++) {
        scale *= 2;
      }
      return value * scale;
    }

    return field('content_tag', tag) +
        field('content', codepoint) +
        field('style_id', styleId) +
        field('wide', wide) +
        field('protected', isProtected ? 1 : 0) +
        field('hyperlink', hasHyperlink ? 1 : 0) +
        field('semantic_content', semanticContent);
  }

  group('PackedCellLayout', () {
    test('decodes codepoint, style, and width from manifest bits', () {
      final types = packedCellTypes();
      final layout = PackedCellLayout.fromTypes(types);
      final raw = rawCell(
        types,
        tag: 0,
        codepoint: 0x41,
        styleId: 0x1234,
        wide: 1,
      );

      final summary = RawCellData();

      layout.decodeInto(raw, summary);

      expect(summary.codepoint, 0x41);
      expect(summary.styleId, 0x1234);
      expect(summary.wide, CellWide.wide);
    });

    test('decodes grapheme codepoints through the tagged arm', () {
      final types = packedCellTypes();
      final layout = PackedCellLayout.fromTypes(types);
      final raw = rawCell(
        types,
        tag: 1,
        codepoint: 0x1F642,
        styleId: 0,
        wide: 0,
      );

      final summary = RawCellData();

      layout.decodeInto(raw, summary);

      expect(summary.codepoint, 0x1F642);
    });

    test('decodes packed cell metadata without a C query', () {
      final types = packedCellTypes();
      final layout = PackedCellLayout.fromTypes(types);
      final raw = rawCell(
        types,
        tag: 0,
        codepoint: 0x41,
        styleId: 7,
        wide: 2,
        isProtected: true,
        hasHyperlink: true,
        semanticContent: 2,
      );
      final data = RawCellData();

      layout.decodeInto(raw, data);

      expect(
        (
          rawCell: data.rawCell,
          contentTag: data.contentTag,
          codepoint: data.codepoint,
          hasGrapheme: data.hasGrapheme,
          styleId: data.styleId,
          wide: data.wide,
          isProtected: data.isProtected,
          hasHyperlink: data.hasHyperlink,
          semanticContent: data.semanticContent,
        ),
        (
          rawCell: raw,
          contentTag: CellContentTag.codepoint,
          codepoint: 0x41,
          hasGrapheme: false,
          styleId: 7,
          wide: CellWide.spacerTail,
          isProtected: true,
          hasHyperlink: true,
          semanticContent: CellSemanticContent.prompt,
        ),
      );
    });

    test('decodes inline RGB background data from the tagged arm', () {
      final types = packedCellTypes();
      final layout = PackedCellLayout.fromTypes(types);
      final raw = rawCell(
        types,
        tag: 3,
        codepoint: 0x123456,
        styleId: 0,
        wide: 0,
      );
      final data = RawCellData();

      layout.decodeInto(raw, data);

      expect(
        (
          contentTag: data.contentTag,
          codepoint: data.codepoint,
          hasBackgroundRgb: data.hasBackgroundRgb,
          red: data.backgroundR,
          green: data.backgroundG,
          blue: data.backgroundB,
        ),
        (
          contentTag: CellContentTag.bgColorRgb,
          codepoint: 0,
          hasBackgroundRgb: true,
          red: 0x56,
          green: 0x34,
          blue: 0x12,
        ),
      );
    });

    test('rejects a missing packed field', () {
      final types = packedCellTypes();
      final cell = types['GhosttyCell'] as Map<String, dynamic>;
      final bits = cell['bits'] as Map<String, dynamic>;
      bits.remove('style_id');

      expect(
        () => PackedCellLayout.fromTypes(types),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a malformed tagged union', () {
      final types = packedCellTypes();
      final cell = types['GhosttyCell'] as Map<String, dynamic>;
      final bits = cell['bits'] as Map<String, dynamic>;
      final content = bits['content'] as Map<String, dynamic>;
      content['tag'] = 'wrong_tag';

      expect(
        () => PackedCellLayout.fromTypes(types),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Layouts.fromJson', () {
    String metadata({
      int schema = 1,
      String target = 'wasm32',
      int pointerSize = 4,
      int usizeSize = 4,
      String endian = 'little',
    }) => jsonEncode(<String, dynamic>{
      'schema': schema,
      'abi': {
        'target': target,
        'os': 'freestanding',
        'environment': 'unknown',
        'pointer_size': pointerSize,
        'usize_size': usizeSize,
        'max_alignment': 8,
        'endian': endian,
      },
      'library_version': 'test',
      'commit': null,
      'dirty': null,
      'types': <String, dynamic>{},
    });

    test('rejects an unsupported schema version', () {
      expect(
        () => Layouts.fromJson(metadata(schema: 2)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Unsupported layout metadata schema: 2.',
          ),
        ),
      );
    });

    test('rejects a non-wasm target', () {
      expect(
        () => Layouts.fromJson(metadata(target: 'x86_64')),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Unsupported layout metadata target: x86_64.',
          ),
        ),
      );
    });

    test('rejects a non-32-bit pointer ABI', () {
      expect(
        () => Layouts.fromJson(metadata(pointerSize: 8)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Wasm layout metadata must use 32-bit pointers and usize.',
          ),
        ),
      );
    });

    test('rejects a non-little-endian ABI', () {
      expect(
        () => Layouts.fromJson(metadata(endian: 'big')),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Unsupported Wasm layout metadata endianness: big.',
          ),
        ),
      );
    });

    test('rejects metadata with a missing manifest field', () {
      expect(
        () => Layouts.fromJson('{"schema":1}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Layout metadata is missing manifest field: abi.',
          ),
        ),
      );
    });
  });
}
