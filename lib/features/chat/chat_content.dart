import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/i18n/app_strings.dart';
import '../../core/models/chat_message.dart';
import '../../core/util/time_format.dart';

// Presentational chat-content widgets shared by the single-agent chat
// (bot_chat_screen) and the multi-agent swarm chat (group_chat_screen), so both
// render assistant replies the same way: streamed markdown, per-segment
// timestamps, and the collapsible "progress updates" stack. Keeping these in one
// place means a rendering fix lands in both surfaces at once.

/// Renders a multi-message assistant turn. The final message is always shown in
/// full; the agent's earlier phased "thinking" reports are collapsed behind a
/// toggle so they don't drown out the result, but stay one tap away for anyone
/// who wants to follow the reasoning.
class SegmentedContent extends StatefulWidget {
  const SegmentedContent({
    required this.segments,
    required this.color,
    required this.formatInlineEmphasis,
    this.highlightQuery,
    super.key,
  });

  final List<MessageSegment> segments;
  final Color color;
  final bool formatInlineEmphasis;

  /// See [MessageText.highlightQuery].
  final String? highlightQuery;

  @override
  State<SegmentedContent> createState() => _SegmentedContentState();
}

class _SegmentedContentState extends State<SegmentedContent> {
  bool _expanded = false;

  Widget _segmentText(MessageSegment segment) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        MessageText(
          text: segment.text,
          color: widget.color,
          formatInlineEmphasis: widget.formatInlineEmphasis,
          highlightQuery: widget.highlightQuery,
        ),
        if (segment.createdAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              formatShortTime(context, segment.createdAt!.toIso8601String()),
              style: TextStyle(
                fontSize: 11,
                color: widget.color.withValues(alpha: 0.6),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<MessageSegment> nonEmpty = widget.segments
        .where((MessageSegment s) => s.text.trim().isNotEmpty)
        .toList(growable: false);
    if (nonEmpty.isEmpty) return const SizedBox.shrink();
    if (nonEmpty.length == 1) return _segmentText(nonEmpty.first);

    final List<MessageSegment> earlier =
        nonEmpty.sublist(0, nonEmpty.length - 1);
    final MessageSegment last = nonEmpty.last;
    final Color toggleColor = widget.color.withValues(alpha: 0.7);
    // A search hit inside a collapsed progress update would otherwise be marked
    // where nobody can see it, so reveal the stack while it is highlighted.
    final String needle = widget.highlightQuery?.trim().toLowerCase() ?? '';
    final bool expanded = _expanded ||
        (needle.isNotEmpty &&
            earlier.any(
              (MessageSegment s) => s.text.toLowerCase().contains(needle),
            ));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: toggleColor,
                ),
                const SizedBox(width: 4),
                Text(
                  context.l10n.agentProgressUpdates(earlier.length),
                  style: TextStyle(
                    fontSize: 12,
                    color: toggleColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...<Widget>[
          const SizedBox(height: 6),
          for (final MessageSegment segment in earlier) ...<Widget>[
            _segmentText(segment),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Divider(
                height: 1,
                thickness: 1,
                color: widget.color.withValues(alpha: 0.15),
              ),
            ),
          ],
        ] else
          const SizedBox(height: 8),
        _segmentText(last),
      ],
    );
  }
}

class MessageText extends StatefulWidget {
  const MessageText({
    required this.text,
    required this.color,
    required this.formatInlineEmphasis,
    this.highlightQuery,
    super.key,
  });

  final String text;
  final Color color;
  final bool formatInlineEmphasis;

  /// Term to mark inside this message while a "search chats" hit is being
  /// revealed. Null in the normal case, which renders without any marking.
  final String? highlightQuery;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  // Parsing markdown is the costly part of a finished assistant bubble. The
  // chat subtree rebuilds ~12x/sec during a streaming turn, so we cache the
  // built widget and return the same instance unless something it depends on
  // changed. Returning an identical Widget lets Flutter skip rebuilding the
  // MarkdownBody (and re-parsing) entirely. We rebuild on prop changes
  // (didUpdateWidget) and on theme changes (didChangeDependencies).
  Widget? _cached;

  @override
  void didUpdateWidget(MessageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.color != widget.color ||
        oldWidget.formatInlineEmphasis != widget.formatInlineEmphasis ||
        oldWidget.highlightQuery != widget.highlightQuery) {
      _cached = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme (and thus the markdown style sheet) may have changed.
    _cached = null;
  }

