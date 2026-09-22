import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Reusable small status pill used across My Recordings / Recording
/// Details / Home to show a state (Completed, Uploading, Pending, Failed,
/// Emergency, ...) as a colored chip with an icon -- never color alone, so
/// the meaning is still clear without relying on color perception.
class StatusChip extends StatelessWidget {
  final String label;
  final Color foreground;
  final Color background;
  final IconData icon;

  const StatusChip({
    super.key,
    required this.label,
    required this.foreground,
    required this.background,
    required this.icon,
  });

  const StatusChip.success({super.key, required this.label, this.icon = Icons.check_circle})
      : foreground = AppColors.success,
        background = AppColors.successBg;

  const StatusChip.warning({super.key, required this.label, this.icon = Icons.schedule})
      : foreground = AppColors.warning,
        background = AppColors.warningBg;

  const StatusChip.danger({super.key, required this.label, this.icon = Icons.error})
      : foreground = AppColors.danger,
        background = AppColors.dangerBg;

  const StatusChip.info({super.key, required this.label, this.icon = Icons.cloud_upload_outlined})
      : foreground = AppColors.info,
        background = AppColors.infoBg;

  const StatusChip.emergency({super.key, required this.label, this.icon = Icons.emergency})
      : foreground = AppColors.emergency,
        background = AppColors.emergencyBg;

  const StatusChip.neutral({super.key, required this.label, this.icon = Icons.circle_outlined})
      : foreground = AppColors.textSecondary,
        background = AppColors.neutralBg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(color: foreground, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// Small colored status dot + label, used for compact inline indicators
/// (device online/offline, GPS, command channel) where a full chip would
/// be too heavy.
class StatusDot extends StatelessWidget {
  final Color color;
  const StatusDot({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Subtle pulsing dot used next to an active-recording indicator. Purely a
/// visual affordance (a live "recording" heartbeat) -- carries no state and
/// reads nothing from any service.
class RecordingPulseDot extends StatefulWidget {
  final Color color;
  const RecordingPulseDot({super.key, required this.color});

  @override
  State<RecordingPulseDot> createState() => _RecordingPulseDotState();
}

class _RecordingPulseDotState extends State<RecordingPulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// A left-aligned, uppercase-style section label used to introduce a group
/// of cards/rows (e.g. "DEVICE STATUS", "RECORDING", "LOCATION").
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionHeader({super.key, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Text(title.toUpperCase(), style: AppTypography.sectionTitle),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}
