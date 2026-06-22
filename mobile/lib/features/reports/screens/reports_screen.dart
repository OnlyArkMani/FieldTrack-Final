import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../auth/models/user.dart';
import '../../auth/providers/auth_provider.dart';
import '../../teams/providers/team_provider.dart';
import '../models/report_models.dart';
import '../providers/report_provider.dart';

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(reportProvider);
    final notifier = ref.read(reportProvider.notifier);
    final isSupervisor =
        ref.watch(authProvider).user?.role == UserRole.supervisor;
    final busy = state.phase == ReportPhase.generating;
    // Enforce the 31-day cap (range reports only; team reports use a month).
    final rangeTooLong = !state.isTeamReport &&
        state.range != null &&
        state.range!.duration.inDays > 31;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: ListView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          children: [
            _SectionLabel(isSupervisor ? 'Team reporting' : 'My reports'),

            // ── Report type ─────────────────────────────────────────────
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Report type',
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: Theme.of(context).colorScheme.onSurface)),
                  const SizedBox(height: AppDimens.grid * 1.5),
                  Wrap(
                    spacing: AppDimens.grid,
                    runSpacing: AppDimens.grid,
                    children: [
                      for (final t in ReportType.values)
                        // Supervisor-only reports (team overview, compliance)
                        // are hidden from employees.
                        if (isSupervisor || !t.supervisorOnly)
                          _SelectChip(
                            label: t.label,
                            icon: t.icon,
                            selected: state.type == t,
                            onTap: busy ? null : () => notifier.setType(t),
                          ),
                    ],
                  ),
                  if (state.type == ReportType.distanceZones) ...[
                    const SizedBox(height: AppDimens.grid),
                    Text(
                      'Distance & time per geofence zone, daily',
                      style: AppTextStyles.caption
                          .copyWith(color: context.appColors.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppDimens.grid * 2),

            // ── Scope: team selector (supervisor) ───────────────────────
            if (isSupervisor) ...[
              _TeamSelector(
                value: state.teamId,
                isRequired: state.type.requiresTeam,
                // Compliance is locked to the supervisor's own team (pre-
                // selected, not changeable).
                locked: state.type == ReportType.compliance,
                enabled: !busy,
                onChanged: notifier.setTeam,
              ),
              const SizedBox(height: AppDimens.grid * 2),
            ],

            // ── Date selection ──────────────────────────────────────────
            AppCard(
              child: state.isTeamReport
                  ? _MonthField(
                      month: state.month,
                      enabled: !busy,
                      onPick: notifier.setMonth,
                    )
                  : _RangeField(
                      range: state.range!,
                      enabled: !busy,
                      onPick: notifier.setRange,
                    ),
            ),
            const SizedBox(height: AppDimens.grid * 2),

            // ── Format ──────────────────────────────────────────────────
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Format',
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: Theme.of(context).colorScheme.onSurface)),
                  const SizedBox(height: AppDimens.grid * 1.5),
                  Wrap(
                    spacing: AppDimens.grid,
                    runSpacing: AppDimens.grid,
                    children: [
                      for (final f in ReportFormat.values)
                        // Zone Report is CSV/Excel only — hide the PDF chip.
                        if (state.type.supportsPdf || f != ReportFormat.pdf)
                          _SelectChip(
                            label: f.label,
                            icon: f.icon,
                            selected: state.format == f,
                            onTap: busy ? null : () => notifier.setFormat(f),
                          ),
                    ],
                  ),
                ],
              ),
            ),
            // Inline range error (defensive — the picker already clamps).
            if (rangeTooLong) ...[
              Padding(
                padding: const EdgeInsets.only(
                    left: AppDimens.grid, bottom: AppDimens.grid),
                child: Text(
                  'Please select a date range of 31 days or less',
                  style: AppTextStyles.caption
                      .copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: AppDimens.grid * 3),

            // ── Generate ────────────────────────────────────────────────
            AppButton(
              label: busy ? 'Generating…' : 'Generate report',
              icon: busy ? null : Icons.auto_awesome_rounded,
              isLoading: busy,
              onPressed: (busy || rangeTooLong) ? null : notifier.generate,
            ),
            const SizedBox(height: AppDimens.grid * 2),

            // ── Result ──────────────────────────────────────────────────
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
              child: switch (state.phase) {
                ReportPhase.generating => const _GeneratingCard(),
                ReportPhase.ready => _ReadyCard(state: state, onReset: notifier.reset),
                ReportPhase.failed => _FailedCard(
                    message: state.error ?? 'Something went wrong',
                    onRetry: notifier.generate,
                  ),
                ReportPhase.configuring => const SizedBox.shrink(),
              },
            ),
            const SizedBox(height: AppDimens.grid * 4),
          ],
        ),
      ),
    );
  }
}