  @override
  Widget build(BuildContext context) {
    return _cached ??= _buildContent(context);
  }

  Widget _buildContent(BuildContext context) {
    final TextStyle style = TextStyle(
      color: widget.color,
      height: 1.45,
      fontSize: 15,
    );
    final String needle = widget.highlightQuery?.trim() ?? '';
    if (!widget.formatInlineEmphasis) {
      // Not SelectableText: a wrapping SelectionArea (see the message lists)
      // handles selection. SelectableText / MarkdownBody(selectable: true)
      // build overlay-based selection that registers a dependency on the
      // enclosing Scrollable and throws InheritedElement '_dependents.isEmpty'
      // when the conversation is torn down (e.g. creating/switching a session).
      if (needle.isEmpty) return Text(widget.text, style: style);
      return Text.rich(_markedSpan(widget.text, needle, style));
    }
    return MarkdownBody(
      data: _normalizeAgentMarkdown(widget.text),
      selectable: false,
      softLineBreak: true,
      styleSheet: _markdownStyleSheet(context, widget.color, style),
      // The search term is marked by parsing it as its own inline element, so
      // the surrounding markdown still renders normally around it.
      inlineSyntaxes: needle.isEmpty
          ? null
          : <md.InlineSyntax>[_SearchHitSyntax(needle)],
      builders: needle.isEmpty
          ? const <String, MarkdownElementBuilder>{}
          : <String, MarkdownElementBuilder>{
              _searchHitTag: _SearchHitBuilder(style),
            },
    );
  }
}

// Marker-pen colours rather than scheme colours: the mark has to stay readable
// on both bubble backgrounds (primary for the user, surface for the agent) in
// both themes, and reading as "search highlight" matters more than blending in.
const Color _searchHitBackground = Color(0xFFFFD54F);
const Color _searchHitForeground = Color(0xDD000000);
const String _searchHitTag = 'relaySearchHit';

// Colour only, no weight or size change: the mark comes and goes on its own
// timer and must not reflow the paragraph under it.
TextStyle _searchHitStyle(TextStyle? base) {
  return (base ?? const TextStyle()).copyWith(
    backgroundColor: _searchHitBackground,
    color: _searchHitForeground,
  );
}

/// Splits [text] on every case-insensitive occurrence of [needle], marking the
/// matches. Used for the plain-text (non-markdown) rendering path.
TextSpan _markedSpan(String text, String needle, TextStyle base) {
  final TextStyle hit = _searchHitStyle(base);
  final String haystack = text.toLowerCase();
  final String lowered = needle.toLowerCase();
  final List<TextSpan> spans = <TextSpan>[];
  int cursor = 0;
  while (true) {
    final int at = haystack.indexOf(lowered, cursor);
    if (at < 0) break;
    if (at > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, at)));
    }
    spans.add(
      TextSpan(text: text.substring(at, at + lowered.length), style: hit),
    );
    cursor = at + lowered.length;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(style: base, children: spans);
}

/// Turns each occurrence of the search term into a [_searchHitTag] element so
/// the markdown builder can paint it without disturbing the rest of the parse.
class _SearchHitSyntax extends md.InlineSyntax {
  _SearchHitSyntax(String query)
      : super(RegExp.escape(query), caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text(_searchHitTag, match[0]!));
    return true;
  }
}

class _SearchHitBuilder extends MarkdownElementBuilder {
  _SearchHitBuilder(this.base);

  final TextStyle base;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // parentStyle carries whatever the enclosing markdown (bold, list, heading)
    // resolved to, so the mark keeps the surrounding weight and size.
    return Text.rich(
      TextSpan(
        text: element.textContent,
        style: _searchHitStyle(parentStyle ?? base),
      ),
    );
  }
}

