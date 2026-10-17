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

/// Builds a real Office Open XML presentation: every slide is a text frame
/// and, when it has one, a picture — not an image of a slide. PowerPoint,
/// WPS and Keynote can open the result and keep editing it.
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
    final id = slide.imageId;
    final image = id == null ? null : images[id];
    if (id != null && image != null) {
      final part = media.putIfAbsent(id, () => _Media(media.length + 1, image));
      used[id] = part;
    }
    slides.add(
      _SlideParts(
        number: i + 1,
        xml: _slideXml(slide, i + 1, size, image, used.values.toList()),
        images: used.values.toList(),
      ),
    );
  }

  final zip = _ZipBuilder()
    ..add(
      '[Content_Types].xml',
      _contentTypes(
        media.values.map((part) => part.image.mime).toSet(),
        slides.length,
      ),
    )
    ..add('_rels/.rels', _rootRels())
    ..add('ppt/presentation.xml', _presentationXml(slides.length, size))
    ..add('ppt/_rels/presentation.xml.rels', _presentationRels(slides.length))
    ..add('ppt/slideMasters/slideMaster1.xml', _slideMasterXml())
    ..add(
      'ppt/slideMasters/_rels/slideMaster1.xml.rels',
      _slideMasterRels(),
    )
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
    ..add('ppt/theme/theme1.xml', _themeXml());

  for (final slide in slides) {
    zip.add('ppt/slides/slide${slide.number}.xml', slide.xml);
    zip.add(
      'ppt/slides/_rels/slide${slide.number}.xml.rels',
      _relationshipXml([
        _Relationship('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'),
        for (var i = 0; i < slide.images.length; i++)
          _Relationship(
            'rId${i + 2}',
            'image',
            '../media/image${slide.images[i].number}.${_extension(slide.images[i].image.mime)}',
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

String _contentTypes(Set<String> imageMimes, int slideCount) {
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
    '</p:sldMasterIdLst>',
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
  List<_Media> images,
) {
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

  final shapes = StringBuffer();
  var id = 2;
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
    for (final bullet in slide.bullets)
      if (bullet.trim().isNotEmpty) bullet.trim(),
  ];
  if (bullets.isNotEmpty) {
    shapes.write(
      _textShape(
        id: id++,
        name: 'Content ${number - 1}',
        x: margin,
        y: bodyTop,
        cx: textWidth,
        cy: bodyHeight,
        paragraphs: [
          for (final bullet in bullets)
            _bulletParagraph(bullet, bodySize, '3B3650'),
        ],
      ),
    );
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

  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sld '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
      '<p:cSld>'
      '<p:bg><p:bgPr><a:solidFill><a:srgbClr val="FBFAFE"/></a:solidFill>'
      '<a:effectLst/></p:bgPr></p:bg>'
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
}) => '<p:sp>'
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

String _run(String text, int size, bool bold, String color) =>
    '<a:rPr lang="zh-CN" sz="$size" b="${bold ? 1 : 0}" dirty="0">'
    '<a:solidFill><a:srgbClr val="$color"/></a:solidFill>'
    '<a:latin typeface="Aptos"/><a:ea typeface="Microsoft YaHei"/>'
    '</a:rPr><a:t>${_esc(text)}</a:t>';

String _bulletParagraph(String text, int size, String color) =>
    '<a:p><a:pPr marL="342900" indent="-342900">'
    '<a:lnSpc><a:spcPct val="115000"/></a:lnSpc>'
    '<a:buFont typeface="Arial"/><a:buChar char="•"/></a:pPr>'
    '<a:r>${_run(text, size, false, color)}</a:r></a:p>';

String _pictureShape({
  required int id,
  required String name,
  required String embed,
  required int x,
  required int y,
  required int cx,
  required int cy,
}) => '<p:pic>'
    '<p:nvPicPr><p:cNvPr id="$id" name="${_esc(name)}"/>'
    '<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/>'
    '</p:nvPicPr>'
    '<p:blipFill><a:blip r:embed="$embed"/>'
    '<a:stretch><a:fillRect/></a:stretch></p:blipFill>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$cx" cy="$cy"/>'
    '</a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>'
    '</p:pic>';

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
        if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) {
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
