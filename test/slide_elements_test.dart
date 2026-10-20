import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/pptx.dart';

import 'support/pptx_archive.dart';

SlideElement _text({
  String id = 'e1',
  double x = .06,
  double y = .1,
  double width = .6,
  double height = .2,
  double radius = 0,
  String color = '1F1B2E',
  String align = 'left',
}) => SlideElement(
  id: id,
  kind: SlideElementKind.text,
  text: '标题',
  x: x,
  y: y,
  width: width,
  height: height,
  fontSize: 44,
  color: color,
  align: align,
  radius: radius,
);

SlideElement _image({
  String id = 'e2',
  double x = .06,
  double y = .4,
  double width = .4,
  double height = .5,
  String fit = 'cover',
}) => SlideElement(
  id: id,
  kind: SlideElementKind.image,
  imageId: 'img',
  x: x,
  y: y,
  width: width,
  height: height,
  fit: fit,
);

void main() {
  final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0, 0, 0, 13, 73, 72, 68, 82,
  ]);

  test('an element round-trips through JSON with its style intact', () {
    final element = SlideElement(
      id: 'e1',
      kind: SlideElementKind.text,
      text: '封面\n副标题',
      x: .1,
      y: .2,
      width: .5,
      height: .3,
      fontSize: 40,
      color: '#ffffff',
      bold: true,
      align: 'center',
      fill: '1f1b2e',
      border: '7863c7',
      radius: .2,
    );
    expect(element.color, 'FFFFFF');
    expect(element.fill, '1F1B2E');

    final restored = SlideElement.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(jsonEncode(element.toJson())) as Map,
      ),
    );
    expect(restored.toJson(), element.toJson());
    expect(restored.kind, SlideElementKind.text);
    expect(restored.text, '封面\n副标题');
    expect(restored.bold, isTrue);
    expect(restored.radius, .2);
  });

  test('an element outside the page is rejected, not written', () {
    expect(() => _text(x: .8, width: .4), throwsFormatException);
    expect(() => _text(y: .9, height: .3), throwsFormatException);
    expect(() => _text(width: 0), throwsFormatException);
    expect(() => _text(radius: .6), throwsFormatException);
    expect(() => _text(color: 'red'), throwsFormatException);
    expect(() => _text(align: 'justify'), throwsFormatException);
    expect(
      () => SlideElement(
        id: '',
        kind: SlideElementKind.text,
        x: 0,
        y: 0,
        width: 1,
        height: 1,
      ),
      throwsFormatException,
    );
    expect(
      () => SlideElement(
        id: 'e1',
        kind: SlideElementKind.image,
        imageId: '',
        x: 0,
        y: 0,
        width: 1,
        height: 1,
      ),
      throwsFormatException,
    );
  });

  test('a slide keeps its elements through JSON', () {
    final slide = Slide(
      title: '页面',
      elements: [_text(), _image()],
    );
    final restored = Slide.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(jsonEncode(slide.toJson())) as Map,
      ),
    );
    expect(restored.elements, hasLength(2));
    expect(restored.elements.first.text, '标题');
    expect(restored.elements.last.imageId, 'img');
    expect(restored.elements.last.fit, 'cover');
  });

  test('the export writes text boxes and pictures as editable shapes', () {
    final deck = Deck(
      id: 'deck',
      title: '自由排版',
      slides: [
        Slide(
          elements: [
            _text(
              align: 'center',
              radius: .15,
              color: 'FFFFFF',
            ),
            SlideElement(
              id: 'e2',
              kind: SlideElementKind.text,
              text: '标签',
              x: .7,
              y: .7,
              width: .2,
              height: .1,
              fontSize: 18,
              fill: 'F4F2FA',
              border: 'DCD7EA',
              align: 'right',
            ),
            _image(),
            _image(id: 'e3', x: .55, fit: 'contain'),
          ],
        ),
      ],
    );
    final files = unzipPptx(
      buildPptx(deck, {
        'img': PptxImage(
          bytes: png,
          mime: 'image/png',
          width: 1600,
          height: 900,
        ),
      }),
    );

    final slide = utf8.decode(files['ppt/slides/slide1.xml']!);
    expect(slide, contains('<a:t>标题</a:t>'));
    expect(slide, contains('<a:t>标签</a:t>'));
    expect(slide, contains('sz="4400"'));
    expect(slide, contains('sz="1800"'));
    expect(slide, contains('algn="ctr"'));
    expect(slide, contains('algn="r"'));
    expect(slide, contains('prst="roundRect"'));
    expect(slide, contains('<a:srgbClr val="FFFFFF"/>'));
    expect(slide, contains('<a:srgbClr val="F4F2FA"/>'));

    // Two pictures, both pointing at the single embedded file, and the cover
    // box crops the 16:9 source to 1.42:1 instead of stretching it.
    expect('<p:pic>'.allMatches(slide), hasLength(2));
    expect('r:embed="rId2"'.allMatches(slide), hasLength(2));
    expect(
      slide,
      contains('<a:srcRect l="0" t="10000" r="0" b="10000"/>'),
    );
    // `contain` shrinks the shape to the source ratio inside the box.
    expect(slide, contains('cx="4876800" cy="2743200"'));

    expect(files.containsKey('ppt/media/image1.png'), isTrue);
    final rels = utf8.decode(files['ppt/slides/_rels/slide1.xml.rels']!);
    expect('relationships/image"'.allMatches(rels), hasLength(1));
  });

  test('a 4:3 page keeps the same element fractions', () {
    final deck = Deck(
      id: 'deck',
      title: '4:3',
      aspectRatio: '4:3',
      slides: [
        Slide(elements: [_text(x: .5, y: .5, width: .5, height: .5)]),
      ],
    );
    final files = unzipPptx(buildPptx(deck, {}));
    final slide = utf8.decode(files['ppt/slides/slide1.xml']!);
    // Half the 9144000 EMU width, half the 6858000 EMU height.
    expect(
      slide,
      contains('<a:off x="4572000" y="3429000"/>'
          '<a:ext cx="4572000" cy="3429000"/>'),
    );
  });

  test('the built-in prompt and tool list describe the element tools', () {
    expect(builtInAgentPrompt, contains('add_text'));
    expect(builtInAgentPrompt, contains('add_image'));
    expect(builtInAgentPrompt, contains('remove_element'));
    expect(
      agentTools.map((tool) => tool['name']),
      containsAll(['add_text', 'add_image', 'remove_element']),
    );
  });
}
