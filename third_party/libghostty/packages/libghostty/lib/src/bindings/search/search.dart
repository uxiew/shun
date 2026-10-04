import '../../generated/libghostty_enums.g.dart';
import '../types.dart';

abstract interface class SearchBindings {
  void searchFeed(LibGhosttyHandle search);
  void searchFree(LibGhosttyHandle search);
  // `ghostty_search_get_multi` is intentionally not surfaced here. Its
  // heterogeneous output pointers are less type-safe than the typed reads
  // below, and it only provides an optimization over those reads.
  List<RawSelection> searchGetMatches(
    LibGhosttyHandle search, {
    required bool viewport,
  });
  String? searchGetNeedle(LibGhosttyHandle search);
  int? searchGetSelectedIndex(LibGhosttyHandle search);
  RawSelection? searchGetSelectedMatch(LibGhosttyHandle search);
  SearchScroll searchGetSelectScroll(LibGhosttyHandle search);
  SearchStatus searchGetStatus(LibGhosttyHandle search);
  int searchGetTotalMatches(LibGhosttyHandle search);
  LibGhosttyHandle searchNew(LibGhosttyHandle terminal);
  void searchRun(LibGhosttyHandle search);
  void searchSelectNext(LibGhosttyHandle search);
  void searchSelectPrevious(LibGhosttyHandle search);
  void searchSetNeedle(LibGhosttyHandle search, String? needle);
  void searchSetSelectScroll(LibGhosttyHandle search, SearchScroll? value);
  SearchStatus searchTick(LibGhosttyHandle search);
}
