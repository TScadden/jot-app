import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/tools/trends_screen.dart';

/// Fresh-account audit (Oct 28, 2026): entries referencing category
/// ids with no row in the sync pull rendered as raw "Category 8 / 9 /
/// 11" in Visual Trends. Built-in default ids (1–8) now resolve to
/// their canonical names as a display fallback; pulled rows (incl.
/// user renames) always win; non-default ids keep the raw fallback.
void main() {
  group('resolveTrendsCategoryName', () {
    test('pulled name wins over the default table (user rename)', () {
      expect(resolveTrendsCategoryName(8, {8: 'My Meds'}), 'My Meds');
      expect(resolveTrendsCategoryName(1, {1: 'How I Feel'}), 'How I Feel');
    });

    test('built-in defaults resolve when the pull has no row', () {
      expect(resolveTrendsCategoryName(1, const {}), 'Symptoms');
      expect(resolveTrendsCategoryName(2, const {}), 'Food & Eating');
      expect(resolveTrendsCategoryName(3, const {}), 'Weight & Vitals');
      expect(resolveTrendsCategoryName(4, const {}), 'Goals & Habits');
      expect(resolveTrendsCategoryName(5, const {}), 'Sleep');
      expect(resolveTrendsCategoryName(6, const {}), 'Mood & Energy');
      expect(resolveTrendsCategoryName(7, const {}), 'General');
      expect(resolveTrendsCategoryName(8, const {}), 'Medication');
    });

    test('non-default ids keep the raw Category N fallback', () {
      expect(resolveTrendsCategoryName(9, const {}), 'Category 9');
      expect(resolveTrendsCategoryName(11, const {}), 'Category 11');
      expect(resolveTrendsCategoryName(17, const {}), 'Category 17');
    });

    test('a pulled row for a custom id is used verbatim', () {
      expect(
        resolveTrendsCategoryName(13, {13: 'Run Distance'}),
        'Run Distance',
      );
    });
  });
}
