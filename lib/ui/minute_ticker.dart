import 'dart:async';

import 'package:flutter/widgets.dart';

/// Rebuilds [builder] at the start of every minute by [clock], so a rate
/// summary on an open sheet turns to the next period on time (Codex P2).
class MinuteTicker extends StatefulWidget {
  const MinuteTicker({super.key, required this.clock, required this.builder});
  final DateTime Function() clock;
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<MinuteTicker> createState() => _MinuteTickerState();
}

class _MinuteTickerState extends State<MinuteTicker> {
  Timer? timer;

  void schedule() {
    timer?.cancel();
    final now = widget.clock();
    final wait =
        const Duration(minutes: 1) -
        Duration(seconds: now.second, milliseconds: now.millisecond);
    timer = Timer(wait, () {
      if (!mounted) return;
      setState(() {});
      schedule();
    });
  }

  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.clock());
}
