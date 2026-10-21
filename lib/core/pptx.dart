import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

/// One picture the deck may use, already read from storage.
///
/// The writer never touches files: a slide names an image by id, and the
/// caller resolves it. That keeps this file testable without a database or a
/// platform channel, and keeps the picture bytes out of the deck model.
class PptxImage {
  const PptxImage({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
  });
  final Uint8List bytes;
  final String mime;
  final int width, height;
}

/// The EMU size of the slide, matching the ratio the user picked.
({int width, int height}) deckSize(Deck deck) => deck.aspectRatio == '4:3'
    ? (width: 9144000, height: 6858000)
    : (width: 12192000, height: 6858000);

/// Builds an Office Open XML presentation with editable text, pictures and
/// native DrawingML tables. The caller supplies any referenced picture bytes.
///
/// The archive is stored rather than deflated. Images are already compressed,
/// slide XML is small, and a stored archive needs no compressor in Dart — only
/// the CRC each entry must carry anyway.
Uint8List buildPptx(Deck deck, Map<String, PptxImage> images) {
  final size = deckSize(deck);
  final media = <String, _Media>{};
  final slides = <_SlideParts>[];

  for (var i = 0; i < deck.slides.length; i++) {
    final slide = deck.slides[i];
    final used = <String, _Media>{};
    final backgroundId = deck.backgroundFor(slide);
    final background = backgroundId == null ? null : images[backgroundId];
    if (backgroundId != null && background != null) {
      final part = media.putIfAbsent(
        backgroundId,
        () => _Media(media.length + 1, background),
      );
      used[backgroundId] = part;
    }
    final id = slide.imageId;
    final image = id == null ? null : images[id];
    if (id != null && image != null) {
      final part = media.putIfAbsent(id, () => _Media(media.length + 1, image));
      used[id] = part;
    }
    // Free-form pictures are embedded the same way, so a page can carry
    // several of them and every element keeps its own relationship id.
    final elementImages = <String, PptxImage>{};
    for (final element in slide.elements) {
      final elementId = element.imageId;
      if (elementId == null) continue;
      final picture = images[elementId];
      if (picture == null) continue;
      final part = media.putIfAbsent(
        elementId,
        () => _Media(media.length + 1, picture),
      );
      used[elementId] = part;
      elementImages[elementId] = picture;
    }
    slides.add(
      _SlideParts(
        number: i + 1,
        xml: _slideXml(
          slide,
          i + 1,
          size,
          image,
          used.values.toList(),
          background: background,
          backgroundRgb: deck.backgroundColorFor(slide),
          elementImages: elementImages,
        ),
        images: used.values.toList(),
      ),
    );
  }

  final noted = [
    for (var i = 0; i < deck.slides.length; i++)
      if (deck.slides[i].notes.trim().isNotEmpty) i + 1,
  ];

  final zip = _ZipBuilder()
    ..add(
      '[Content_Types].xml',
      _contentTypes(
        media.values.map((part) => part.image.mime).toSet(),
        slides.length,
        notesSlides: noted,
      ),
    )
    ..add('_rels/.rels', _rootRels())
    ..add('ppt/presentation.xml', _presentationXml(slides.length, size))
    ..add('ppt/_rels/presentation.xml.rels', _presentationRels(slides.length))
    ..add('ppt/slideMasters/slideMaster1.xml', _slideMasterXml())
    ..add('ppt/slideMasters/_rels/slideMaster1.xml.rels', _slideMasterRels())
    ..add('ppt/slideLayouts/slideLayout1.xml', _slideLayoutXml())
    ..add(
      'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
      _relationshipXml([
        _Relationship(
          'rId1',
          'slideMaster',
          '../slideMasters/slideMaster1.xml',
        ),
      ]),
    )
    ..add('ppt/theme/theme1.xml', _themeXml())
    ..add('ppt/notesMasters/notesMaster1.xml', _notesMasterXml())
    ..add(
      'ppt/notesMasters/_rels/notesMaster1.xml.rels',
      _relationshipXml([
        _Relationship('rId1', 'theme', '../theme/theme1.xml'),
      ]),
    );

  for (final slide in slides) {
    zip.add('ppt/slides/slide${slide.number}.xml', slide.xml);
    zip.add(
      'ppt/slides/_rels/slide${slide.number}.xml.rels',
      _relationshipXml([
        _Relationship(
          'rId1',
          'slideLayout',
          '../slideLayouts/slideLayout1.xml',
        ),
        for (var i = 0; i < slide.images.length; i++)
          _Relationship(
            'rId${i + 2}',
            'image',
            '../media/image${slide.images[i].number}.${_extension(slide.images[i].image.mime)}',
          ),
        if (deck.slides[slide.number - 1].notes.trim().isNotEmpty)
          _Relationship(
            'rId${slide.images.length + 2}',
            'notesSlide',
            '../notesSlides/notesSlide${slide.number}.xml',
          ),
      ]),
    );
  }
  for (final number in noted) {
    zip.add(
      'ppt/notesSlides/notesSlide$number.xml',
      _notesSlideXml(deck.slides[number - 1].notes),
    );
    zip.add(
      'ppt/notesSlides/_rels/notesSlide$number.xml.rels',
      _relationshipXml([
        _Relationship('rId1', 'slide', '../slides/slide$number.xml'),
        _Relationship(
          'rId2',
          'notesMaster',
          '../notesMasters/notesMaster1.xml',
        ),
      ]),
    );
  }
  for (final part in media.values) {
    zip.addBytes(
      'ppt/media/image${part.number}.${_extension(part.image.mime)}',
      part.image.bytes,
    );
  }
  return zip.build();
}

