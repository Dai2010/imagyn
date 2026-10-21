import 'dart:convert';
import 'dart:typed_data';

import 'import.dart';
import 'models.dart';

/// Reads a presentation the user already has into the editable deck model.
///
/// Each shape becomes a free-form element so the layout survives: a standard
/// title/bullets page would be re-flowed by our own layout, which is not what
/// "open my deck and keep editing" means. Pictures are returned as bytes and
/// saved by the caller, because this layer has no storage.
class PptxImport {
  static ({Deck deck, Map<String, Uint8List> media}) read(
    String fileName,
    Uint8List bytes, {
    required String id,
  }) {
    final files = DocumentImport.unzip(bytes);
    final size = _slideSize(files['ppt/presentation.xml']);
    final numbers =
        files.keys
            .where((key) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(key))
            .map(_slideNumber)
            .toList()
          ..sort();
    if (numbers.isEmpty) throw const FormatException('invalidDeck');
    final media = <String, Uint8List>{};
    final slides = <Slide>[
      for (final number in numbers)
        _slide(
          utf8.decode(files['ppt/slides/slide$number.xml']!, allowMalformed: true),
          number,
          size.width,
          size.height,
          files,
          media,
        ),
    ];
    final ratio = size.width / size.height;
    return (
      deck: Deck(
        id: id,
        title: _title(files) ?? _nameWithoutExtension(fileName),
        aspectRatio: ratio < 1.5 ? '4:3' : '16:9',
        slides: slides,
      ),
      media: media,
    );
  }

