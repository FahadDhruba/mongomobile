import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../services/pipeline.dart';

/// The pipeline being built for one collection.
class AggregationState {
  const AggregationState({
    this.stages = const [],
    this.textMode = false,
    this.text = '[]',
    this.name,
    this.collationText = '',
  });

  final List<StageDraft> stages;

  /// Editing the whole pipeline as one array instead of stage cards.
  final bool textMode;
  final String text;

  /// The saved pipeline this came from, if any.
  final String? name;

  /// Optional collation for the whole aggregation.
  final String collationText;

  AggregationState copyWith({
    List<StageDraft>? stages,
    bool? textMode,
    String? text,
    String? name,
    bool clearName = false,
    String? collationText,
  }) => AggregationState(
    stages: stages ?? this.stages,
    textMode: textMode ?? this.textMode,
    text: text ?? this.text,
    name: clearName ? null : (name ?? this.name),
    collationText: collationText ?? this.collationText,
  );

  /// The full pipeline, from whichever editor is active.
  List<Map<String, dynamic>> pipeline() {
    if (!textMode) return buildPipeline(stages);
    var id = 0;
    return buildPipeline(textToStages(text, () => ++id));
  }

  Map<String, dynamic>? collation() {
    if (collationText.trim().isEmpty) return null;
    try {
      final c = EJson.parseDocument(collationText);
      if (c['locale'] is! String) {
        throw const FormatException('needs a locale');
      }
      return c;
    } on FormatException catch (e) {
      throw FormatException('Collation: ${e.message}');
    }
  }

  bool get writes =>
      textMode ? text.contains(RegExp(r'\$(out|merge)\b')) : stages.any((s) => s.enabled && s.writes);
}

/// Which pipeline: the builder of a collection, or the one used to edit a
/// view's definition (which runs on the view's source collection).
class AggregationKey {
  const AggregationKey(this.source, {this.view});

  /// The collection the pipeline runs on.
  final Namespace source;

  /// The view being edited, if any.
  final Namespace? view;

  @override
  bool operator ==(Object other) =>
      other is AggregationKey && other.source == source && other.view == view;

  @override
  int get hashCode => Object.hash(source, view);
}

class AggregationController extends Notifier<AggregationState> {
  AggregationController(this.key);

  final AggregationKey key;
  int _nextId = 1;
  int _id() => _nextId++;

  @override
  AggregationState build() => AggregationState(
    stages: [
      StageDraft(
        id: _id(),
        operator: r'$match',
        body: templateFor(r'$match')!.template,
      ),
    ],
  );

  void addStage(String operator, {int? after}) {
    final t = templateFor(operator);
    final draft = StageDraft(
      id: _id(),
      operator: operator,
      body: t?.template ?? '{}',
    );
    final list = [...state.stages];
    list.insert(after == null ? list.length : after + 1, draft);
    state = state.copyWith(stages: list);
  }

  void _replace(int id, StageDraft Function(StageDraft s) change) {
    state = state.copyWith(
      stages: [for (final s in state.stages) s.id == id ? change(s) : s],
    );
  }

  void setBody(int id, String body) => _replace(id, (s) => s.copyWith(body: body));

  /// Changing the operator swaps an untouched template for the new one.
  void setOperator(int id, String operator) => _replace(id, (s) {
    final oldTemplate = templateFor(s.operator)?.template;
    final keepBody = s.body.trim().isNotEmpty && s.body != oldTemplate;
    return s.copyWith(
      operator: operator,
      body: keepBody ? s.body : (templateFor(operator)?.template ?? s.body),
    );
  });

  void toggle(int id) => _replace(id, (s) => s.copyWith(enabled: !s.enabled));

  void remove(int id) => state = state.copyWith(
    stages: state.stages.where((s) => s.id != id).toList(),
  );

  void move(int id, int delta) {
    final list = [...state.stages];
    final i = list.indexWhere((s) => s.id == id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= list.length) return;
    final s = list.removeAt(i);
    list.insert(j, s);
    state = state.copyWith(stages: list);
  }

  void setText(String text) => state = state.copyWith(text: text);

  void setCollation(String text) => state = state.copyWith(collationText: text);

  /// Switches between stage cards and the text editor, converting the
  /// pipeline. Throws [FormatException] when the text can't become stages.
  void setTextMode(bool on) {
    if (on == state.textMode) return;
    if (on) {
      final pipeline = [
        for (final s in state.stages)
          if (s.enabled) _tryParse(s),
      ];
      state = state.copyWith(
        textMode: true,
        text: pipelineToText(pipeline.whereType<Map<String, dynamic>>().toList()),
      );
    } else {
      final stages = textToStages(state.text, _id);
      state = state.copyWith(textMode: false, stages: stages);
    }
  }

  Map<String, dynamic>? _tryParse(StageDraft s) {
    try {
      return s.parse();
    } on FormatException {
      return null;
    }
  }

  /// Replaces the pipeline, e.g. from a saved one or a view's definition.
  void load(List<Map<String, dynamic>> pipeline, {String? name}) {
    final stages = textToStages(pipelineToText(pipeline), _id);
    state = AggregationState(
      stages: stages,
      name: name,
      collationText: state.collationText,
    );
  }

  /// Loads pipeline text as saved; falls back to text mode if it doesn't
  /// split into stages.
  void loadText(String text, {String? name}) {
    try {
      state = AggregationState(stages: textToStages(text, _id), name: name);
    } on FormatException {
      state = AggregationState(textMode: true, text: text, name: name);
    }
  }

  void setName(String? name) =>
      state = state.copyWith(name: name, clearName: name == null);

  void clear() => state = AggregationState(
    stages: [
      StageDraft(
        id: _id(),
        operator: r'$match',
        body: templateFor(r'$match')!.template,
      ),
    ],
  );
}

final aggregationProvider = NotifierProvider.autoDispose
    .family<AggregationController, AggregationState, AggregationKey>(
      AggregationController.new,
    );