class _Media {
  const _Media(this.number, this.image);
  final int number;
  final PptxImage image;
}

class _SlideParts {
  const _SlideParts({
    required this.number,
    required this.xml,
    required this.images,
  });
  final int number;
  final String xml;
  final List<_Media> images;
}

String _extension(String mime) => switch (mime) {
  'image/jpeg' => 'jpeg',
  'image/webp' => 'webp',
  _ => 'png',
};

String _contentTypes(
  Set<String> imageMimes,
  int slideCount, {
  Iterable<int> notesSlides = const [],
}) {
  final extensions = <String, String>{
    'rels': 'application/vnd.openxmlformats-package.relationships+xml',
    'xml': 'application/xml',
  };
  for (final mime in imageMimes) {
    extensions[_extension(mime)] = mime;
  }
  final buffer = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
  );
  for (final entry in extensions.entries) {
    buffer.write(
      '<Default Extension="${_esc(entry.key)}" '
      'ContentType="${_esc(entry.value)}"/>',
    );
  }
  const presentation =
      'application/vnd.openxmlformats-officedocument.presentationml';
  buffer
    ..write(
      '<Override PartName="/ppt/presentation.xml" '
      'ContentType="$presentation.presentation.main+xml"/>',
    )
    ..write(
      '<Override PartName="/ppt/slideMasters/slideMaster1.xml" '
      'ContentType="$presentation.slideMaster+xml"/>',
    )
    ..write(
      '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" '
      'ContentType="$presentation.slideLayout+xml"/>',
    )
    ..write(
      '<Override PartName="/ppt/theme/theme1.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>',
    );
  // Without one Override per slide, the `xml` default type applies and Office
  // reads a slide as a plain XML part instead of a presentation slide.
  for (var i = 0; i < slideCount; i++) {
    buffer.write(
      '<Override PartName="/ppt/slides/slide${i + 1}.xml" '
      'ContentType="$presentation.slide+xml"/>',
    );
  }
  buffer.write(
    '<Override PartName="/ppt/notesMasters/notesMaster1.xml" '
    'ContentType="$presentation.notesMaster+xml"/>',
  );
  if (notesSlides.isNotEmpty) {
    buffer.write(
      [for (final number in notesSlides)
        '<Override PartName="/ppt/notesSlides/notesSlide$number.xml" '
            'ContentType="$presentation.notesSlide+xml"/>'].join(),
    );
  }
  buffer.write('</Types>');
  return buffer.toString();
}

String _rootRels() => _relationshipXml([
  _Relationship('rId1', 'officeDocument', 'ppt/presentation.xml'),
]);

String _presentationXml(int count, ({int width, int height}) size) {
  final buffer = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<p:presentation '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
    '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/>'
    '</p:sldMasterIdLst>'
    '<p:notesMasterIdLst><p:notesMasterId r:id="rId${count + 3}"/>'
    '</p:notesMasterIdLst>',
  );
  if (count > 0) {
    buffer.write('<p:sldIdLst>');
    for (var i = 0; i < count; i++) {
      buffer.write('<p:sldId id="${256 + i}" r:id="rId${i + 3}"/>');
    }
    buffer.write('</p:sldIdLst>');
  }
  buffer.write(
    '<p:sldSz cx="${size.width}" cy="${size.height}"/>'
    '<p:notesSz cx="6858000" cy="9144000"/>'
    '</p:presentation>',
  );
  return buffer.toString();
}

String _presentationRels(int count) => _relationshipXml([
  _Relationship('rId1', 'slideMaster', 'slideMasters/slideMaster1.xml'),
  _Relationship('rId2', 'theme', 'theme/theme1.xml'),
  for (var i = 0; i < count; i++)
    _Relationship('rId${i + 3}', 'slide', 'slides/slide${i + 1}.xml'),
  _Relationship(
    'rId${count + 3}',
    'notesMaster',
    'notesMasters/notesMaster1.xml',
  ),
]);

