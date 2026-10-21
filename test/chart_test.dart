import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/pptx.dart';

import 'support/pptx_archive.dart';

SlideChart _chart({
  String kind = 'bar',
  String title = '',
  List<String> categories = const ['Q1', 'Q2'],
  List<ChartSeries>? series,
}) => SlideChart(
  kind: kind,
  title: title,
  categories: categories,
  series:
      series ??
      [
        ChartSeries(name: '2025', values: const [3, 5]),
      ],
);

void main() {
  test('chart JSON round trips with its slide', () {
    final slide = Slide(
      title: '销售',
      bullets: const ['要点'],
      chart: SlideChart(
        kind: 'line',
        title: '季度销量',
        categories: const ['一季度', '二季度'],
        series: [
          ChartSeries(name: '今年', values: const [10, 20.5]),
          ChartSeries(name: '去年', values: const [8, 15]),
        ],
      ),
    );
    final copy = Slide.fromJson(
      jsonDecode(jsonEncode(slide.toJson())) as Map<String, dynamic>,
    );
    expect(copy.toJson(), slide.toJson());
    expect(copy.chart!.kind, 'line');
    expect(copy.chart!.title, '季度销量');
    expect(copy.chart!.categories, ['一季度', '二季度']);
    expect(copy.chart!.series, hasLength(2));
    expect(copy.chart!.series.first.name, '今年');
    expect(copy.chart!.series.first.values, [10.0, 20.5]);

    final plain = Slide.fromJson(const {
      'title': 'No chart',
      'bullets': <String>[],
    });
    expect(plain.chart, isNull);
    expect(plain.toJson(), {'title': 'No chart', 'bullets': <String>[]});
  });

  test('chart validation rejects malformed data', () {
    expect(
      () => _chart(kind: 'bubble'),
      throwsFormatException,
      reason: 'kind',
    );
    expect(
      () => _chart(categories: const []),
      throwsFormatException,
      reason: 'empty categories',
    );
    expect(
      () => _chart(categories: const ['Q1', 'Q2'], series: [
        ChartSeries(name: 'ragged', values: const [1]),
      ]),
      throwsFormatException,
      reason: 'ragged values',
    );
    expect(
      () => _chart(series: [
        for (var i = 0; i < SlideChart.maxSeries + 1; i++)
          ChartSeries(name: 'S$i', values: const [1, 2]),
      ]),
      throwsFormatException,
      reason: 'too many series',
    );
    expect(
      () => _chart(categories: const ['  ']),
      throwsFormatException,
      reason: 'blank category',
    );
    expect(
      () => _chart(categories: ['x' * (SlideChart.maxLabelLength + 1)]),
      throwsFormatException,
      reason: 'long category',
    );
    expect(
      () => ChartSeries(name: 'bad', values: const [double.nan]),
      throwsFormatException,
      reason: 'not finite',
    );
    expect(
      () => ChartSeries(name: 'bad', values: const [1e10]),
      throwsFormatException,
      reason: 'out of range',
    );
    expect(
      () => SlideChart.fromJson(const {
        'kind': 'bar',
        'categories': ['Q1'],
        'series': [
          {'name': 'missing values'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('add_chart is offered with a strict schema', () {
    final tool = agentTools.firstWhere((tool) => tool['name'] == 'add_chart');
    final parameters = tool['parameters'] as Map;
    expect(
      parameters['required'],
      containsAll(['deck', 'index', 'kind', 'title', 'categories', 'series']),
    );
    expect(parameters['additionalProperties'], isFalse);
    final series = (parameters['properties'] as Map)['series'] as Map;
    final items = series['items'] as Map;
    expect(items['required'], ['name', 'values']);
    expect(items['additionalProperties'], isFalse);
    expect(builtInAgentPrompt, contains('add_chart'));
  });

  test('export writes native charts, relationships and content types', () {
    final deck = Deck(
      id: 'deck',
      title: 'Charts',
      slides: [
        Slide(
          title: 'Bars',
          notes: 'note',
          imageId: 'img',
          chart: _chart(title: 'Sales'),
        ),
        Slide(
          title: 'Line',
          chart: _chart(
            kind: 'line',
            categories: const ['Jan', 'Feb', 'Mar'],
            series: [
              ChartSeries(name: 'Trend', values: const [1, 4, 2.5]),
            ],
          ),
        ),
        Slide(
          title: 'Pie',
          chart: _chart(
            kind: 'pie',
            categories: const ['A', 'B'],
            series: [
              ChartSeries(name: 'Share', values: const [2, 3]),
              ChartSeries(name: 'Hidden', values: const [9, 9]),
            ],
          ),
        ),
      ],
    );
    final png = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0, 0, 0, 13, 73, 72, 68, 82,
    ]);
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

    for (var number = 1; number <= 3; number++) {
      expect(files, contains('ppt/charts/chart$number.xml'));
      final rels = utf8.decode(
        files['ppt/slides/_rels/slide$number.xml.rels']!,
      );
      expect(rels, contains('../charts/chart$number.xml'));
      expect(
        rels,
        contains(
          'http://schemas.openxmlformats.org/officeDocument/2006/'
          'relationships/chart',
        ),
      );
      expect(
        utf8.decode(files['ppt/slides/slide$number.xml']!),
        contains(
          '<c:chart xmlns:c="http://schemas.openxmlformats.org/'
          'drawingml/2006/chart" r:id=',
        ),
      );
    }

    final types = utf8.decode(files['[Content_Types].xml']!);
    for (var number = 1; number <= 3; number++) {
      expect(types, contains('PartName="/ppt/charts/chart$number.xml"'));
    }
    expect(
      types,
      contains(
        'ContentType="application/vnd.openxmlformats-officedocument.'
        'drawingml.chart+xml"',
      ),
    );

    final bar = utf8.decode(files['ppt/charts/chart1.xml']!);
    expect(bar, contains('<c:barChart>'));
    expect(bar, contains('<c:barDir val="col"/>'));
    expect(bar, contains('<c:grouping val="clustered"/>'));
    expect(bar, contains('<c:v>Q1</c:v>'));
    expect(bar, contains('<c:v>Q2</c:v>'));
    expect(bar, contains('<c:v>3</c:v>'));
    expect(bar, contains('<c:v>5</c:v>'));
    expect(bar, contains('<c:v>2025</c:v>'));
    expect(bar, contains('<c:plotVisOnly val="1"/>'));
    expect(bar, contains('<c:dispBlanksAs val="gap"/>'));
    expect(bar, contains('<c:catAx>'));
    expect(bar, contains('<c:valAx>'));

    final line = utf8.decode(files['ppt/charts/chart2.xml']!);
    expect(line, contains('<c:lineChart>'));
    expect(line, contains('<c:v>Jan</c:v>'));
    expect(line, contains('<c:v>2.5</c:v>'));

    final pie = utf8.decode(files['ppt/charts/chart3.xml']!);
    expect(pie, contains('<c:pieChart>'));
    expect(pie, contains('<c:v>Share</c:v>'));
    expect(pie, isNot(contains('Hidden')));
    expect('<c:ser>'.allMatches(pie), hasLength(1));

    // Confirmation comes after layout, image and notes relationships.
    final slide1Rels = utf8.decode(
      files['ppt/slides/_rels/slide1.xml.rels']!,
    );
    expect(slide1Rels, contains('Id="rId2"'));
    expect(slide1Rels, contains('Id="rId3"'));
    expect(slide1Rels, contains('Id="rId4"'));
    expect(slide1Rels, contains('Target="../charts/chart1.xml"'));
    expect(
      utf8.decode(files['ppt/slides/slide1.xml']!),
      contains('r:id="rId4"'),
    );
  });
}
