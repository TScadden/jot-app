import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 11 — info bottom sheets behind the weather detail rows.
///
/// Faithful ports of the native `showTempInfo` / `showHumidityInfo` /
/// `showWindInfo` / `showUvInfo` / `showPressureInfo` `ModalBottomSheet`s
/// in `TodayScreen.kt`. All copy is static, taken verbatim from the
/// native source.

void showTempInfoSheet(BuildContext context) {
  showInfoSheet(
    context: context,
    title: 'Temperature',
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        darkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              whiteBold('Ambient Temp & Sleep Recovery', 16),
              const SizedBox(height: 12),
              whiteFaint(
                'Ambient temperature strongly influences overnight recovery. '
                'Sleep studies show that cooler rooms support deeper, '
                'higher-quality sleep.',
                14,
                20,
              ),
              const SizedBox(height: 16),
              emojiRangeRow(
                emoji: '❄️',
                label: 'Optimal Sleep Range',
                value: '60°F - 67°F\n(15°C - 19°C)',
              ),
              thinDivider(),
              emojiRangeRow(
                emoji: '🏠',
                label: 'Comfortable Room Range',
                value: '68°F - 72°F\n(20°C - 22°C)',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        whiteBold('Why Temperature Matters', 18),
        const SizedBox(height: 12),
        whiteFaint(
          'Extreme temperatures place additional strain on the '
          'cardiovascular system. In hot weather, the heart beats faster to '
          'pump blood to the skin for cooling. In freezing weather, blood '
          'vessels constrict to conserve core heat, raising blood pressure.\n\n'
          'Working out in temperatures above 80°F (27°C) or below 32°F (0°C) '
          'elevates overall physiological strain, requiring slower pacing '
          'and adequate recovery times.',
          14,
          20,
        ),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1C1E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: NotelColors.success.withValues(alpha: 0.2),
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Text('🏃', style: TextStyle(fontSize: 18)),
                  SizedBox(width: 8),
                  Text(
                    'Workout Performance Guidance',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              whiteFaint(
                'Avoid strenuous outdoor exertion during midday heat waves. '
                'Ensure you hydrate with both water and electrolytes to '
                'compensate for sweat loss and preserve heart rate '
                'variability (HRV).',
                12,
                18,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

void showHumidityInfoSheet(BuildContext context) {
  showInfoSheet(
    context: context,
    title: 'Humidity',
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        darkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              whiteBold('Comfort and Health Ranges', 16),
              const SizedBox(height: 16),
              dotRangeRow(
                dotColor: NotelColors.success,
                label: 'Optimal Humidity Zone',
                value: '30% - 50%',
              ),
              thinDivider(),
              dotRangeRow(
                dotColor: NotelColors.error,
                label: 'High Humidity (Sticky/Hot)',
                value: '> 60%',
                dotEmoji: '🔴',
              ),
              thinDivider(),
              dotRangeRow(
                dotColor: NotelColors.info,
                label: 'Low Humidity (Dry/Irritating)',
                value: '< 30%',
                dotEmoji: '🔵',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        whiteBold('How Humidity Affects Your Body', 18),
        const SizedBox(height: 12),
        whiteFaint(
          'High humidity prevents sweat from evaporating efficiently. '
          'Because sweat cannot evaporate, your body cannot cool itself '
          'down, causing core temperature and heart rate to rise quickly.\n\n'
          'Low humidity (below 30%) dries out the mucous membranes in your '
          'nose and throat, compromising your immune system\'s first line '
          'of defense and making you more susceptible to viruses.',
          14,
          20,
        ),
        const SizedBox(height: 24),
        darkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Text('💡', style: TextStyle(fontSize: 18)),
                  SizedBox(width: 8),
                  Text(
                    'Hydration & Air Quality Tips',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              whiteFaint(
                'In dry weather, consider using a humidifier in your '
                'bedroom. In high humidity, drink extra water, wear loose '
                'moisture-wicking clothing, and limit high-intensity '
                'workouts to ventilated indoor spaces.',
                12,
                18,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Shared bottom-sheet scaffold for the info dialogs (native pattern:
/// pinned dark container, drag handle, 24dp horizontal / 64dp bottom
/// padding, 20sp Black title with 2sp letter spacing).
void showInfoSheet({
  required BuildContext context,
  required String title,
  required Widget content,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF080E1A),
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 64.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 24),
                content,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget darkCard({required Widget child}) {
  return Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: NotelColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
    ),
    padding: const EdgeInsets.all(16),
    child: child,
  );
}

Widget thinDivider() {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 12.0),
    child: Divider(
      color: NotelColors.legacyDarkHairlineFaint,
      thickness: 0.5,
      height: 0.5,
    ),
  );
}

Text whiteBold(String text, double size) {
  return Text(
    text,
    style: TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.bold,
      fontSize: size,
    ),
  );
}

Text whiteFaint(String text, double size, double lineHeight) {
  return Text(
    text,
    style: TextStyle(
      color: Colors.white.withValues(alpha: 0.7),
      fontSize: size,
      height: lineHeight / size,
    ),
  );
}

Widget emojiRangeRow({
  required String emoji,
  required String label,
  required String value,
}) {
  return Row(
    children: [
      Text(emoji, style: const TextStyle(fontSize: 18)),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 14,
          ),
        ),
      ),
      Text(
        value,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 12,
        ),
        textAlign: TextAlign.end,
      ),
    ],
  );
}

Widget dotRangeRow({
  required Color dotColor,
  required String label,
  required String value,
  String? dotEmoji,
}) {
  return Row(
    children: [
      if (dotEmoji != null)
        Text(dotEmoji, style: const TextStyle(fontSize: 12))
      else
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 14,
          ),
        ),
      ),
      Text(
        value,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 14,
        ),
      ),
    ],
  );
}

/// Public aliases used by `weather_info_sheets2.dart`.
void showInfoSheetScaffold({
  required BuildContext context,
  required String title,
  required Widget content,
}) =>
    showInfoSheet(context: context, title: title, content: content);

Widget infoDarkCard({required Widget child}) => darkCard(child: child);
Widget infoThinDivider() => thinDivider();
Text infoWhiteBold(String text, double size) => whiteBold(text, size);
Text infoWhiteFaint(String text, double size, double lineHeight) =>
    whiteFaint(text, size, lineHeight);
Widget infoEmojiRangeRow({
  required String emoji,
  required String label,
  required String value,
}) =>
    emojiRangeRow(emoji: emoji, label: label, value: value);
