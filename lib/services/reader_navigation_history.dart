import '../models/reading_position.dart';

class ReaderNavigationHistory {
  final int capacity;
  final List<ReadingPosition> _positions = [];
  ReaderNavigationHistory({this.capacity = 32}) : assert(capacity > 0);

  bool get canGoBack => _positions.isNotEmpty;
  int get length => _positions.length;
  ReadingPosition? get previous => _positions.isEmpty ? null : _positions.last;

  static bool sameAnchor(ReadingPosition a, ReadingPosition b) =>
      a.chapterId == b.chapterId &&
      a.paragraphIndex == b.paragraphIndex &&
      a.characterOffset == b.characterOffset;

  void record(ReadingPosition origin, ReadingPosition target) {
    if (sameAnchor(origin, target)) return;
    if (_positions.isNotEmpty && sameAnchor(_positions.last, origin)) return;
    _positions.add(origin);
    if (_positions.length > capacity) _positions.removeAt(0);
  }

  void returnedTo(ReadingPosition position) {
    if (_positions.isNotEmpty && sameAnchor(_positions.last, position)) {
      _positions.removeLast();
    }
  }

  void clear() => _positions.clear();
}
