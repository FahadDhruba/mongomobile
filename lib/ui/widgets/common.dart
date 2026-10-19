import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// An inline message strip for errors and warnings.
class MessageBanner extends StatelessWidget {
  const MessageBanner({
    super.key,
    required this.message,
    this.kind = BannerKind.error,
    this.action,
    this.onDismiss,
  });

  final String message;
  final BannerKind kind;
  final Widget? action;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = switch (kind) {
      BannerKind.error => c.danger,
      BannerKind.warning => c.warning,
      BannerKind.info => c.accent,
    };
    final icon = switch (kind) {
      BannerKind.error => Icons.error_outline,
      BannerKind.warning => Icons.warning_amber_rounded,
      BannerKind.info => Icons.info_outline,
    };
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(message,
                style: TextStyle(color: c.text, fontSize: 13.5, height: 1.35)),
          ),
          ?action,
          if (onDismiss != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: onDismiss,
              icon: Icon(Icons.close, color: c.muted),
            ),
        ],
      ),
    );
  }
}

enum BannerKind { error, warning, info }

/// A centred icon, title and hint for empty lists.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: c.muted),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: c.text)),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted, height: 1.4)),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// A spinner with a label.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: context.colors.accent),
          ),
          if (label != null) ...[
            const SizedBox(height: 12),
            Text(label!, style: TextStyle(color: context.colors.muted)),
          ],
        ],
      ),
    );
  }
}

/// The app mark, drawn from the bundled icon.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.asset('assets/icon/app_icon_192.png',
            width: size, height: size, filterQuality: FilterQuality.medium),
      );
}

/// A small rounded label, e.g. UNIQUE or TTL on an index.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.colors.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.6)),
        color: c.withValues(alpha: 0.1),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: c)),
    );
  }
}

/// Asks to confirm a destructive action. Returns true when confirmed.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final c = context.colors;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: c.danger)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
