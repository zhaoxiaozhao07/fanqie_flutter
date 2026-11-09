import '../models/reading_position.dart';

class ReaderNavigationHistory {
  final int capacity;
  final List<ReadingPosition> _positions = [];
  final List<ReadingPosition> _forward = [];
  ReaderNavigationHistory({this.capacity = 32}) : assert(capacity > 0);

  bool get canGoBack => _positions.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;
  int get length => _positions.length;
  ReadingPosition? get previous => _positions.isEmpty ? null : _positions.last;
  ReadingPosition? get next => _forward.isEmpty ? null : _forward.last;

  static bool sameAnchor(ReadingPosition a, ReadingPosition b) =>
      a.chapterId == b.chapterId &&
      a.paragraphIndex == b.paragraphIndex &&
      a.characterOffset == b.characterOffset &&
      a.imageId == b.imageId;

  void _push(List<ReadingPosition> stack, ReadingPosition position) {
    if (stack.isNotEmpty && sameAnchor(stack.last, position)) {
      // Update the viewport fraction even when the canonical anchor is equal.
      stack[stack.length - 1] = position;
    } else {
      stack.add(position);
      if (stack.length > capacity) stack.removeAt(0);
    }
  }

  void record(ReadingPosition origin, ReadingPosition target) {
    if (sameAnchor(origin, target)) return;
    _forward.clear();
    _push(_positions, origin);
  }

  void returnedTo(ReadingPosition position, {ReadingPosition? origin}) {
    if (_positions.isNotEmpty && sameAnchor(_positions.last, position)) {
      _positions.removeLast();
      if (origin != null) _push(_forward, origin);
    }
  }

  void advancedTo(ReadingPosition position, {required ReadingPosition origin}) {
    if (_forward.isNotEmpty && sameAnchor(_forward.last, position)) {
      _forward.removeLast();
      _push(_positions, origin);
    }
  }

  void clear() {
    _positions.clear();
    _forward.clear();
  }
}
