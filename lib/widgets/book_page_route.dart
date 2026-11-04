import 'package:flutter/material.dart';

/// Book entry is an opaque slide, not a zoom/fade of two changing snapshots.
/// In-book page-turn animations remain entirely independent.
class BookPageRoute<T> extends MaterialPageRoute<T> {
  BookPageRoute({required super.builder, super.settings})
    : super(allowSnapshotting: false);

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);
  @override
  DelegatedTransitionBuilder? get delegatedTransition => null;
  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;
  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) => false;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
      child: child,
    );
  }
}
