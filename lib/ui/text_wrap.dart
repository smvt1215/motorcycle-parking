import 'package:flutter/widgets.dart';

/// Line breaking that Chinese text needs and the engine does not give
/// (#467): it may break between any two characters, so a title can end on
/// one lone character and 臺北市中山區 can split between 市 and 中.

/// The style [Text] would lay [style] out in here, bold text included.
TextStyle _effectiveStyle(BuildContext context, TextStyle? style) {
  var effective = DefaultTextStyle.of(context).style.merge(style);
  if (MediaQuery.boldTextOf(context)) {
    effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
  }
  return effective;
}

TextPainter _painter(BuildContext context, String text, TextStyle style) =>
    TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    );

/// The characters on [painter]'s last line, spaces left out.
int _lastLineLength(TextPainter painter, String text) {
  final last = painter.computeLineMetrics().last;
  final start = painter
      .getPositionForOffset(Offset(0, last.baseline - last.ascent + 1))
      .offset;
  return text.substring(start).trim().characters.length;
}

/// A [Text] that never leaves one character alone on its last line. When
/// it would, it first takes the narrowest width that keeps its number of
/// lines, so its lines even out; where that still ends on one character
/// (a break the line rules force, as before 區 in 「・3 區」), the line
/// before gives up its last character. The words are the same, and a
/// screen reader hears them as they are; only where the lines break moves.
class NoOrphanText extends StatelessWidget {
  const NoOrphanText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  /// How [data] is laid out at most [maxWidth] wide without an orphan:
  /// the narrower [width] to give it, or the [text] with a line break
  /// moved earlier; null where it has none to fix.
  static ({double? width, String text})? layout(
    BuildContext context,
    String data,
    TextStyle? style,
    double maxWidth, {
    int? maxLines,
  }) {
    if (!maxWidth.isFinite || data.characters.length < 3) return null;
    final effective = _effectiveStyle(context, style);
    final painter = _painter(context, data, effective)..maxLines = maxLines;
    bool orphaned() =>
        painter.computeLineMetrics().length > 1 &&
        !painter.didExceedMaxLines &&
        _lastLineLength(painter, data) < 2;
    try {
      painter.layout(maxWidth: maxWidth);
      if (!orphaned()) return null;
      final lines = painter.computeLineMetrics().length;
      var low = 0.0, high = maxWidth;
      while (high - low > .5) {
        final mid = (low + high) / 2;
        painter.layout(maxWidth: mid);
        if (painter.computeLineMetrics().length == lines &&
            !painter.didExceedMaxLines) {
          high = mid;
        } else {
          low = mid;
        }
      }
      final width = high.ceilToDouble().clamp(0.0, maxWidth);
      painter.layout(maxWidth: width);
      if (!orphaned()) return (width: width, text: data);

      // Move the last line's break back one character.
      painter.layout(maxWidth: maxWidth);
      final last = painter.computeLineMetrics().last;
      var at = painter
          .getPositionForOffset(Offset(0, last.baseline - last.ascent + 1))
          .offset;
      while (at > 0 && data[at - 1].trim().isEmpty) {
        at--;
      }
      if (at < 2) return null;
      at--;
      // Never between the halves of a surrogate pair.
      final unit = data.codeUnitAt(at);
      if (unit >= 0xdc00 && unit <= 0xdfff && at > 1) at--;
      final moved =
          '${data.substring(0, at).trimRight()}\n${data.substring(at)}';
      final check = _painter(context, moved, effective)
        ..maxLines = maxLines
        ..layout(maxWidth: maxWidth);
      final fits =
          !check.didExceedMaxLines &&
          check.computeLineMetrics().length == lines;
      check.dispose();
      return fits ? (width: null, text: moved) : null;
    } finally {
      painter.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final fixed = layout(
        context,
        data,
        style,
        box.maxWidth,
        maxLines: maxLines,
      );
      final shown = fixed?.text ?? data;
      final text = Text(
        shown,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        semanticsLabel: shown == data ? null : data,
      );
      final width = fixed?.width;
      if (width == null) return text;
      final end = textAlign == TextAlign.end || textAlign == TextAlign.right;
      return Align(
        alignment: end
            ? AlignmentDirectional.topEnd
            : AlignmentDirectional.topStart,
        widthFactor: 1,
        heightFactor: 1,
        child: SizedBox(width: width, child: text),
      );
    },
  );
}

/// A [Text] of groups joined by [separator] (「路外停車場　臺北市中山區　500 m」)
/// where a group that fits on a line is never split: it moves to the next
/// line whole. A screen reader hears the text as it is.
class KeepGroupsText extends StatelessWidget {
  const KeepGroupsText(
    this.data, {
    super.key,
    this.style,
    this.separator = '\u3000',
  });
  final String data;
  final TextStyle? style;
  final String separator;

  /// [data] with a line break before each group that would otherwise be
  /// split at [maxWidth].
  static String lines(
    BuildContext context,
    String data,
    TextStyle? style,
    double maxWidth, {
    String separator = '\u3000',
  }) {
    final groups = data.split(separator);
    if (groups.length < 2 || !maxWidth.isFinite) return data;
    final effective = _effectiveStyle(context, style);
    var text = data;
    var start = 0;
    for (final (i, group) in groups.indexed) {
      if (i > 0 && group.isNotEmpty) {
        final painter = _painter(context, text, effective)
          ..layout(maxWidth: maxWidth);
        final tops = painter
            .getBoxesForSelection(
              TextSelection(
                baseOffset: start,
                extentOffset: start + group.length,
              ),
            )
            .map((b) => b.top.round())
            .toSet();
        painter.dispose();
        if (tops.length > 1) {
          final alone = _painter(context, group, effective)
            ..layout(maxWidth: maxWidth);
          final fits = alone.computeLineMetrics().length == 1;
          alone.dispose();
          if (fits) {
            final at = start - separator.length;
            text = '${text.substring(0, at)}\n${text.substring(start)}';
            start += 1 - separator.length;
          }
        }
      }
      start += group.length + separator.length;
    }
    return text;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final shown = lines(
        context,
        data,
        style,
        box.maxWidth,
        separator: separator,
      );
      return Text(
        shown,
        style: style,
        semanticsLabel: shown == data ? null : data,
      );
    },
  );
}