// ── Team selector ──────────────────────────────────────────────────────────
class _TeamSelector extends ConsumerWidget {
  const _TeamSelector({
    required this.value,
    required this.isRequired,
    required this.enabled,
    required this.onChanged,
    this.locked = false,
  });

  final int? value;
  final bool isRequired;
  final bool enabled;
  final bool locked; // compliance: pre-select own team, can't change it
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teams = ref.watch(teamListProvider).teams;

    // Locked (compliance): default to the supervisor's first/own team and keep
    // the control read-only.
    if (locked && value == null && teams.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) onChanged(teams.first.id);
      });
    }
    final canEdit = enabled && !locked;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              locked
                  ? 'Team (your team)'
                  : isRequired
                      ? 'Team (required)'
                      : 'Team (optional scope)',
              style: AppTextStyles.bodyMedium
                  .copyWith(color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: AppDimens.grid),
          DropdownButtonFormField<int?>(
            value: value,
            isExpanded: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.groups_rounded),
              hintText: 'Select a team',
            ),
            items: [
              if (!isRequired)
                const DropdownMenuItem(value: null, child: Text('All my teams')),
              for (final t in teams)
                DropdownMenuItem(
                  value: t.id,
                  child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: canEdit ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

// ── Date fields ────────────────────────────────────────────────────────────
class _RangeField extends StatelessWidget {
  const _RangeField({required this.range, required this.enabled, required this.onPick});

  final DateTimeRange range;
  final bool enabled;
  final ValueChanged<DateTimeRange> onPick;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM yyyy');
    final colors = context.appColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldRow(
          icon: Icons.date_range_rounded,
          label: 'Date range',
          value: '${fmt.format(range.start)}  –  ${fmt.format(range.end)}',
          enabled: enabled,
          onTap: () async {
            final now = DateTime.now();
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(now.year - 2),
              lastDate: now,
              initialDateRange: range,
            );
            if (picked == null) return;
            // Enforce the 31-day maximum: clamp the end to start + 31 days.
            if (picked.duration.inDays > 31) {
              onPick(DateTimeRange(
                start: picked.start,
                end: picked.start.add(const Duration(days: 31)),
              ));
            } else {
              onPick(picked);
            }
          },
        ),
        const SizedBox(height: AppDimens.grid * 0.5),
        Text(
          'Reports are available for up to 31 days at a time',
          style: AppTextStyles.caption.copyWith(
            color: colors.textSecondary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }
}

class _MonthField extends StatelessWidget {
  const _MonthField({required this.month, required this.enabled, required this.onPick});

  final DateTime month;
  final bool enabled;
  final ValueChanged<DateTime> onPick;

  @override
  Widget build(BuildContext context) {
    return _FieldRow(
      icon: Icons.calendar_month_rounded,
      label: 'Month',
      value: DateFormat('MMMM yyyy').format(month),
      enabled: enabled,
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: month,
          firstDate: DateTime(now.year - 2),
          lastDate: now,
          helpText: 'Select any day in the month',
        );
        if (picked != null) onPick(picked);
      },
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppDimens.grid * 0.5),
        child: Row(
          children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(width: AppDimens.grid * 1.5),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(value,
                      style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Icon(Icons.edit_calendar_rounded, size: 18, color: colors.textSecondary),
          ],
        ),
      ),
    );
  }
}