  static int _slideNumber(String key) =>
      int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(key)?.group(1) ?? '') ?? 0;

  static ({int width, int height}) _slideSize(String? xml) {
    final match = RegExp(
      r'<p:sldSz cx="(\d+)" cy="(\d+)"',
    ).firstMatch(xml ?? '');
    final width = int.tryParse(match?.group(1) ?? '') ?? 12192000;
    final height = int.tryParse(match?.group(2) ?? '') ?? 6858000;
    return (width: width <= 0 ? 12192000 : width, height: height <= 0 ? 6858000 : height);
  }

  static String? _title(Map<String, Uint8List> files) {
    final core = files['docProps/core.xml'];
    if (core == null) return null;
    final match = RegExp(
      r'<dc:title>(.*?)</dc:title>',
      dotAll: true,
    ).firstMatch(utf8.decode(core, allowMalformed: true));
    final title = match == null ? '' : DocumentImport.unescape(match.group(1)!);
    return title.trim().isEmpty ? null : title.trim();
  }

  static String _nameWithoutExtension(String name) {
    final base = DocumentImport.baseName(name);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }

  static Slide _slide(
    String xml,
    int number,
    int pageWidth,
    int pageHeight,
    Map<String, Uint8List> files,
    Map<String, Uint8List> media,
  ) {
    final elements = <SlideElement>[];
    final tables = <SlideTable>[];
    var counter = 0;
    final shapes = RegExp(
      r'<(p:sp|p:pic|p:graphicFrame)>(.*?)</\1>',
      dotAll: true,
    );
    for (final shape in shapes.allMatches(xml)) {
      final kind = shape.group(1);
      final body = shape.group(2) ?? '';
      if (kind == 'p:graphicFrame') {
        final table = _table(body);
        if (table != null) tables.add(table);
        continue;
      }
      final box = _box(body, pageWidth, pageHeight);
      if (kind == 'p:pic') {
        final picture = _picture(
          body,
          number,
          files,
          media,
          box,
          counter + 1,
        );
        if (picture != null) {
          elements.add(picture.element);
          counter++;
        }
        continue;
      }
      final text = _paragraphs(body);
      if (text.isEmpty) continue;
      final isTitle =
          body.contains('<p:ph type="title"') ||
          body.contains('<p:ph type="ctrTitle"');
      final geometry = box ??
          (
            x: .06,
            y: isTitle ? .05 : .24,
            width: .88,
            height: isTitle ? .18 : .68,
          );
      final element = _textElement(
        body,
        text,
        geometry,
        pageWidth,
        ++counter,
      );
      if (element != null) elements.add(element);
    }
    return Slide(
      backgroundColor: _background(xml),
      notes: _notes(files, number),
      tables: tables,
      elements: elements,
    );
  }

  static SlideElement? _textElement(
    String body,
    List<String> lines,
    ({double x, double y, double width, double height}) box,
    int pageWidth,
    int id,
  ) {
    var text = lines.join('\n');
    if (text.length > SlideElement.maxTextLength) {
      text = text.substring(0, SlideElement.maxTextLength);
    }
    final sizeMatch = RegExp(r'sz="(\d+)"').firstMatch(body);
    final size = ((int.tryParse(sizeMatch?.group(1) ?? '') ?? 1800) / 100)
        .clamp(6.0, 200.0)
        .toDouble();
    final runProperties =
        RegExp(r'<a:rPr[^>]*>(.*?)</a:rPr>', dotAll: true).firstMatch(body);
    final color =
        RegExp(
          r'<a:srgbClr val="([0-9A-Fa-f]{6})"/>',
        ).firstMatch(runProperties?.group(1) ?? '')?.group(1)?.toUpperCase() ??
        '1F1B2E';
    final align = body.contains('algn="ctr"')
        ? 'center'
        : body.contains('algn="r"')
        ? 'right'
        : 'left';
    try {
      return SlideElement(
        id: 'e$id',
        kind: SlideElementKind.text,
        text: text,
        x: box.x,
        y: box.y,
        width: box.width,
        height: box.height,
        fontSize: size,
        color: color,
        bold: body.contains('b="1"'),
        italic: body.contains('i="1"'),
        align: align,
      );
    } on FormatException {
      return null;
    }
  }

  static ({SlideElement element}?) _picture(
    String body,
    int number,
    Map<String, Uint8List> files,
    Map<String, Uint8List> media,
    ({double x, double y, double width, double height})? box,
    int id,
  ) {
    if (box == null) return null;
    final embed = RegExp(r'r:embed="(rId\d+)"').firstMatch(body)?.group(1);
    if (embed == null) return null;
    final target = _mediaTarget(files, number, embed);
    final bytes = target == null ? null : files[target];
    if (bytes == null) return null;
    final key = 'e$id';
    media[key] = bytes;
    try {
      return (
        element: SlideElement(
          id: key,
          kind: SlideElementKind.image,
          imageId: key,
          x: box.x,
          y: box.y,
          width: box.width,
          height: box.height,
          fit: 'contain',
        ),
      );
    } on FormatException {
      media.remove(key);
      return null;
    }
  }

  static ({double x, double y, double width, double height})? _box(
    String body,
    int pageWidth,
    int pageHeight,
  ) {
    final off = RegExp(
      r'<a:off x="(-?\d+)" y="(-?\d+)"/>',
    ).firstMatch(body);
    final ext = RegExp(
      r'<a:ext cx="(\d+)" cy="(\d+)"/>',
    ).firstMatch(body);
    if (off == null || ext == null) return null;
    final cx = int.tryParse(ext.group(1) ?? '') ?? 0;
    final cy = int.tryParse(ext.group(2) ?? '') ?? 0;
    if (cx <= 0 || cy <= 0) return null;
    final width = (cx / pageWidth).clamp(.01, 1.0).toDouble();
    final height = (cy / pageHeight).clamp(.01, 1.0).toDouble();
    final x = (int.parse(off.group(1)!) / pageWidth)
        .clamp(0.0, 1.0 - width)
        .toDouble();
    final y = (int.parse(off.group(2)!) / pageHeight)
        .clamp(0.0, 1.0 - height)
        .toDouble();
    return (x: x, y: y, width: width, height: height);
  }

  static String? _mediaTarget(
    Map<String, Uint8List> files,
    int number,
    String relationship,
  ) {
    final rels = files['ppt/slides/_rels/slide$number.xml.rels'];
    if (rels == null) return null;
    final match = RegExp(
      '<Relationship Id="$relationship"[^>]*Target="([^"]+)"',
    ).firstMatch(utf8.decode(rels, allowMalformed: true));
    final target = match?.group(1);
    if (target == null) return null;
    final parts = <String>['ppt', 'slides'];
    for (final segment in target.split('/')) {
      if (segment == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (segment != '.' && segment.isNotEmpty) {
        parts.add(segment);
      }
    }
    return parts.join('/');
  }

  static List<String> _paragraphs(String xml) => [
    for (final match in RegExp(
      r'<a:p>.*?</a:p>',
      dotAll: true,
    ).allMatches(xml))
      if (_runs(match.group(0)!).trim().isNotEmpty)
        '${match.group(0)!.contains('<a:buChar') || match.group(0)!.contains('<a:buAutoNum') ? '• ' : ''}'
            '${_runs(match.group(0)!).trim()}',
  ];

  static String _runs(String xml) => RegExp(
    r'<a:t[^>]*>(.*?)</a:t>',
    dotAll: true,
  ).allMatches(xml).map((match) => DocumentImport.unescape(match.group(1) ?? '')).join();

  static SlideTable? _table(String body) {
    final table = RegExp(
      r'<a:tbl>.*?</a:tbl>',
      dotAll: true,
    ).firstMatch(body)?.group(0);
    if (table == null) return null;
    final rows = <List<String>>[];
    for (final row in RegExp(
      r'<a:tr[^>]*>(.*?)</a:tr>',
      dotAll: true,
    ).allMatches(table)) {
      final cells = <String>[
        for (final cell in RegExp(
          r'<a:tc[^>]*>(.*?)</a:tc>',
          dotAll: true,
        ).allMatches(row.group(1)!))
          _runs(cell.group(1)!).trim(),
      ];
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return null;
    final columns = rows.first.length;
    if (columns > SlideTable.maxColumns ||
        rows.length > SlideTable.maxRows ||
        rows.any((row) => row.length != columns)) {
      return null;
    }
    try {
      return SlideTable(
        rows: [
          for (final row in rows)
            [
              for (final cell in row)
                cell.length > SlideTable.maxCellLength
                    ? cell.substring(0, SlideTable.maxCellLength)
                    : cell,
            ],
        ],
        headerRow: table.contains('firstRow="1"'),
      );
    } on FormatException {
      return null;
    }
  }

  static String? _background(String xml) {
    final block = RegExp(
      r'<p:bg>.*?</p:bg>',
      dotAll: true,
    ).firstMatch(xml)?.group(0);
    if (block == null || block.contains('<a:blip')) return null;
    return RegExp(
      r'<a:srgbClr val="([0-9A-Fa-f]{6})"/>',
    ).firstMatch(block)?.group(1)?.toUpperCase();
  }

  static String _notes(Map<String, Uint8List> files, int number) {
    final part = files['ppt/notesSlides/notesSlide$number.xml'];
    if (part == null) return '';
    final text = _paragraphs(
      utf8.decode(part, allowMalformed: true),
    ).join('\n').trim();
    return text.length > Slide.maxNotesLength
        ? text.substring(0, Slide.maxNotesLength)
        : text;
  }
}
