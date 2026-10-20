import 'package:mongo_wire/mongo_wire.dart';

/// A stage operator with the text a new stage starts with.
class StageTemplate {
  const StageTemplate(this.operator, this.template, this.summary);

  final String operator;
  final String template;
  final String summary;
}

/// Stage operators offered when adding a stage, most used first.
const stageTemplates = [
  StageTemplate(r'$match', "{\n  field: 'value'\n}", 'Filter documents'),
  StageTemplate(r'$project', '{\n  field: 1\n}', 'Choose or compute fields'),
  StageTemplate(
    r'$group',
    "{\n  _id: '\$field',\n  count: { \$sum: 1 }\n}",
    'Group and accumulate',
  ),
  StageTemplate(r'$sort', '{\n  field: -1\n}', 'Order documents'),
  StageTemplate(r'$limit', '20', 'Keep the first n documents'),
  StageTemplate(r'$skip', '0', 'Skip the first n documents'),
  StageTemplate(r'$unwind', "'\$field'", 'One document per array element'),
  StageTemplate(
    r'$lookup',
    "{\n  from: 'collection',\n  localField: 'field',\n  foreignField: '_id',\n  as: 'joined'\n}",
    'Join another collection',
  ),
  StageTemplate(r'$addFields', "{\n  newField: '\$field'\n}", 'Add fields'),
  StageTemplate(r'$set', "{\n  newField: '\$field'\n}", 'Add or change fields'),
  StageTemplate(r'$unset', "'field'", 'Remove fields'),
  StageTemplate(r'$count', "'count'", 'Count the documents'),
  StageTemplate(r'$sortByCount', "'\$field'", 'Group, count and sort'),
  StageTemplate(
    r'$facet',
    '{\n  output: [{ \$limit: 5 }]\n}',
    'Several pipelines on the same input',
  ),
  StageTemplate(
    r'$bucket',
    "{\n  groupBy: '\$field',\n  boundaries: [0, 100],\n  default: 'other',\n  output: { count: { \$sum: 1 } }\n}",
    'Group into ranges',
  ),
  StageTemplate(
    r'$bucketAuto',
    "{\n  groupBy: '\$field',\n  buckets: 5\n}",
    'Group into evenly filled ranges',
  ),
  StageTemplate(r'$sample', '{\n  size: 10\n}', 'Random documents'),
  StageTemplate(
    r'$replaceRoot',
    "{\n  newRoot: '\$field'\n}",
    'Promote an embedded document',
  ),
  StageTemplate(r'$replaceWith', "'\$field'", 'Promote an embedded document'),
  StageTemplate(
    r'$unionWith',
    "{\n  coll: 'collection'\n}",
    'Append another collection',
  ),
  StageTemplate(
    r'$graphLookup',
    "{\n  from: 'collection',\n  startWith: '\$field',\n  connectFromField: 'field',\n  connectToField: '_id',\n  as: 'graph'\n}",
    'Recursive lookup',
  ),
  StageTemplate(
    r'$setWindowFields',
    "{\n  partitionBy: '\$field',\n  sortBy: { _id: 1 },\n  output: { total: { \$sum: '\$value', window: { documents: ['unbounded', 'current'] } } }\n}",
    'Running totals and windows',
  ),
  StageTemplate(
    r'$densify',
    "{\n  field: 'field',\n  range: { step: 1, bounds: 'full' }\n}",
    'Fill gaps in a sequence',
  ),
  StageTemplate(
    r'$fill',
    "{\n  output: { field: { value: 0 } }\n}",
    'Fill missing values',
  ),
  StageTemplate(r'$redact', "'\$\$KEEP'", 'Restrict content per document'),
  StageTemplate(
    r'$geoNear',
    "{\n  near: { type: 'Point', coordinates: [0, 0] },\n  distanceField: 'distance'\n}",
    'Sort by distance',
  ),
  StageTemplate(r'$out', "'collection'", 'Write results to a collection'),
  StageTemplate(
    r'$merge',
    "{\n  into: 'collection'\n}",
    'Merge results into a collection',
  ),
];

/// Stages that write instead of returning documents.
const writeStages = {r'$out', r'$merge'};

StageTemplate? templateFor(String operator) {
  for (final t in stageTemplates) {
    if (t.operator == operator) return t;
  }
  return null;
}

/// A stage as edited in the builder.
class StageDraft {
  const StageDraft({
    required this.id,
    required this.operator,
    required this.body,
    this.enabled = true,
  });

  final int id;
  final String operator;

  /// The stage's value as typed, e.g. `{ status: 'paid' }` for `$match`.
  final String body;
  final bool enabled;

  StageDraft copyWith({String? operator, String? body, bool? enabled}) =>
      StageDraft(
        id: id,
        operator: operator ?? this.operator,
        body: body ?? this.body,
        enabled: enabled ?? this.enabled,
      );

  bool get writes => writeStages.contains(operator);

  /// The stage document, or throws [FormatException] with the reason.
  Map<String, dynamic> parse() {
    if (!operator.startsWith(r'$')) {
      throw const FormatException('Pick a stage operator');
    }
    if (body.trim().isEmpty) {
      throw FormatException('$operator needs a value');
    }
    try {
      return {operator: EJsonParser(body).parseValue()};
    } on EJsonParseException catch (e) {
      throw FormatException(
        '${e.message} (line ${e.line}, column ${e.column})',
      );
    }
  }
}

/// Builds the pipeline from the enabled stages up to and including
/// [upTo] (all when null). Throws [FormatException] naming the stage.
List<Map<String, dynamic>> buildPipeline(List<StageDraft> stages, {int? upTo}) {
  final out = <Map<String, dynamic>>[];
  final last = upTo ?? stages.length - 1;
  for (var i = 0; i <= last && i < stages.length; i++) {
    final s = stages[i];
    if (!s.enabled) continue;
    try {
      out.add(s.parse());
    } on FormatException catch (e) {
      throw FormatException('Stage ${i + 1} (${s.operator}): ${e.message}');
    }
  }
  return out;
}

/// The pipeline as editable text, one stage per element.
String pipelineToText(List<Map<String, dynamic>> pipeline) =>
    EJson.stringify(pipeline);

/// Reads an array of stages from text, e.g. pasted from mongosh.
/// [nextId] numbers the new drafts.
List<StageDraft> textToStages(String text, int Function() nextId) {
  final value = EJsonParser(text).parseValue();
  if (value is! List) {
    throw const FormatException('A pipeline is an array: [ { \$match: … } ]');
  }
  final out = <StageDraft>[];
  for (var i = 0; i < value.length; i++) {
    final stage = value[i];
    if (stage is! Map<String, dynamic> || stage.length != 1) {
      throw FormatException(
        'Stage ${i + 1} must be a document with one operator, like { \$match: {} }',
      );
    }
    final op = stage.keys.single;
    final v = stage[op];
    out.add(
      StageDraft(
        id: nextId(),
        operator: op,
        body: v is Map || v is List
            ? EJson.stringify(v)
            : EJson.stringify(v, pretty: false),
      ),
    );
  }
  return out;
}
