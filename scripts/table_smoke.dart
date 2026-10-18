// Generate native table fixtures for manual Office open/edit/save validation.
// Run: dart run scripts/table_smoke.dart [output-directory]
// Dense cells intentionally exercise very small type; split real content into
// more slides when the resulting text would be difficult to read.
import 'dart:convert';
import 'dart:io';

import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/pptx.dart';

void main(List<String> args) {
  if (args.length > 1) {
    stderr.writeln(
      'Usage: dart run scripts/table_smoke.dart [output-directory]',
    );
    exitCode = 64;
    return;
  }
  final output = Directory(
    args.isEmpty ? '/tmp/imagyn-table-smoke' : args.single,
  )..createSync(recursive: true);
  final images = {
    'sample': PptxImage(
      bytes: base64Decode(_samplePng),
      mime: 'image/png',
      width: 160,
      height: 90,
    ),
  };
  final slides = [
    Slide(
      title: '原生可编辑表格',
      table: SlideTable(
        rows: [
          ['项目', '说明', '数值'],
          ['中文与空格', '  Leading and trailing  ', '42'],
          ['XML < & >', '第一行\n第二行\n\n末行', '😀'],
        ],
      ),
    ),
    Slide(
      title: '标题、要点、图片和表格',
      bullets: ['各对象保持独立', '标题行采用显式样式'],
      imageId: 'sample',
      table: SlideTable(
        rows: [
          ['名称', '价格'],
          ['基础', '9.9'],
          ['标准', '19.9'],
        ],
      ),
    ),
    Slide(
      title: '无标题行与单格边界',
      table: SlideTable(
        rows: [
          ['  首尾空格  \n\n段落\n末行'],
        ],
        headerRow: false,
      ),
    ),
    _denseSlide('12 × 8 上限与长文本', List.filled(100, '长文本验证').join()),
  ];
  for (final ratio in ['16:9', '4:3']) {
    final suffix = ratio == '16:9' ? '' : '-4x3';
    _write(
      output,
      'imagyn-table$suffix.pptx',
      Deck(
        id: 'table',
        title: 'Imagyn table smoke',
        aspectRatio: ratio,
        slides: slides,
      ),
      images,
    );
  }
  _write(
    output,
    'dense-mixed.pptx',
    Deck(
      id: 'dense',
      title: 'Dense mixed table smoke',
      aspectRatio: '4:3',
      slides: [
        _denseSlide(
          '500 Latin characters',
          List.filled(500, 'W').join(),
          withImage: true,
        ),
        _denseSlide('500 中文字符', List.filled(500, '中').join(), withImage: true),
        _denseSlide(
          '250 emoji / 500 UTF-16 units',
          List.filled(250, '😀').join(),
          withImage: true,
        ),
      ],
    ),
    images,
  );
}

Slide _denseSlide(String title, String text, {bool withImage = false}) => Slide(
  title: title,
  bullets: ['完整保留单元格内容；检查表格位于页面内'],
  imageId: withImage ? 'sample' : null,
  table: SlideTable(
    rows: List.generate(
      12,
      (row) => List.generate(
        8,
        (column) => row == 1 && column == 1 ? text : '$row,$column',
      ),
    ),
  ),
);

void _write(
  Directory output,
  String name,
  Deck deck,
  Map<String, PptxImage> images,
) {
  final file = File('${output.path}/$name');
  file.writeAsBytesSync(buildPptx(deck, images));
  stdout.writeln('${file.absolute.path} (${deck.slides.length} slides)');
}

// A valid 160 × 90 PNG keeps the fixture self-contained and dependency-free.
const _samplePng =
    'iVBORw0KGgoAAAANSUhEUgAAAKAAAABaCAIAAACwpMoFAAAB9klEQVR4nO3czU3DQBRF'
    '4QmiFmpAoh0aYEkFLGmALqgBiQKyoof0wMIblMj5Gezxu0fnbJ1YT+/TyFGkZPe5'
    'PzTjdrf1ALZuAsMTGJ7A8ASGJzA8geEJDE9gePfnL3+9/4yZw/7T08vD3CVPMDyB'
    '4QkMT2B4AsMTGJ7A8ASGJzC8C99kMXr7eJy79Pr8PXKS8WGBz6DOvQyJDQS+knbu'
    'jTBmFHA37elNMMwQ4EVoT28IYCZ8il5cd8CdhxUPvLZBunE28JjtRxsHA4/ce65x'
    'KvD4jYcaRwJvtetE4zzgbbccZ5wHbDcVBlzhAFWY4frCgO3WkoDrHJ06k1wsCdg6i'
    'gGudmiqzTNXDLD1JTA8geFlANd84NWc6qgMYOtOYHgCwxMYnsDwBIYnMDyB4WUA1/y'
    'FQc2pjsoAtu4EhicwvBjgag+8avPMFQNsfSUB1zk0dSa5WBKwdRQGXOHoVJjh+sKA'
    '7dbygLc9QFnHtyUCt+22HKfbQoHbFrtO1G25wG3sxkN1WzRwG7X3XN2WDtzW3360'
    'bgMAtzUN0nUb5q8MJ4kFf2oAoJ2CAE8twoyhnUIBT3Uzw2ingMBTf7X8x3d4eMUz'
    'ET5F25kEhicwPIHhCQxPYHgCwxMYnsDwdp/7w9Yz2Ip5guEJDE9geALDExiewPAE'
    'hicwvF/8m3NWgTUP7AAAAABJRU5ErkJggg==';