String _slideMasterXml() =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<p:sldMaster '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
    '<p:cSld>${_emptyTree()}</p:cSld>'
    '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" '
    'accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" '
    'accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
    '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/>'
    '</p:sldLayoutIdLst>'
    '</p:sldMaster>';

String _slideMasterRels() => _relationshipXml([
  _Relationship('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'),
  _Relationship('rId2', 'theme', '../theme/theme1.xml'),
]);

String _slideLayoutXml() =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<p:sldLayout '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
    'type="blank" preserve="1">'
    '<p:cSld name="Blank">${_emptyTree()}</p:cSld>'
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>'
    '</p:sldLayout>';

String _emptyTree() =>
    '<p:spTree>'
    '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
    '</p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
    '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
    '</p:spTree>';

String _themeXml() => '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Imagyn">
<a:themeElements>
<a:clrScheme name="Imagyn">
<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
<a:dk2><a:srgbClr val="1F1B2E"/></a:dk2>
<a:lt2><a:srgbClr val="F4F2FA"/></a:lt2>
<a:accent1><a:srgbClr val="7863C7"/></a:accent1>
<a:accent2><a:srgbClr val="4C9A8F"/></a:accent2>
<a:accent3><a:srgbClr val="D98A5F"/></a:accent3>
<a:accent4><a:srgbClr val="5B7FC7"/></a:accent4>
<a:accent5><a:srgbClr val="A76BA6"/></a:accent5>
<a:accent6><a:srgbClr val="8C7F63"/></a:accent6>
<a:hlink><a:srgbClr val="5B7FC7"/></a:hlink>
<a:folHlink><a:srgbClr val="A76BA6"/></a:folHlink>
</a:clrScheme>
<a:fontScheme name="Imagyn">
<a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface="Microsoft YaHei"/><a:cs typeface=""/></a:majorFont>
<a:minorFont><a:latin typeface="Aptos"/><a:ea typeface="Microsoft YaHei"/><a:cs typeface=""/></a:minorFont>
</a:fontScheme>
<a:fmtScheme name="Imagyn">
<a:fillStyleLst>
<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
</a:fillStyleLst>
<a:lnStyleLst>
<a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
<a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
<a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
</a:lnStyleLst>
<a:effectStyleLst>
<a:effectStyle><a:effectLst/></a:effectStyle>
<a:effectStyle><a:effectLst/></a:effectStyle>
<a:effectStyle><a:effectLst/></a:effectStyle>
</a:effectStyleLst>
<a:bgFillStyleLst>
<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
</a:bgFillStyleLst>
</a:fmtScheme>
</a:themeElements>
</a:theme>''';

String _slideXml(
  Slide slide,
  int number,
  ({int width, int height}) size,
  PptxImage? image,
  List<_Media> images, {
  PptxImage? background,
  String? backgroundRgb,
  Map<String, PptxImage> elementImages = const {},
}) {
  final margin = (size.width * .05).round();
  final contentWidth = size.width - margin * 2;
  final titleTop = (size.height * .055).round();
  final titleHeight = (size.height * .16).round();
  final bodyTop = titleTop + titleHeight + (size.height * .02).round();
  final bodyHeight = size.height - bodyTop - margin;
  final hasImage = image != null && images.isNotEmpty;
  final gap = (size.width * .022).round();
  final imageWidth = (contentWidth * .45).round();
  final textWidth = hasImage ? contentWidth - imageWidth - gap : contentWidth;
  final titleSize = slide.bullets.length <= 2 ? 3200 : 3000;
  final bodySize = switch (slide.bullets.length) {
    <= 3 => 1800,
    <= 5 => 1600,
    _ => 1500,
  };
  final backgroundIndex = background == null
      ? -1
      : images.indexWhere((part) => identical(part.image, background));
  final backgroundEmbed = backgroundIndex < 0
      ? null
      : 'rId${backgroundIndex + 2}';

  final shapes = StringBuffer();
  var id = 2;
  if (backgroundEmbed != null) {
    // The picture is the page background; a translucent white sheet keeps the
    // editable dark text readable on any photograph, and stays a separate
    // shape the user can delete or restyle in PowerPoint.
    shapes.write(_scrimShape(id++, size));
  }
  final title = slide.title.trim();
  if (title.isNotEmpty) {
    shapes.write(
      _textShape(
        id: id++,
        name: 'Title ${number - 1}',
        x: margin,
        y: titleTop,
        cx: textWidth,
        cy: titleHeight,
        paragraphs: [
          '<a:p><a:pPr algn="l"/><a:r>${_run(title, titleSize, true, '1F1B2E')}'
              '</a:r></a:p>',
        ],
      ),
    );
  }
  final bullets = [
    for (var i = 0; i < slide.bullets.length; i++)
      if (slide.bullets[i].trim().isNotEmpty)
        (
          text: slide.bullets[i].trim(),
          level: i < slide.bulletLevels.length
              ? slide.bulletLevels[i]
              : 0,
        ),
  ];
  final tables = slide.allTables;
  final tableArea = tables.isEmpty ? 0 : (bodyHeight * .42).round();
  final bulletHeight = tables.isEmpty ? bodyHeight : bodyHeight - tableArea;
  if (bullets.isNotEmpty) {
    shapes.write(
      _textShape(
        id: id++,
        name: 'Content ${number - 1}',
        x: margin,
        y: bodyTop,
        cx: textWidth,
        cy: bulletHeight,
        paragraphs: [
          for (final bullet in bullets)
            _bulletParagraph(
              bullet.text,
              bodySize,
              '3B3650',
              level: bullet.level,
            ),
        ],
      ),
    );
  }
  if (tables.isNotEmpty) {
    final tableGap = bullets.isEmpty ? 0 : (size.height * .02).round();
    final tableTop = bullets.isEmpty
        ? bodyTop
        : bodyTop + bulletHeight + tableGap;
    final parts = _equalParts(bodyTop + bodyHeight - tableTop, tables.length);
    var top = tableTop;
    for (var i = 0; i < tables.length; i++) {
      shapes.write(
        _tableShape(
          id: id++,
          name: 'Table ${number - 1}.${i + 1}',
          table: tables[i],
          x: margin,
          y: top,
          cx: textWidth,
          cy: parts[i],
        ),
      );
      top += parts[i];
    }
  }
  final picture = hasImage ? image : null;
  if (picture != null) {
    final boxX = margin + textWidth + gap;
    final fit = _fit(picture, imageWidth, bodyHeight);
    final part = images.firstWhere((part) => part.image == picture);
    shapes.write(
      _pictureShape(
        id: id++,
        name: 'Picture ${number - 1}',
        embed: 'rId${images.indexOf(part) + 2}',
        x: boxX + (imageWidth - fit.width) ~/ 2,
        y: bodyTop + (bodyHeight - fit.height) ~/ 2,
        cx: fit.width,
        cy: fit.height,
      ),
    );
  }
  // Free-form shapes are written last so they sit above the standard slots,
  // matching the workspace preview's layer order.
  for (final element in slide.elements) {
    final x = (element.x * size.width).round();
    final y = (element.y * size.height).round();
    final cx = math.max(1, (element.width * size.width).round());
    final cy = math.max(1, (element.height * size.height).round());
    if (element.kind == SlideElementKind.text) {
      shapes.write(
        _elementTextShape(
          id: id++,
          name: 'Text ${number - 1}-${element.id}',
          element: element,
          x: x,
          y: y,
          cx: cx,
          cy: cy,
        ),
      );
      continue;
    }
    final picture = elementImages[element.imageId];
    if (picture == null) continue;
    final embed = images.indexWhere((part) => identical(part.image, picture));
    if (embed < 0) continue;
    shapes.write(
      _elementPictureShape(
        id: id++,
        name: 'Picture ${number - 1}-${element.id}',
        embed: 'rId${embed + 2}',
        element: element,
        picture: picture,
        x: x,
        y: y,
        cx: cx,
        cy: cy,
      ),
    );
  }
  // A small page number keeps the deck readable in a slide sorter and costs
  // nothing to edit later.
  shapes.write(
    _textShape(
      id: id++,
      name: 'Page $number',
      x: size.width - margin - 914400,
      y: size.height - (size.height * .065).round(),
      cx: 914400,
      cy: 274320,
      paragraphs: [
        '<a:p><a:pPr algn="r"/><a:r>${_run('$number', 1000, false, '8A8496')}'
            '</a:r></a:p>',
      ],
    ),
  );

  final page = backgroundEmbed != null
      ? '<p:bg><p:bgPr><a:blipFill dpi="0" rotWithShape="1">'
            '<a:blip r:embed="$backgroundEmbed"/><a:stretch><a:fillRect/>'
            '</a:stretch></a:blipFill><a:effectLst/></p:bgPr></p:bg>'
      : '<p:bg><p:bgPr><a:solidFill><a:srgbClr '
            'val="${backgroundRgb ?? 'FBFAFE'}"/></a:solidFill>'
            '<a:effectLst/></p:bgPr></p:bg>';

  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sld '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
      '<p:cSld>'
      '$page'
      '<p:spTree>'
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
      '</p:nvGrpSpPr>'
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
      '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
      '$shapes'
      '</p:spTree>'
      '</p:cSld>'
      '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>'
      '</p:sld>';
}

({int width, int height}) _fit(PptxImage image, int boxWidth, int boxHeight) {
  final width = image.width > 0 ? image.width : 16;
  final height = image.height > 0 ? image.height : 9;
  final scale = math.min(boxWidth / width, boxHeight / height);
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}

String _textShape({
  required int id,
  required String name,
  required int x,
  required int y,
  required int cx,
  required int cy,
  required List<String> paragraphs,
}) =>
    '<p:sp>'
    '<p:nvSpPr><p:cNvPr id="$id" name="${_esc(name)}"/>'
    '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$cx" cy="$cy"/>'
    '</a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
    '<a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>'
    '<p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0">'
    '<a:normAutofit/></a:bodyPr><a:lstStyle/>'
    '${paragraphs.join()}'
    '</p:txBody>'
    '</p:sp>';

String _run(
  String text,
  int size,
  bool bold,
  String color, {
  bool italic = false,
  String? font,
  double spacing = 0,
}) {
  final latin = _esc(font ?? 'Aptos');
  final eastAsian = _esc(font ?? 'Microsoft YaHei');
  final tracking = spacing == 0 ? '' : ' spc="${(spacing * 100).round()}"';
  return '<a:rPr lang="zh-CN" sz="$size" b="${bold ? 1 : 0}" '
      'i="${italic ? 1 : 0}"$tracking dirty="0">'
      '<a:solidFill><a:srgbClr val="$color"/></a:solidFill>'
      '<a:latin typeface="$latin"/><a:ea typeface="$eastAsian"/>'
      '</a:rPr><a:t>${_esc(text)}</a:t>';
}

/// Distributes integer EMUs without losing the remainder to rounding. The
/// grid and row dimensions consequently match the graphic frame exactly.
List<int> _equalParts(int total, int count) => [
  for (var i = 0; i < count; i++) total ~/ count + (i < total % count ? 1 : 0),
];

/// Font sizes use hundredths of a point (127 EMUs). Fit actual cell text,
/// including paragraphs, because Office treats table row heights as minima.
/// normAutofit alone does not prevent a long cell from expanding its row.
int _tableFontSize(
  List<String> paragraphs,
  int width,
  int height, {
  required int row,
  required int column,
}) {
  bool fits(int fontSize) {
    final capacity = width / (fontSize * 127);
    final availableLines = height ~/ (_tableLineHeight(fontSize) * 127);
    var lines = 0;
    for (final paragraph in paragraphs) {
      lines++;
      var used = 0.0;
      for (final rune in paragraph.runes) {
        // Estimate conservatively across font substitutions. CJK and emoji
        // need a full em; most Latin characters take less space. Count tabs
        // as several characters even when they occur at the start of a line.
        final advance = rune == 0x09
            ? 4.4
            : (rune > 0x7F ? 1.1 : (rune == 0x4D || rune == 0x57 ? 1.0 : .8));
        if (used > 0 && used + advance > capacity) {
          lines++;
          used = 0;
        }
        used += advance;
      }
      if (lines > availableLines) return false;
    }
    return lines <= availableLines;
  }

  // DrawingML's minimum valid font size is one point. A cell with hundreds of
  // explicit paragraphs can still exceed that limit; return a useful error
  // instead of a table that Office silently expands past the slide boundary.
  if (!fits(100)) {
    throw FormatException(
      'Table cell at row $row, column $column cannot fit at the minimum '
      '1pt font size. Shorten its text or split the table across slides.',
    );
  }
  var lower = 100;
  var upper = 1800;
  while (lower < upper) {
    final candidate = (lower + upper + 1) ~/ 2;
    if (fits(candidate)) {
      lower = candidate;
    } else {
      upper = candidate - 1;
    }
  }
  return lower;
}

int _tableLineHeight(int fontSize) => (fontSize * 1.2).ceil();

String _tableShape({
  required int id,
  required String name,
  required SlideTable table,
  required int x,
  required int y,
  required int cx,
  required int cy,
}) {
  final widths = _equalParts(cx, table.columnCount);
  final heights = _equalParts(cy, table.rows.length);
  final buffer = StringBuffer(
    '<p:graphicFrame>'
    '<p:nvGraphicFramePr><p:cNvPr id="$id" name="${_esc(name)}"/>'
    '<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/>'
    '</p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>'
    '<p:xfrm><a:off x="$x" y="$y"/><a:ext cx="$cx" cy="$cy"/></p:xfrm>'
    '<a:graphic><a:graphicData '
    'uri="http://schemas.openxmlformats.org/drawingml/2006/table">'
    '<a:tbl><a:tblPr firstRow="${table.headerRow ? 1 : 0}" bandRow="0"/>'
    '<a:tblGrid>',
  );
  for (final width in widths) {
    buffer.write('<a:gridCol w="$width"/>');
  }
  buffer.write('</a:tblGrid>');
  for (var row = 0; row < table.rows.length; row++) {
    final isHeader = table.headerRow && row == 0;
    final fill = isHeader ? '7863C7' : (row.isEven ? 'F4F2FA' : 'FFFFFF');
    final color = isHeader ? 'FFFFFF' : '3B3650';
    buffer.write('<a:tr h="${heights[row]}">');
    for (var column = 0; column < table.columnCount; column++) {
      final text = table.rows[row][column];
      // Smaller cells need proportionally smaller padding to keep useful
      // space for their content, while normal tables retain comfortable gaps.
      final horizontalInset = math.min(91440, widths[column] ~/ 20);
      final verticalInset = math.min(45720, heights[row] ~/ 32);
      final paragraphs = text
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .split('\n');
      final fontSize = _tableFontSize(
        paragraphs,
        widths[column] - horizontalInset * 2,
        heights[row] - verticalInset * 2,
        row: row + 1,
        column: column + 1,
      );
      buffer.write(
        '<a:tc><a:txBody>'
        '<a:bodyPr wrap="square"><a:normAutofit/></a:bodyPr><a:lstStyle/>',
      );
      // DrawingML paragraphs, rather than literal newlines in a:t, preserve
      // line breaks consistently in Office, including leading/trailing blanks.
      for (final line in paragraphs) {
        buffer.write(
          '<a:p><a:pPr algn="l">'
          '<a:lnSpc><a:spcPts val="${_tableLineHeight(fontSize)}"/></a:lnSpc>'
          '<a:spcBef><a:spcPts val="0"/></a:spcBef>'
          '<a:spcAft><a:spcPts val="0"/></a:spcAft><a:buNone/></a:pPr><a:r>'
          '${_run(line, fontSize, isHeader, color)}'
          '</a:r><a:endParaRPr lang="zh-CN" sz="$fontSize"/></a:p>',
        );
      }
      buffer.write(
        '</a:txBody>'
        '<a:tcPr marL="$horizontalInset" marR="$horizontalInset" '
        'marT="$verticalInset" marB="$verticalInset" '
        'anchor="ctr">',
      );
      for (final side in ['L', 'R', 'T', 'B']) {
        buffer.write(
          '<a:ln$side w="6350"><a:solidFill><a:srgbClr val="DCD7EA"/>'
          '</a:solidFill><a:prstDash val="solid"/></a:ln$side>',
        );
      }
      buffer.write(
        '<a:solidFill><a:srgbClr val="$fill"/></a:solidFill></a:tcPr></a:tc>',
      );
    }
    buffer.write('</a:tr>');
  }
  buffer.write('</a:tbl></a:graphicData></a:graphic></p:graphicFrame>');
  return buffer.toString();
}

String _bulletParagraph(
  String text,
  int size,
  String color, {
  int level = 0,
}) {
  final indent = 342900 + level * 342900;
  return '<a:p><a:pPr marL="$indent" indent="-342900" lvl="$level">'
      '<a:lnSpc><a:spcPct val="115000"/></a:lnSpc>'
      '<a:buFont typeface="Arial"/><a:buChar char="•"/></a:pPr>'
      '<a:r>${_run(text, size, false, color)}</a:r></a:p>';
}

String _scrimShape(int id, ({int width, int height}) size) =>
    '<p:sp>'
    '<p:nvSpPr><p:cNvPr id="$id" name="Background scrim"/>'
    '<p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="0" y="0"/>'
    '<a:ext cx="${size.width}" cy="${size.height}"/></a:xfrm>'
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
    '<a:solidFill><a:srgbClr val="FFFFFF"><a:alpha val="52000"/></a:srgbClr>'
    '</a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>'
    '<p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody>'
    '</p:sp>';

String _pictureShape({
  required int id,
  required String name,
  required String embed,
  required int x,
  required int y,
  required int cx,
  required int cy,
}) =>
    '<p:pic>'
    '<p:nvPicPr><p:cNvPr id="$id" name="${_esc(name)}"/>'
    '<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/>'
    '</p:nvPicPr>'
    '<p:blipFill><a:blip r:embed="$embed"/>'
    '<a:stretch><a:fillRect/></a:stretch></p:blipFill>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$cx" cy="$cy"/>'
    '</a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>'
    '</p:pic>';

/// A rectangle, or a rounded one when the element asked for a curve. The
/// adjustment is in 1/1000 of a percent, where 50000 is a half-circle corner —
/// the same range [SlideElement.radius] exposes.
String _elementGeometry(double radius) => radius <= 0
    ? '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
    : '<a:prstGeom prst="roundRect"><a:avLst>'
          '<a:gd name="adj" fmla="val ${(radius * 100000).round()}"/>'
          '</a:avLst></a:prstGeom>';

String _elementLine(String? color) => color == null
    ? '<a:ln><a:noFill/></a:ln>'
    : '<a:ln w="9525"><a:solidFill><a:srgbClr val="$color"/></a:solidFill>'
          '<a:prstDash val="solid"/></a:ln>';

/// An editable DrawingML text box: the fill and outline are real shape
/// properties, so the user can restyle it in PowerPoint instead of getting a
/// picture of a label.
String _elementTextShape({
  required int id,
  required String name,
  required SlideElement element,
  required int x,
  required int y,
  required int cx,
  required int cy,
}) {
  final size = (element.fontSize * 100).round();
  final align = switch (element.align) {
    'center' => 'ctr',
    'right' => 'r',
    _ => 'l',
  };
  // Proportional insets keep a small label from losing its text to padding;
  // an explicit padding wins when the model asked for one.
  final horizontal = element.padding == null
      ? math.min(cx ~/ 12, 91440)
      : (element.padding! * 12700).round();
  final vertical = element.padding == null
      ? math.min(cy ~/ 12, 45720)
      : (element.padding! * 12700).round();
  final spacing = (element.lineSpacing * 100000).round();
  final fill = element.fill == null
      ? '<a:noFill/>'
      : element.fill2 == null
      ? '<a:solidFill><a:srgbClr val="${element.fill}"/></a:solidFill>'
      : '<a:gradFill rotWithShape="1"><a:gsLst>'
            '<a:gs pos="0"><a:srgbClr val="${element.fill}"/></a:gs>'
            '<a:gs pos="100000"><a:srgbClr val="${element.fill2}"/></a:gs>'
            '</a:gsLst><a:lin ang="2700000" scaled="0"/></a:gradFill>';
  final shadow = element.shadow
      ? '<a:effectLst><a:outerShdw blurRad="63500" dist="25400" '
            'dir="5400000" rotWithShape="0"><a:srgbClr val="000000">'
            '<a:alpha val="24000"/></a:srgbClr></a:outerShdw></a:effectLst>'
      : '';
  final rotation = element.rotation == 0
      ? ''
      : ' rot="${(element.rotation * 60000).round()}"';
  final lines = element.text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  return '<p:sp>'
      '<p:nvSpPr><p:cNvPr id="$id" name="${_esc(name)}"/>'
      '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>'
      '<p:spPr><a:xfrm$rotation><a:off x="$x" y="$y"/>'
      '<a:ext cx="$cx" cy="$cy"/></a:xfrm>'
      '${_elementGeometry(element.radius)}$fill'
      '${_elementLine(element.border)}$shadow</p:spPr>'
      '<p:txBody><a:bodyPr wrap="square" lIns="$horizontal" '
      'tIns="$vertical" rIns="$horizontal" bIns="$vertical" anchor="ctr">'
      '<a:normAutofit/></a:bodyPr><a:lstStyle/>'
      '${lines.map((line) => '<a:p><a:pPr algn="$align">'
          '<a:lnSpc><a:spcPct val="$spacing"/></a:lnSpc></a:pPr><a:r>'
          '${_run(line, size, element.bold, element.color, italic: element.italic, font: element.font, spacing: element.letterSpacing)}'
          '</a:r></a:p>').join()}'
      '</p:txBody></p:sp>';
}

/// A free-form picture. `cover` fills the box and crops the overflow through
/// `a:srcRect`, `contain` shrinks the shape to the picture's own ratio inside
/// the box — both are properties Office understands, not a flattened image.
String _elementPictureShape({
  required int id,
  required String name,
  required String embed,
  required SlideElement element,
  required PptxImage picture,
  required int x,
  required int y,
  required int cx,
  required int cy,
}) {
  var left = x, top = y, width = cx, height = cy;
  var crop = '';
  if (element.fit == 'contain') {
    final fit = _fit(picture, cx, cy);
    left = x + (cx - fit.width) ~/ 2;
    top = y + (cy - fit.height) ~/ 2;
    width = math.max(1, fit.width);
    height = math.max(1, fit.height);
  } else {
    final cut = _coverCrop(picture, cx, cy);
    if (cut.l > 0 || cut.t > 0 || cut.r > 0 || cut.b > 0) {
      crop =
          '<a:srcRect l="${cut.l}" t="${cut.t}" r="${cut.r}" b="${cut.b}"/>';
    }
  }
  return '<p:pic>'
      '<p:nvPicPr><p:cNvPr id="$id" name="${_esc(name)}"/>'
      '<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/>'
      '</p:nvPicPr>'
      '<p:blipFill><a:blip r:embed="$embed"/>$crop'
      '<a:stretch><a:fillRect/></a:stretch></p:blipFill>'
      '<p:spPr><a:xfrm><a:off x="$left" y="$top"/>'
      '<a:ext cx="$width" cy="$height"/></a:xfrm>'
      '${_elementGeometry(element.radius)}'
      '${_elementLine(element.border)}</p:spPr>'
      '</p:pic>';
}

/// The crop `cover` needs so a picture fills a box without distortion. Values
/// are in 1/1000 of a percent of the source, as `a:srcRect` expects.
({int l, int t, int r, int b}) _coverCrop(
  PptxImage image,
  int cx,
  int cy,
) {
  final iw = image.width > 0 ? image.width : 16;
  final ih = image.height > 0 ? image.height : 9;
  if (cx <= 0 || cy <= 0) return (l: 0, t: 0, r: 0, b: 0);
  final imageAspect = iw / ih;
  final boxAspect = cx / cy;
  if ((imageAspect - boxAspect).abs() < .0001) {
    return (l: 0, t: 0, r: 0, b: 0);
  }
  final keep = imageAspect > boxAspect
      ? boxAspect / imageAspect
      : imageAspect / boxAspect;
  final cut = ((1 - keep) / 2 * 100000).round();
  return imageAspect > boxAspect
      ? (l: cut, t: 0, r: cut, b: 0)
      : (l: 0, t: cut, r: 0, b: cut);
}

String _notesMasterXml() =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<p:notesMaster '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
    '<p:cSld>${_emptyTree()}</p:cSld>'
    '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" '
    'accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" '
    'accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
    '<p:notesStyle><a:lvl1pPr><a:defRPr sz="1200"/></a:lvl1pPr>'
    '</p:notesStyle></p:notesMaster>';

/// The notes page PowerPoint shows below the slide: the text is a real
/// placeholder, editable in the app the user opens the export with.
String _notesSlideXml(String notes) {
  final paragraphs = notes
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map(
        (line) =>
            '<a:p><a:r><a:rPr lang="zh-CN" sz="1200" dirty="0"/>'
            '<a:t>${_esc(line)}</a:t></a:r></a:p>',
      )
      .join();
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:notes '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
      '<p:cSld><p:spTree>'
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
      '</p:nvGrpSpPr>'
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
      '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
      '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder"/>'
      '<p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/>'
      '</p:cNvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr>'
      '<p:spPr/></p:sp>'
      '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder"/>'
      '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
      '<p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>'
      '<p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>$paragraphs</p:txBody>'
      '</p:sp></p:spTree></p:cSld>'
      '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>';
}

class _Relationship {
  const _Relationship(this.id, this.type, this.target);
  final String id, type, target;
}

String _relationshipXml(List<_Relationship> relationships) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships '
    'xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '${relationships.map((rel) => '<Relationship Id="${rel.id}" Type="'
        'http://schemas.openxmlformats.org/officeDocument/2006/relationships/${rel.type}" '
        'Target="${_esc(rel.target)}"/>').join()}'
    '</Relationships>';

/// Applies the XML escaping every text node needs, and drops characters XML
/// 1.0 cannot carry at all — models sometimes emit control bytes, and one of
/// them is enough to make PowerPoint call the file damaged.
String _esc(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x26:
        buffer.write('&amp;');
      case 0x3C:
        buffer.write('&lt;');
      case 0x3E:
        buffer.write('&gt;');
      case 0x22:
        buffer.write('&quot;');
      case 0x27:
        buffer.write('&apos;');
      default:
        if ((rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) ||
            (rune >= 0xD800 && rune <= 0xDFFF) ||
            rune == 0xFFFE ||
            rune == 0xFFFF) {
          continue;
        }
        buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

final _crcTable = List<int>.generate(256, (n) {
  var value = n;
  for (var bit = 0; bit < 8; bit++) {
    value = value & 1 == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

/// A ZIP with stored entries. Office accepts stored parts; deflate would need
/// a compressor and only save bytes on the small XML parts.
class _ZipBuilder {
  final _entries = <({String name, List<int> bytes})>[];

  void add(String name, String content) =>
      _entries.add((name: name, bytes: utf8.encode(content)));

  void addBytes(String name, List<int> bytes) =>
      _entries.add((name: name, bytes: bytes));

  Uint8List build() {
    final body = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    for (final entry in _entries) {
      final name = utf8.encode(entry.name);
      final crc = _crc32(entry.bytes);
      final offset = body.length;
      body
        ..add(_u32(0x04034b50))
        ..add(_u16(20))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0x21))
        ..add(_u32(crc))
        ..add(_u32(entry.bytes.length))
        ..add(_u32(entry.bytes.length))
        ..add(_u16(name.length))
        ..add(_u16(0))
        ..add(name)
        ..add(entry.bytes);
      central
        ..add(_u32(0x02014b50))
        ..add(_u16(20))
        ..add(_u16(20))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0x21))
        ..add(_u32(crc))
        ..add(_u32(entry.bytes.length))
        ..add(_u32(entry.bytes.length))
        ..add(_u16(name.length))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u32(0))
        ..add(_u32(offset))
        ..add(name);
    }
    final directory = central.takeBytes();
    final start = body.length;
    body
      ..add(directory)
      ..add(_u32(0x06054b50))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(_entries.length))
      ..add(_u16(_entries.length))
      ..add(_u32(directory.length))
      ..add(_u32(start))
      ..add(_u16(0));
    return body.takeBytes();
  }

  List<int> _u16(int value) => [value & 0xFF, (value >> 8) & 0xFF];

  List<int> _u32(int value) => [
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ];
}