MarkdownStyleSheet _markdownStyleSheet(
  BuildContext context,
  Color color,
  TextStyle base,
) {
  final ColorScheme colors = Theme.of(context).colorScheme;
  final Color codeBackground = colors.surface.withValues(alpha: 0.55);
  final Color borderColor = color.withValues(alpha: 0.20);
  return MarkdownStyleSheet(
    p: base,
    pPadding: EdgeInsets.zero,
    strong: base.copyWith(fontWeight: FontWeight.w700),
    em: base.copyWith(fontStyle: FontStyle.italic),
    h1: base.copyWith(
      fontSize: 21,
      fontWeight: FontWeight.w800,
      height: 1.25,
    ),
    h1Padding: const EdgeInsets.only(top: 4, bottom: 6),
    h2: base.copyWith(
      fontSize: 19,
      fontWeight: FontWeight.w800,
      height: 1.28,
    ),
    h2Padding: const EdgeInsets.only(top: 4, bottom: 5),
    h3: base.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w700,
      height: 1.30,
    ),
    h3Padding: const EdgeInsets.only(top: 3, bottom: 4),
    h4: base.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
    h4Padding: const EdgeInsets.only(top: 3, bottom: 3),
    h5: base.copyWith(fontWeight: FontWeight.w700),
    h5Padding: const EdgeInsets.only(top: 2, bottom: 2),
    h6: base.copyWith(fontWeight: FontWeight.w700),
    h6Padding: const EdgeInsets.only(top: 2, bottom: 2),
    blockSpacing: 8,
    listIndent: 22,
    listBullet: base,
    code: base.copyWith(fontStyle: FontStyle.italic),
    codeblockPadding: const EdgeInsets.all(9),
    codeblockDecoration: BoxDecoration(
      color: codeBackground,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: borderColor),
    ),
    blockquote: base.copyWith(color: color.withValues(alpha: 0.78)),
    blockquotePadding: const EdgeInsets.only(left: 10),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: color.withValues(alpha: 0.45),
          width: 3,
        ),
      ),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: borderColor)),
    ),
  );
}

String _normalizeAgentMarkdown(String raw) {
  final List<String> output = <String>[];
  bool inFence = false;
  String? fenceMarker;
  for (final String line in raw.split('\n')) {
    final String trimmed = line.trimLeft();
    final String? marker = trimmed.startsWith('```')
        ? '```'
        : trimmed.startsWith('~~~')
            ? '~~~'
            : null;
    if (marker != null) {
      if (!inFence) {
        inFence = true;
        fenceMarker = marker;
      } else if (fenceMarker == marker) {
        inFence = false;
        fenceMarker = null;
      }
      output.add(line);
      continue;
    }
    output.add(inFence ? line : _normalizeMarkdownLine(line));
  }
  return output.join('\n');
}

String _normalizeMarkdownLine(String line) {
  final RegExpMatch? heading =
      RegExp(r'^( {0,3})(#{1,6})(?!#)\s*(.*?)\s*#*\s*$').firstMatch(line);
  if (heading != null) {
    final String content = (heading.group(3) ?? '').trim();
    if (content.isNotEmpty) {
      return '${heading.group(1)}${heading.group(2)} $content';
    }
  }

  String value = line.replaceAllMapped(
    RegExp(r'##([^#\n]+?)##'),
    (Match match) => '*${match.group(1)}*',
  );

  final RegExpMatch? boldPrefix =
      RegExp(r'^(\s*)\*\*\s*(\S.*)$').firstMatch(value);
  if (boldPrefix == null) return value;
  final String leadingWhitespace = boldPrefix.group(1) ?? '';
  final int contentStart = leadingWhitespace.length + 2;
  if (value.indexOf('**', contentStart) != -1) return value;
  value = '$leadingWhitespace**${boldPrefix.group(2)}**';
  return value;
}

/// Detects a trailing "pick one of these" prompt at the end of an assistant
/// message: a question line (ending in `?` / `？`) immediately followed by an
/// ordered list (`1.` / `2)` / `a.` …). Returns the cleaned option texts, or
/// null when the text doesn't match. Kept deliberately strict — only a question
/// directly above a closing ordered list qualifies — so ordinary numbered lists
/// in an answer never turn into buttons.
List<String>? parseOptionPrompt(String text) {
  final List<String> lines = text.replaceAll('\r\n', '\n').split('\n');
  int end = lines.length;
  while (end > 0 && lines[end - 1].trim().isEmpty) {
    end--;
  }
  if (end == 0) return null;

  final RegExp item = RegExp(r'^\s*(?:\d{1,2}|[A-Za-z])[.)、]\s+(\S.*)$');
  final List<String> options = <String>[];
  int i = end - 1;
  for (; i >= 0; i--) {
    final RegExpMatch? match = item.firstMatch(lines[i]);
    if (match == null) break;
    options.insert(0, _stripInlineMarkdown(match.group(1)!));
  }
  if (options.length < 2 || options.length > 8) return null;

  // The line directly above the list (skipping blanks) must be the question.
  int q = i;
  while (q >= 0 && lines[q].trim().isEmpty) {
    q--;
  }
  if (q < 0) return null;
  final String question = lines[q];
  if (!question.contains('?') && !question.contains('？')) return null;

  return options;
}