// ── Result cards ───────────────────────────────────────────────────────────
class _GeneratingCard extends StatelessWidget {
  const _GeneratingCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return AppCard(
      color: scheme.secondary.withValues(alpha: 0.10),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: scheme.secondary),
          ),
          const SizedBox(width: AppDimens.grid * 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Generating your report',
                        style: AppTextStyles.bodyMedium
                            .copyWith(color: scheme.onSurface)),
                    const _AnimatedDots(),
                  ],
                ),
                const SizedBox(height: 2),
                Text('This can take a few seconds.',
                    style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadyCard extends StatelessWidget {
  const _ReadyCard({required this.state, required this.onReset});

  final ReportUiState state;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final file = state.file;
    final savedToDevice = state.savedToDevice; // web: already in browser downloads
    final name = savedToDevice
        ? 'Saved to your downloads'
        : (file?.path.split('/').last ?? 'report');

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(scale: 0.96 + 0.04 * t.clamp(0, 1), child: child),
      ),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary.withValues(alpha: 0.14),
                  ),
                  child: Icon(state.format.icon, color: scheme.primary),
                ),
                const SizedBox(width: AppDimens.grid * 1.5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(savedToDevice ? 'Report downloaded' : 'Report ready',
                          style: AppTextStyles.bodyMedium
                              .copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700)),
                      Text(name,
                          style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppDimens.grid * 2),
            Row(
              children: [
                if (!savedToDevice) ...[
                  Expanded(
                    child: AppButton(
                      label: 'Share / Save',
                      icon: Icons.ios_share_rounded,
                      onPressed: file == null ? null : () => _share(context, file.path, name),
                    ),
                  ),
                  const SizedBox(width: AppDimens.grid),
                ],
                Expanded(
                  child: AppButton(
                    label: savedToDevice ? 'Generate another' : 'New',
                    variant: AppButtonVariant.secondary,
                    icon: Icons.refresh_rounded,
                    onPressed: onReset,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _share(BuildContext context, String path, String name) async {
    try {
      await Share.shareXFiles([XFile(path)], subject: name);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the share sheet')),
        );
      }
    }
  }
}

class _FailedCard extends StatelessWidget {
  const _FailedCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      color: scheme.error.withValues(alpha: 0.08),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: scheme.error),
              const SizedBox(width: AppDimens.grid * 1.5),
              Expanded(
                child: Text(message,
                    style: AppTextStyles.body.copyWith(color: scheme.onSurface),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.grid * 1.5),
          AppButton(
            label: 'Retry',
            variant: AppButtonVariant.secondary,
            icon: Icons.refresh_rounded,
            expanded: false,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

// ── Bits ───────────────────────────────────────────────────────────────────
class _SelectChip extends StatelessWidget {
  const _SelectChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOutCubic,
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: 0.16) : colors.card,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.grid * 1.75, vertical: AppDimens.grid),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? scheme.primary
                    : colors.textSecondary.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 16,
                    color: selected ? scheme.primary : colors.textSecondary),
                const SizedBox(width: AppDimens.grid * 0.75),
                Text(label,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: selected ? scheme.primary : colors.textSecondary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppDimens.grid, bottom: AppDimens.grid),
      child: Text(
        text.toUpperCase(),
        style: AppTextStyles.caption.copyWith(
          color: context.appColors.textSecondary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Three dots that fade in sequence — the "Generating..." affordance.
class _AnimatedDots extends StatefulWidget {
  const _AnimatedDots();

  @override
  State<_AnimatedDots> createState() => _AnimatedDotsState();
}

class _AnimatedDotsState extends State<_AnimatedDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final active = (_c.value * 3).floor() % 3; // 0,1,2
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Padding(
              padding: const EdgeInsets.only(left: 1.5),
              child: Text(
                '.',
                style: AppTextStyles.bodyMedium.copyWith(
                  color: color.withValues(alpha: i <= active ? 1 : 0.25),
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
