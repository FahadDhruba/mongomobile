import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/aggregation_controller.dart';
import 'aggregations_view.dart';

/// Edits a view's pipeline in the aggregation builder, running previews
/// against the view's source collection. Pops with true once updated.
class EditViewScreen extends ConsumerStatefulWidget {
  const EditViewScreen({
    super.key,
    required this.view,
    required this.source,
    required this.pipeline,
  });

  final Namespace view;
  final Namespace source;
  final List<Map<String, dynamic>> pipeline;

  @override
  ConsumerState<EditViewScreen> createState() => _EditViewScreenState();
}

class _EditViewScreenState extends ConsumerState<EditViewScreen> {
  late final _key = AggregationKey(widget.source, view: widget.view);

  @override
  void initState() {
    super.initState();
    // Providers can't change while widgets build; load right after.
    Future.microtask(() {
      if (mounted) {
        ref.read(aggregationProvider(_key).notifier).load(widget.pipeline);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keep the draft alive while the screen is open.
    ref.listen(aggregationProvider(_key), (_, _) {});
    return Scaffold(
      appBar: AppBar(title: Text('Edit view ${widget.view.collection}')),
      body: AggregationsView(aggregationKey: _key),
    );
  }
}