String _stripInlineMarkdown(String value) {
  return value
      .replaceAll(RegExp(r'\*\*|__|[`*]'), '')
      .trim();
}

/// Splits a leading "here's my plan" preamble off an assistant answer so it can
/// be folded away. Claude and Codex often open with one or more "I will …" /
/// "我将 …" planning paragraphs before the real answer. Returns (plan, body) when
/// such a preamble sits above a non-empty body, else null (so a message that is
/// nothing but plan is never hidden).
({String plan, String body})? splitLeadingPlan(String text) {
  final List<String> paras = text.trim().split(RegExp(r'\n\s*\n'));
  if (paras.length < 2) return null;
  final RegExp planStart = RegExp(
    r"^(?:I will\b|I['’]ll\b|I am going to\b|I['’]m going to\b|Let me\b|"
    r'First[,，]|我将|我会|我先|我打算|我准备|让我|接下来我)',
    caseSensitive: false,
  );
  int i = 0;
  while (i < paras.length && planStart.hasMatch(paras[i].trimLeft())) {
    i++;
  }
  if (i == 0 || i >= paras.length) return null;
  return (
    plan: paras.sublist(0, i).join('\n\n'),
    body: paras.sublist(i).join('\n\n'),
  );
}

/// A default-collapsed disclosure used to tuck an agent's "thinking" (a plan
/// preamble or its execution steps) under a one-line toggle, matching the
/// styling of [SegmentedContent]'s progress-updates toggle.
class CollapsibleNote extends StatefulWidget {
  const CollapsibleNote({
    required this.title,
    required this.color,
    required this.child,
    super.key,
  });

  final String title;
  final Color color;
  final Widget child;

  @override
  State<CollapsibleNote> createState() => _CollapsibleNoteState();
}

class _CollapsibleNoteState extends State<CollapsibleNote> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final Color toggle = widget.color.withValues(alpha: 0.7);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: toggle,
                ),
                const SizedBox(width: 4),
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 12,
                    color: toggle,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: widget.child,
          ),
      ],
    );
  }
}

/// Renders the choices from [parseOptionPrompt] as tappable buttons. Tapping one
/// sends its text as the next user message (wired by the host screen).
class OptionButtons extends StatelessWidget {
  const OptionButtons({
    required this.options,
    required this.color,
    required this.onSelected,
    super.key,
  });

  final List<String> options;
  final Color color;
  final void Function(String option) onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final String option in options)
            OutlinedButton(
              onPressed: () => onSelected(option),
              style: OutlinedButton.styleFrom(
                foregroundColor: color,
                side: BorderSide(color: color.withValues(alpha: 0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(option),
            ),
        ],
      ),
    );
  }
}

class ProgressLines extends StatelessWidget {
  const ProgressLines({
    required this.lines,
    required this.color,
    super.key,
  });

  final List<String> lines;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final String line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    line,
                    style: TextStyle(
                      color: color.withValues(alpha: 0.72),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class MessageStatus extends StatelessWidget {
  const MessageStatus({
    required this.icon,
    required this.text,
    required this.color,
    super.key,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          icon,
          size: 14,
          color: color.withValues(alpha: 0.68),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            color: color.withValues(alpha: 0.72),
            fontSize: 12,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

class TypingDots extends StatefulWidget {
  const TypingDots({required this.color, super.key});

  final Color color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double _opacity(double t, int i) {
    final double offset = i * 0.18;
    final double phase = (t - offset) % 1.0;
    final double wrapped = phase < 0 ? phase + 1.0 : phase;
    if (wrapped < 0.5) return 0.35 + 0.65 * (wrapped * 2);
    return 0.35 + 0.65 * ((1.0 - wrapped) * 2);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (BuildContext context, Widget? _) {
          final double t = _ctrl.value;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List<Widget>.generate(3, (int i) {
              return Padding(
                padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
                child: Opacity(
                  opacity: _opacity(t, i),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: widget.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
