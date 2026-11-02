// The structured-view question contract shared by the bridge (which composes
// it from the opencode service's pending question forms, hiding the service's
// internal `q0`/`q1` field keys) and the app (which renders the TUI-style
// question panel). One `QuestionForm` is what
// `GET /api/sessions/{id}/questions` returns per pending question form
// (issue #50), and the answers to
// `POST /api/sessions/{id}/questions/{formID}/answer` are one entry per
// question, in the form's question order.

/// One pickable option of a question: its displayed label (also the answer
/// value sent back — the service's option `value` equals its `label`) and an
/// optional description.
class QuestionOption {
  const QuestionOption({required this.label, this.description});

  /// The option's label (what the user picks; also the answer value).
  final String label;

  /// The option's description, or `null` when the option carries none.
  final String? description;

  Map<String, Object?> toJson() => {
    'label': label,
    if (description != null) 'description': description,
  };

  factory QuestionOption.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return QuestionOption(
      label: map['label'] as String? ?? '',
      description: map['description'] is String
          ? map['description'] as String
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is QuestionOption &&
      other.label == label &&
      other.description == description;

  @override
  int get hashCode => Object.hash(label, description);

  @override
  String toString() =>
      'QuestionOption(label: $label, description: $description)';
}

/// One question of a question form (the service's form field, with the
/// internal `q0`/`q1` key hidden): its short header, question text, single-
/// or multiple-select, the pickable options, and whether a free-text answer
/// is allowed.
class Question {
  const Question({
    required this.header,
    required this.question,
    required this.multiple,
    required this.options,
    required this.custom,
  });

  /// The question's short header (the service's field `title`).
  final String header;

  /// The question text (the service's field `description`).
  final String question;

  /// Whether the question allows multiple options (the service's field
  /// `type == "multiselect"`); otherwise a single option (or free text).
  final bool multiple;

  /// The pickable options (the service's field `options`); empty when the
  /// question is free text only.
  final List<QuestionOption> options;

  /// Whether a free-text answer is allowed (the service's field `custom`).
  final bool custom;

  Map<String, Object?> toJson() => {
    'header': header,
    'question': question,
    'multiple': multiple,
    'options': [for (final o in options) o.toJson()],
    'custom': custom,
  };

  factory Question.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final options = map['options'];
    return Question(
      header: map['header'] as String? ?? '',
      question: map['question'] as String? ?? '',
      multiple: map['multiple'] == true,
      custom: map['custom'] == true,
      options: options is List
          ? [for (final o in options) QuestionOption.fromJson(o)]
          : const [],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Question &&
      other.header == header &&
      other.question == question &&
      other.multiple == multiple &&
      other.custom == custom &&
      _optionsEqual(other.options, options);

  @override
  int get hashCode =>
      Object.hash(header, question, multiple, custom, Object.hashAll(options));

  @override
  String toString() =>
      'Question(header: $header, question: $question, multiple: $multiple, custom: $custom)';
}

/// One pending question form (the opencode form with
/// `metadata.kind == "question"`), surfaced with its [Question]s in the
/// form's field order — the order the answers are submitted in.
class QuestionForm {
  const QuestionForm({
    required this.id,
    required this.title,
    required this.questions,
  });

  /// The form id (the service's form `id`).
  final String id;

  /// The form title (the service's form `title`, e.g. `Questions`).
  final String title;

  /// The form's questions, in the form's field order.
  final List<Question> questions;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'questions': [for (final q in questions) q.toJson()],
  };

  factory QuestionForm.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final questions = map['questions'];
    return QuestionForm(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      questions: questions is List
          ? [for (final q in questions) Question.fromJson(q)]
          : const [],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is QuestionForm &&
      other.id == id &&
      other.title == title &&
      _questionsEqual(other.questions, questions);

  @override
  int get hashCode => Object.hash(id, title, Object.hashAll(questions));

  @override
  String toString() =>
      'QuestionForm(id: $id, title: $title, questions: $questions)';
}

bool _optionsEqual(List<QuestionOption> a, List<QuestionOption> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _questionsEqual(List<Question> a, List<Question> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
