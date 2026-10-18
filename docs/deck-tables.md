# Editable slide tables

The deck model, workspace preview and PPTX writer share `Slide.table`.
`SlideTable` stores a rectangular matrix of text cells and a `headerRow` flag.
Existing slide JSON without `table` continues to load and export as before.

## Agent workflow

1. `create_deck` creates a deck and returns its id.
2. `add_slide` appends a page with its title, bullets and optional image id.
3. `add_table` attaches a table to that page using a zero-based index:

```json
{
  "deck": "<id returned by create_deck>",
  "index": 0,
  "rows": [["Product", "Price"], ["A", "9.9"], ["B", "19.9"]],
  "header_row": true
}
```

4. `finish_deck` marks the completed deck.

Each slide holds one table. Calling `add_table` again replaces it. Updating
slide text with `update_slide` preserves its image and table. Invalid calls
return a useful tool result and leave the existing slide unchanged.

Tables support 1–12 rows, 1–8 equal-width columns and up to 500 UTF-16 code
units per cell. Rows must have identical column counts and every cell must
be a string. Empty text, Unicode and explicit line breaks are supported.
Input is deeply copied and protected against later list mutations.
The agent turn budget allows up to 32 model requests, so sequential table
tools can complete a multi-page deck within one turn.

## Layout and export

The table uses the text column below the title. When bullets are present,
they receive the top 35% of the body and the table uses the remaining area
after a gap. Images keep their right-hand column. The preview scales the
table to its available area. Export chooses cell font sizes from the text and
available space, with a minimum of 1pt. Very dense tables can become difficult
to read. If explicit lines still cannot fit at 1pt, export reports the cell's
row/column and asks for shorter content or a split table. Keep cell text
concise and split dense tables across slides for legibility.

PPTX output uses native `p:graphicFrame` / `a:tbl` DrawingML, including a
column grid, rows and individual editable cell text bodies. Header cells have
explicit fills and bold text. XML escaping and invalid-character filtering
apply to every cell; CRLF and CR are normalized into DrawingML paragraphs.
The existing text, picture, media relationship and ZIP writer are reused.

The basic interface provides text cells, optional header styling and a fixed
grid. Merged cells, formulas, rich text, custom widths/heights, per-cell styles,
multiple tables per page and automatic pagination remain future work.

## Verification

`flutter analyze` and `flutter test` cover model compatibility and validation,
tool protocol dispatch, error recovery, workspace updates, bounded preview
layout and native OOXML structure. Export tests parse XML, check namespaces
and element order, verify row/column dimensions and shape ids, and read back
ZIP entries with CRC validation.

Create reproducible smoke fixtures without connecting to an AI service:

```sh
dart run scripts/table_smoke.dart /tmp/imagyn-table-smoke
```

Independent client checks used LibreOfficeDev 26.8.0.0.alpha0, python-pptx and
lxml. Both page ratios, mixed text/images/tables and the maximum grid were
opened, rendered to PDF and saved back to PPTX. Native table objects and exact
cell text survived round trips, including 500-character cells and emoji.
Changing one cell with python-pptx preserved every other cell's contents.
These checks found and fixed automatic row expansion from long cell text.

PowerPoint and WPS require their own open/edit validation. Font substitution
and other client versions can affect wrapping and legibility; the checks
above establish the behavior of those specific tested tools and fixtures.
