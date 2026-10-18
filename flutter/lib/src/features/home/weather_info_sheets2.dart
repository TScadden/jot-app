import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/home/weather_info_sheets.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Wind / UV / pressure info sheets (native `showWindInfo`,
/// `showUvInfo`, `showPressureInfo` in `TodayScreen.kt` — static copy,
/// verbatim).

void showWindInfoSheet(BuildContext context) {
  showInfoSheetScaffold(
    context: context,
    title: 'Wind velocity',
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        infoDarkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              infoWhiteBold('Wind Thresholds & Exertion Impact', 16),
              const SizedBox(height: 16),
              infoEmojiRangeRow(
                emoji: '🍃',
                label: 'Calm & Pleasant Range',
                value: '< 12 mph\n(< 19 km/h)',
              ),
              infoThinDivider(),
              infoEmojiRangeRow(
                emoji: '💨',
                label: 'Resistant & Aerobic Strain',
                value: '12 - 20 mph\n(19 - 32 km/h)',
              ),
              infoThinDivider(),
              infoEmojiRangeRow(
                emoji: '🌪️',
                label: 'High Wind Alert',
                value: '> 20 mph\n(> 32 km/h)',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        infoWhiteBold('Wind Chill & Drag Forces', 18),
        const SizedBox(height: 12),
        infoWhiteFaint(
          'Convective heat loss increases with wind speed. In cold '
          'temperatures, strong winds strip away the thin boundary layer '
          'of warm air surrounding your skin, causing your body '
          'temperature to drop rapidly.\n\n'
          'For cyclists and runners, headwind dramatically increases '
          'aerobic resistance. Sustained wind speeds above 15 mph can '
          'increase energy cost/heart rate by up to 20-30% to maintain '
          'the same pace, elevating training load.',
          14,
          20,
        ),
      ],
    ),
  );
}

void showUvInfoSheet(BuildContext context) {
  showInfoSheetScaffold(
    context: context,
    title: 'UV index',
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        infoDarkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              infoWhiteBold('UV Index Ranges', 16),
              const SizedBox(height: 16),
              _uvRangeRow(NotelColors.success, 'Low', '0-2'),
              infoThinDivider(),
              _uvRangeRow(NotelColors.warning, 'Moderate', '3-5'),
              infoThinDivider(),
              _uvRangeRow(NotelColors.warning, 'High', '6-7'),
              infoThinDivider(),
              _uvRangeRow(NotelColors.error, 'Very High', '8-10'),
            ],
          ),
        ),
        const SizedBox(height: 24),
        infoWhiteFaint(
          'The UV Index measures the intensity of ultraviolet radiation '
          'from the sun. Excessive UV exposure causes sunburn, premature '
          'skin aging, eye damage, and significantly increases the risk of '
          'skin cancer including melanoma.\n\n'
          'UV radiation is highest between 10am and 4pm, at higher '
          'altitudes, near the equator, and during summer months. '
          'Reflection from water, sand, and snow can increase exposure.',
          14,
          20,
        ),
        const SizedBox(height: 24),
        infoDarkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Text('🔄', style: TextStyle(fontSize: 18)),
                  SizedBox(width: 8),
                  Text(
                    'Reapplication',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              infoWhiteFaint(
                'Reapply every 2 hours, or immediately after swimming or '
                'sweating. Most people apply only 25-50% of the recommended '
                'amount.',
                12,
                18,
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        infoWhiteBold('Protection by Level', 18),
        const SizedBox(height: 12),
        _protectionLevelCard(
          title: 'Low (0-2) ✓ Safe Zone',
          description:
              'Minimal risk. This is the ideal range for outdoor activities. '
              'Wear sunglasses on bright days for eye protection.',
          color: NotelColors.success,
        ),
        const SizedBox(height: 12),
        _protectionLevelCard(
          title: 'Moderate (3-5)',
          description:
              'Apply mineral sunscreen (SPF 30+), wear UV-blocking '
              'sunglasses and a hat. Limit midday exposure (10am-4pm).',
          color: NotelColors.warning,
        ),
        const SizedBox(height: 12),
        _protectionLevelCard(
          title: 'High (6-7)',
          description:
              'Protection essential. Use SPF 30-50 mineral sunscreen, wear '
              'UPF clothing, wide-brim hat, and wrap-around sunglasses. '
              'Seek shade between 10am-4pm.',
          color: NotelColors.warning,
        ),
        const SizedBox(height: 12),
        _protectionLevelCard(
          title: 'Very High (8-10)',
          description:
              'Avoid sun between 10am-4pm. Use SPF 50+ mineral sunscreen, '
              'full coverage UPF clothing, hat, and sunglasses are '
              'mandatory. Reapply sunscreen every 2 hours.',
          color: NotelColors.error,
        ),
        const SizedBox(height: 12),
        _protectionLevelCard(
          title: 'Extreme (11+)',
          description:
              'Stay indoors during peak hours (10am-4pm). If outside, seek '
              'shade, wear full protective UPF clothing, SPF 50+ mineral '
              'sunscreen, and wrap-around sunglasses. Unprotected skin '
              'burns in minutes.',
          color: NotelColors.uvExtreme,
        ),
      ],
    ),
  );
}

void showPressureInfoSheet(BuildContext context) {
  showInfoSheetScaffold(
    context: context,
    title: 'Barometric pressure',
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        infoDarkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              infoWhiteBold('Barometric Reference Ranges', 16),
              const SizedBox(height: 16),
              infoEmojiRangeRow(
                emoji: '☀️',
                label: 'High/Stable Pressure',
                value: '> 1020 hPa',
              ),
              infoThinDivider(),
              infoEmojiRangeRow(
                emoji: '⛅',
                label: 'Standard Sea Level',
                value: '1013 hPa',
              ),
              infoThinDivider(),
              infoEmojiRangeRow(
                emoji: '⛈️',
                label: 'Low/Stormy Pressure',
                value: '< 1009 hPa',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        infoWhiteBold('How Atmospheric Pressure Impacts You', 18),
        const SizedBox(height: 12),
        infoWhiteFaint(
          'A sudden drop in barometric pressure (often preceding stormy '
          'weather) allows joint tissues, tendons, and fluids to expand '
          'slightly. This expansion can cause aches in arthritic joints or '
          'old injuries.\n\n'
          'Furthermore, barometric drops affect blood flow and oxygen '
          'tension in tissues. The pressure difference between the '
          'atmosphere and your sinuses can cause sinus pressure, vascular '
          'headaches, and migraines.',
          14,
          20,
        ),
        const SizedBox(height: 24),
        infoDarkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Text('⚠️', style: TextStyle(fontSize: 18)),
                  SizedBox(width: 8),
                  Text(
                    'Vulnerability Warning',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              infoWhiteFaint(
                'If you notice a rapid drop in barometric pressure, stay '
                'hydrated, keep joint temperatures warm, and anticipate '
                'potential headaches by scheduling recovery-focused, '
                'low-strain activities.',
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

Widget _uvRangeRow(Color dotColor, String label, String value) {
  return Row(
    children: [
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

/// Native `ProtectionLevelCard`.
Widget _protectionLevelCard({
  required String title,
  required String description,
  required Color color,
}) {
  return Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: NotelColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
    ),
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ],
    ),
  );
}
