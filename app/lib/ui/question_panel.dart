import 'package:flutter/material.dart';

import '../model/question.dart';

/// The TUI-style question panel for the agent's `question` tool (issue #50).
/// One card per pending [QuestionForm], each rendering its questions in the
/// form's field order. The service's internal `q0`/`q1` field keys never
/// appear here — the panel collects the answers per question (the selected
/// option labels, or a typed free text) and hands them to [onSubmit] in the
/// form's order.
///
/// Mirrors [PermissionBanner] (spec §6): rendered by the structured view with
/// the pending list as the initial state, kept live by the `form.created` /
/// `form.replied` / `form.cancelled` events.
class QuestionPanel extends StatelessWidget {
  const QuestionPanel({
    super.key,
    required this.pending,
    required this.onSubmit,
    required this.onDismiss,
    this.busyId,
  });

  /// The forms awaiting an answer (or a dismissal); empty renders nothing.
  final List<QuestionForm> pending;

  /// Submit the answers to [form] (one entry per question, in the form's
  /// field order).
  final Future<void> Function(QuestionForm form, List<List<String>> answers)
  onSubmit;

  /// Dismiss [form] (the agent continues without an answer).
  final Future<void> Function(QuestionForm form) onDismiss;

  /// The form with an action in flight: its card shows progress instead of
  /// the Submit / Dismiss buttons.
  final String? busyId;

  @override
  Widget build(BuildContext context) {
    if (pending.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('question-banner'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final form in pending)
            _QuestionFormCard(
              key: ValueKey('question-row-${form.id}'),
              form: form,
              busy: busyId == form.id,
              onSubmit: (answers) => onSubmit(form, answers),
              onDismiss: () => onDismiss(form),
            ),
        ],
      ),
    );
  }
}

class _QuestionFormCard extends StatefulWidget {
  const _QuestionFormCard({
    super.key,
    required this.form,
    required this.busy,
    required this.onSubmit,
    required this.onDismiss,
  });

  final QuestionForm form;
  final bool busy;
  final void Function(List<List<String>> answers) onSubmit;
  final VoidCallback onDismiss;

  @override
  State<_QuestionFormCard> createState() => _QuestionFormCardState();
}

class _QuestionFormCardState extends State<_QuestionFormCard> {
  /// The visible question when the form has more than one (a tab per
  /// question, Android/touch friendly); `0` when the form is a single
  /// question.
  int _tab = 0;

  /// Per question, the selected option labels: a single selection for a
  /// single-select question, an accumulating set for a multiple-select one.
  late List<Set<String>> _selections;

  /// Per question, the free-text controller (used only for `custom`
  /// questions); index-aligned with [widget.form.questions].
  late List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    final questions = widget.form.questions;
    _selections = [
      for (var i = 0; i < questions.length; i++) <String>{},
    ];
    _controllers = [
      for (var i = 0; i < questions.length; i++) TextEditingController(),
    ];
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _select(int i, String label) {
    if (widget.busy) return;
    setState(() {
      if (widget.form.questions[i].multiple) {
        final set = _selections[i];
        if (set.contains(label)) {
          set.remove(label);
        } else {
          set.add(label);
        }
      } else {
        _selections[i] = {label};
      }
    });
  }

  /// The form's answers, one entry per question in field order. A
  /// single-select question answers with its free text when present (custom),
  /// else its selected option, else nothing; a multiple-select question
  /// answers with its selected option labels (option order) plus its free
  /// text when present.
  List<List<String>> _answers() {
    final answers = <List<String>>[];
    final questions = widget.form.questions;
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      final free = q.custom ? _controllers[i].text.trim() : '';
      if (q.multiple) {
        final labels = <String>[
          for (final o in q.options)
            if (_selections[i].contains(o.label)) o.label,
        ];
        if (q.custom && free.isNotEmpty) labels.add(free);
        answers.add(labels);
      } else if (free.isNotEmpty) {
        answers.add([free]);
      } else if (_selections[i].isNotEmpty) {
        answers.add([_selections[i].first]);
      } else {
        answers.add(const <String>[]);
      }
    }
    return answers;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final questions = widget.form.questions;
    final title = widget.form.title.isNotEmpty
        ? widget.form.title
        : (questions.isNotEmpty ? questions.first.header : 'Question');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (questions.length > 1) ...[
            _TabStrip(
              labels: [
                for (var i = 0; i < questions.length; i++)
                  questions[i].header.isNotEmpty
                      ? questions[i].header
                      : 'Question ${i + 1}',
              ],
              selected: _tab,
              enabled: !widget.busy,
              onSelect: (i) => setState(() => _tab = i),
            ),
            const SizedBox(height: 8),
            _QuestionBody(
              question: questions[_tab],
              index: _tab,
              formId: widget.form.id,
              selections: _selections[_tab],
              controller: _controllers[_tab],
              enabled: !widget.busy,
              onSelect: (label) => _select(_tab, label),
            ),
          ] else if (questions.isNotEmpty)
            _QuestionBody(
              question: questions.first,
              index: 0,
              formId: widget.form.id,
              selections: _selections.first,
              controller: _controllers.first,
              enabled: !widget.busy,
              onSelect: (label) => _select(0, label),
            ),
          Row(
            children: [
              if (widget.form.title.isNotEmpty && questions.isNotEmpty)
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              const Spacer(),
              if (widget.busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else ...[
                TextButton(
                  key: ValueKey('question-dismiss-${widget.form.id}'),
                  onPressed: widget.onDismiss,
                  child: const Text('Dismiss'),
                ),
                FilledButton(
                  key: ValueKey('question-submit-${widget.form.id}'),
                  onPressed: () => widget.onSubmit(_answers()),
                  child: const Text('Submit'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.labels,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final List<String> labels;
  final int selected;
  final bool enabled;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (var i = 0; i < labels.length; i++)
          InkWell(
            key: ValueKey('question-tab-$i'),
            onTap: enabled ? () => onSelect(i) : null,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: i == selected
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontWeight: i == selected ? FontWeight.w600 : FontWeight.w400,
                  color: i == selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _QuestionBody extends StatelessWidget {
  const _QuestionBody({
    required this.question,
    required this.index,
    required this.formId,
    required this.selections,
    required this.controller,
    required this.enabled,
    required this.onSelect,
  });

  final Question question;
  final int index;
  final String formId;
  final Set<String> selections;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (question.question.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              question.question,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        for (var j = 0; j < question.options.length; j++)
          _OptionRow(
            key: ValueKey('question-option-$formId-$index-$j'),
            option: question.options[j],
            selected: selections.contains(question.options[j].label),
            enabled: enabled,
            onTap: () => onSelect(question.options[j].label),
          ),
        if (question.custom)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextField(
              key: ValueKey('question-text-$formId-$index'),
              controller: controller,
              enabled: enabled,
              maxLines: 1,
              textInputAction: question.multiple ? TextInputAction.newline : null,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Or type an answer…',
                border: const OutlineInputBorder(),
              ),
            ),
          ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final QuestionOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.label),
                  if (option.description != null &&
                      (option.description!.isNotEmpty))
                    Text(
                      option.description!,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
