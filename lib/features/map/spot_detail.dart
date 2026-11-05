import '../../domain/eligibility.dart';
import '../../domain/eligibility_display.dart';
import '../../domain/four_sign.dart';
import '../../domain/four_sign_display.dart';
import '../../domain/spot_detail_display.dart';
import '../../models/parking.dart';
import '../../models/zone_entries.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/detail_tokens.dart';
import '../../ui/four_sign_plates.dart';
import '../../domain/availability_beta_display.dart';
import 'beta_tag.dart';
import 'spot_photos.dart';
import 'vehicle_sheet.dart' show SmallPlateStack, platesOf;

/// The full-page details' top (canvas v154 A2, A4, A10): 返回 (iOS chevron
/// and 返回, Android arrow_back; both close the details), the name with
/// 收藏 and 分享 beside it (user decision 2026-10-31), the type and
/// distance, and the four plates as a table of contents: tapping one jumps
/// to its section, and a bar marks the section shown.
class SpotDetailHeader extends StatelessWidget {
  const SpotDetailHeader({
    super.key,
    required this.spot,
    required this.subtitle,
    required this.plates,
    required this.current,
    required this.favorite,
    required this.onFavorite,
    required this.onShare,
    required this.onBack,
    required this.onPlate,
    this.titleNote,
  });
  final ParkingSpot spot;
  final String subtitle;
  final List<SignPlate> plates;
  final FourSignFace current;
  final bool favorite;
  final VoidCallback onFavorite, onBack;
  final Future<void> Function(BuildContext) onShare;
  final ValueChanged<FourSignFace> onPlate;

  /// A line under the name (#316's 部分內容審核中).
  final Widget? titleNote;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    final text = Theme.of(context).textTheme;
    final target = isCupertino ? 44.0 : 48.0;
    final back = isCupertino
        ? Semantics(
            button: true,
            label: '返回地圖（關閉詳情）',
            excludeSemantics: true,
            child: InkWell(
              key: const ValueKey('spot-detail-back'),
              onTap: onBack,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: target),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chevron_left, size: 30, color: c.link),
                    Text('返回', style: TextStyle(fontSize: 17, color: c.link)),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          )
        : IconButton(
            key: const ValueKey('spot-detail-back'),
            tooltip: '返回地圖（關閉詳情）',
            constraints: BoxConstraints.tightFor(width: target, height: target),
            onPressed: onBack,
            icon: Icon(Icons.arrow_back, color: c.ink),
          );
    final iconButton = BoxConstraints.tightFor(width: target, height: target);
    return Column(
      key: const ValueKey('spot-detail-header'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(right: isCupertino ? 0 : 8),
              child: back,
            ),
            if (!isCupertino)
              Expanded(child: _title(context, text, c))
            else
              const Spacer(),
            IconButton(
              key: const ValueKey('spot-detail-favorite'),
              tooltip: favorite ? '取消收藏' : '收藏停車點',
              constraints: iconButton,
              onPressed: onFavorite,
              icon: Icon(favorite ? Icons.bookmark : Icons.bookmark_outline),
              color: c.link,
            ),
            Builder(
              builder: (buttonContext) => IconButton(
                key: const ValueKey('spot-detail-share'),
                tooltip: '分享停車點',
                constraints: iconButton,
                onPressed: () =>
                    runAction(buttonContext, () => onShare(buttonContext)),
                icon: Icon(isCupertino ? Icons.ios_share : Icons.share),
                color: c.muted,
              ),
            ),
          ],
        ),
        // iOS keeps 返回 on its own row and the name under it (A2); Android
        // puts the name beside arrow_back.
        if (isCupertino) ...[
          const SizedBox(height: 2),
          _title(context, text, c),
        ],
        const SizedBox(height: 10),
        FourSignPlates(
          key: const ValueKey('spot-detail-toc'),
          plates: plates,
          dense: true,
          current: current,
          onTap: onPlate,
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _title(BuildContext context, TextTheme text, DetailColors c) =>
      Padding(
        padding: EdgeInsets.only(top: isCupertino ? 0 : 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                spot.name,
                key: const ValueKey('spot-detail-name'),
                style: text.titleLarge?.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                  color: c.ink,
                ),
              ),
            ),
            ?titleNote,
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: text.bodySmall?.copyWith(
                fontSize: 13,
                color: c.muted,
                height: 1.4,
              ),
            ),
          ],
        ),
      );
}

/// One of the details' sections: a small grey heading (能不能停…), its
/// content, and a hairline under it.
class DetailSection extends StatelessWidget {
  const DetailSection({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.gap = 12,
    this.last = false,
  });
  final String title;
  final String? trailing;
  final List<Widget> children;
  final double gap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    final heading = Semantics(
      header: true,
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: c.muted,
          height: 1.4,
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (trailing == null)
            heading
          else
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 8,
              children: [
                heading,
                Text(trailing!, style: TextStyle(fontSize: 12, color: c.muted)),
              ],
            ),
          for (final child in children) ...[SizedBox(height: gap), child],
        ],
      ),
    );
  }
}

/// ①'s card (A2): the conclusion for the rider's vehicle in the marker's
/// colour and icon, what it rests on, and dated notices.
class VerdictCard extends StatelessWidget {
  const VerdictCard({
    super.key,
    required this.status,
    required this.headline,
    this.explanation = '',
    this.basis,
    this.notices = const [],
    this.reported = false,
    this.banned = false,
  });
  final EligibilityStatus status;
  final String headline, explanation;
  final String? basis;
  final List<NoticeLine> notices;

  /// A rider's claim: people, never a tick.
  final bool reported;

  /// 現在禁停.
  final bool banned;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    final (fg, tint, icon) = switch (status) {
      EligibilityStatus.allowed => (
        c.allowed,
        c.allowedTint,
        Icons.verified_user,
      ),
      EligibilityStatus.conditional => (
        c.conditional,
        c.conditionalTint,
        banned ? Icons.block : Icons.timer_outlined,
      ),
      EligibilityStatus.notAllowed => (c.denied, c.deniedTint, Icons.block),
      EligibilityStatus.unverified => (
        c.unverified,
        c.unverifiedTint,
        reported ? Icons.groups_outlined : Icons.help_outline,
      ),
    };
    return MergeSemantics(
      child: Container(
        key: const ValueKey('spot-decision'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 26, color: fg),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    headline,
                    key: const ValueKey('spot-decision-label'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: fg,
                      height: 1.3,
                    ),
                  ),
                  if (explanation.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      explanation,
                      key: const ValueKey('spot-decision-explanation'),
                      style: TextStyle(
                        fontSize: 13,
                        color: c.ink,
                        height: 1.45,
                      ),
                    ),
                  ],
                  if (basis case final basis?) ...[
                    const SizedBox(height: 4),
                    Text(
                      basis,
                      key: const ValueKey('spot-decision-basis'),
                      style: TextStyle(
                        fontSize: 12,
                        color: c.muted,
                        height: 1.45,
                      ),
                    ),
                  ],
                  for (final (i, notice) in notices.indexed) ...[
                    const SizedBox(height: 4),
                    Row(
                      key: ValueKey('spot-decision-notice-$i'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          // An ended notice changes the icon and says so in
                          // words; amber only adds to that (§8.7 C4).
                          child: Icon(
                            notice.expired
                                ? Icons.event_busy_outlined
                                : Icons.calendar_today_outlined,
                            size: 16,
                            color: notice.expired ? c.conditional : c.muted,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            notice.text,
                            style: TextStyle(
                              fontSize: 13,
                              color: c.ink,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ①'s rows under the card (A2): 限時, 禁停, 共用, each with its icon,
/// then 「只列 X 適用的規定」.
class DetailRulesView extends StatelessWidget {
  const DetailRulesView({
    super.key,
    required this.rules,
    required this.vehicle,
    this.scope = true,
  });
  final List<DetailRule> rules;
  final VehicleType vehicle;

  /// Whether to say 「只列 X 適用的規定」 (not where no vehicle may park).
  final bool scope;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    final large = MediaQuery.textScalerOf(context).scale(15) > 22;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rules)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: MergeSemantics(child: _ruleRow(r, c, large)),
          ),
        if (scope)
          Text(
            '只列${vehicle.label}適用的規定',
            key: const ValueKey('detail-rules-scope'),
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
      ],
    );
  }

  Widget _ruleRow(DetailRule r, DetailColors c, bool large) {
    final (icon, color) = switch (r.kind) {
      DetailRuleKind.limit => (Icons.timer_outlined, c.conditional),
      DetailRuleKind.noParking => (Icons.block, c.denied),
      DetailRuleKind.shared => (Icons.directions_car_outlined, c.link),
      DetailRuleKind.special => (Icons.info_outline, c.conditional),
      DetailRuleKind.only => (Icons.directions_car_outlined, c.ink),
      DetailRuleKind.motorcycle => (Icons.block, c.denied),
    };
    final label = Text(
      r.label,
      style: TextStyle(fontSize: 15, color: c.muted, height: 1.45),
    );
    final value = Text(
      r.text,
      key: ValueKey('detail-rule-${r.kind.name}'),
      style: TextStyle(fontSize: 15, color: c.ink, height: 1.45),
    );
    if (large) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              label,
            ],
          ),
          value,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 8),
        SizedBox(width: 48, child: label),
        const SizedBox(width: 8),
        Expanded(child: value),
      ],
    );
  }
}

/// ②'s answer when the spot stands as one (A2): the plate's answer, large,
/// and what it means.
class SeatWholeView extends StatelessWidget {
  const SeatWholeView({
    super.key,
    required this.main,
    required this.explanation,
  });
  final String main, explanation;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    return Column(
      key: const ValueKey('detail-seat-whole'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          main,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.3,
            color: c.ink,
          ),
        ),
        if (explanation.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            explanation,
            style: TextStyle(fontSize: 14, height: 1.5, color: c.ink),
          ),
        ],
      ],
    );
  }
}

/// ②'s rows, place by place (A10, A12): the name, its bay and state, the
/// official count or total, then room for riders' reports. [riderRow] is
/// where #189 adds 車友回報 under each place; null shows none.
class SeatRowsView extends StatelessWidget {
  const SeatRowsView({
    super.key,
    required this.rows,
    required this.note,
    this.riderRow,
    this.betaCities,
  });
  final List<SeatRow> rows;
  final String note;

  /// The Beta cities, when the spot is in one; null otherwise. Shown, as
  /// the whole lot's 有沒有位 does, once any row reads an official count.
  final List<String>? betaCities;
  final Widget? Function(SignArea area)? riderRow;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, row) in rows.indexed) ...[
          if (i > 0) Divider(height: 20, color: c.divider),
          Column(
            key: ValueKey('detail-seat-row-$i'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                row.name,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: c.ink,
                  height: 1.4,
                ),
              ),
              if (row.sub.isNotEmpty)
                Text(
                  row.sub,
                  style: TextStyle(fontSize: 13, color: c.muted, height: 1.4),
                ),
              const SizedBox(height: 6),
              MergeSemantics(
                child: _line(
                  c,
                  '官方',
                  row.official,
                  row.officialNote,
                  key: ValueKey('detail-seat-official-$i'),
                ),
              ),
              ?riderRow?.call(row.area),
            ],
          ),
        ],
        if (betaCities case final beta? when rows.any((r) => r.counted)) ...[
          const SizedBox(height: 12),
          Semantics(
            container: true,
            label: '$betaTagLabel，${betaDetailNote(beta)}',
            excludeSemantics: true,
            child: Row(
              key: const ValueKey('availability-beta-note'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: BetaTag(),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    betaDetailNote(beta),
                    style: TextStyle(
                      fontSize: 12,
                      color: c.muted,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.info_outline, size: 16, color: c.muted),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                note,
                style: TextStyle(fontSize: 12, color: c.muted, height: 1.5),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _line(
    DetailColors c,
    String label,
    String value,
    String note, {
    Key? key,
  }) => Wrap(
    key: key,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    children: [
      SizedBox(
        width: 60,
        child: Text(label, style: TextStyle(fontSize: 13, color: c.muted)),
      ),
      Text(
        value,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: c.ink,
        ),
      ),
      if (note.isNotEmpty)
        Text(note, style: TextStyle(fontSize: 12, color: c.muted)),
    ],
  );
}

/// ③ (A2, A8, A10): a white notice card per place open now, or one for
/// all of them, then the places closed to the vehicle and those open
/// later. The card is paper in both themes (A4).
class FeeSectionView extends StatelessWidget {
  const FeeSectionView({
    super.key,
    required this.section,
    required this.vehicle,
    this.extraNote = '',
  });
  final FeeSection section;
  final VehicleType vehicle;

  /// The spot's own fee text when it adds to the places' rates.
  final String extraNote;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, card) in section.cards.indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          _FeeCardView(
            key: ValueKey('detail-fee-card-$i'),
            card: card,
            vehicle: vehicle,
          ),
        ],
        if (section.sameNote.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            key: const ValueKey('detail-fee-same'),
            children: [
              Text('其他分區', style: TextStyle(fontSize: 13, color: c.muted)),
              const SizedBox(width: 12),
              Text(
                section.sameNote,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.ink,
                ),
              ),
            ],
          ),
        ],
        for (final (i, name) in section.closed.indexed) ...[
          const SizedBox(height: 10),
          MergeSemantics(
            child: Container(
              key: ValueKey('detail-fee-closed-$i'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: c.chip,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.block, size: 18, color: c.denied),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      style: TextStyle(fontSize: 14, color: c.ink, height: 1.4),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${vehicle.label}不能停',
                    style: TextStyle(fontSize: 14, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
        ],
        for (final (i, line) in section.later.indexed) ...[
          const SizedBox(height: 10),
          Row(
            key: ValueKey('detail-fee-later-$i'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.schedule, size: 18, color: c.conditional),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$line。',
                  style: TextStyle(fontSize: 14, color: c.ink, height: 1.5),
                ),
              ),
            ],
          ),
        ],
        if (extraNote.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            extraNote,
            key: const ValueKey('fee-extra-note'),
            style: TextStyle(fontSize: 13, color: c.ink, height: 1.5),
          ),
        ],
        const SizedBox(height: 10),
        Text('請以現場公告為準', style: TextStyle(fontSize: 12, color: c.muted)),
      ],
    );
  }
}

class _FeeCardView extends StatelessWidget {
  const _FeeCardView({super.key, required this.card, required this.vehicle});
  final FeeCard card;
  final VehicleType vehicle;

  @override
  Widget build(BuildContext context) {
    const ink = DetailColors.paperInk, muted = DetailColors.paperMuted;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final amount = Text(
      card.main,
      key: const ValueKey('detail-fee-main'),
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        height: 1.3,
        color: card.unknown ? muted : ink,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DetailColors.paper,
        borderRadius: BorderRadius.circular(10),
        border: dark ? null : Border.all(color: const Color(0xffc9d3d6)),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: ink),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              card.header,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 6),
            if (card.vehicleHeader)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  ExcludeSemantics(
                    child: SmallPlateStack(plates: platesOf(vehicle)),
                  ),
                  amount,
                ],
              )
            else
              amount,
            if (card.detail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                card.detail,
                key: const ValueKey('detail-fee-detail'),
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
            ],
            if (card.note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                card.note,
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ],
            if (card.others.isNotEmpty || card.closedTimes.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(height: 1, color: DetailColors.paperDivider),
              const SizedBox(height: 8),
            ],
            if (card.others.isNotEmpty) ...[
              const Text('其他時段', style: TextStyle(fontSize: 12, color: muted)),
              for (final (i, (period, words)) in card.others.indexed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: MergeSemantics(
                    child: Row(
                      key: ValueKey('detail-fee-other-$i'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            period,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            words,
                            textAlign: TextAlign.end,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            if (card.closedTimes.isNotEmpty) ...[
              if (card.others.isNotEmpty) const SizedBox(height: 8),
              const Text('非開放時段', style: TextStyle(fontSize: 12, color: muted)),
              const SizedBox(height: 6),
              MergeSemantics(
                child: Container(
                  key: const ValueKey('detail-fee-closed-times'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: DetailColors.paperRow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(
                          Icons.block,
                          size: 16,
                          color: DetailColors.paperDenied,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          card.closedTimes,
                          style: const TextStyle(fontSize: 14, color: muted),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${vehicle.label}不能停',
                        style: const TextStyle(fontSize: 14, color: muted),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

IconData _bayIcon(BayKind? kind) => switch (kind) {
  BayKind.motorcycle => Icons.moped,
  BayKind.scooterHeavy => Icons.two_wheeler,
  BayKind.heavy => Icons.two_wheeler,
  BayKind.carMotorcycle => Icons.directions_car,
  BayKind.car => Icons.directions_car,
  BayKind.disabled => Icons.accessible,
  BayKind.ev => Icons.ev_station,
  null => Icons.local_parking,
};

/// A place's tile (A2): its bay on asphalt, a 44-point square.
class _Tile extends StatelessWidget {
  const _Tile({this.kind, this.icon, this.light = false});
  final BayKind? kind;
  final IconData? icon;

  /// The entrance's light tile instead of asphalt.
  final bool light;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    return ExcludeSemantics(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: light ? c.chip : DetailColors.asphalt,
          borderRadius: BorderRadius.circular(6),
          border: kind == BayKind.heavy || kind == BayKind.scooterHeavy
              ? Border.all(color: const Color(0xfff2c200), width: 2)
              : null,
        ),
        child: kind == BayKind.carMotorcycle
            ? const Stack(
                children: [
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Icon(
                      Icons.directions_car,
                      size: 16,
                      color: DetailColors.asphaltInk,
                    ),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Icon(
                      Icons.moped,
                      size: 16,
                      color: DetailColors.asphaltInk,
                    ),
                  ),
                ],
              )
            : Icon(
                icon ?? _bayIcon(kind),
                size: 24,
                color: light ? c.link : DetailColors.asphaltInk,
              ),
      ),
    );
  }
}

/// ④ (A2, A10): the entrance, each place open to the vehicle (the one
/// chosen marked 目前選定), the places closed to it, the photos, and the
/// address with its coordinates and 複製.
class WhereView extends StatelessWidget {
  const WhereView({
    super.key,
    required this.cards,
    required this.closedNote,
    this.pendingNote = '',
    required this.address,
    required this.coordinates,
    required this.onCopy,
    this.entrance = '',
    this.guide = '',
    this.photos = const [],
    this.selectedId,
    this.onSelect,
    this.copied = false,
  });
  final List<WhereCard> cards;
  final String entrance, guide, closedNote, pendingNote, address, coordinates;
  final List<String> photos;

  /// The segment chosen (A10); null when none is.
  final String? selectedId;

  /// Chooses a segment; null when places cannot be chosen.
  final ValueChanged<String?>? onSelect;
  final VoidCallback onCopy;

  /// Whether 複製 just copied.
  final bool copied;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    Widget row({
      required Widget tile,
      required List<Widget> lines,
      Key? key,
      VoidCallback? onTap,
      bool? selected,
    }) {
      final content = Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            tile,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, l) in lines.indexed) ...[
                    if (i > 0) const SizedBox(height: 3),
                    l,
                  ],
                ],
              ),
            ),
          ],
        ),
      );
      if (onTap == null) return KeyedSubtree(key: key, child: content);
      return Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: content,
        ),
      );
    }

    Text bold(String t) => Text(
      t,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: c.ink,
        height: 1.4,
      ),
    );
    Text small(String t, {Color? color}) => Text(
      t,
      style: TextStyle(fontSize: 13, color: color ?? c.muted, height: 1.4),
    );
    Text body(String t) =>
        Text(t, style: TextStyle(fontSize: 14, color: c.ink, height: 1.5));
    final selectable = onSelect != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (entrance.isNotEmpty) ...[
          row(
            key: const ValueKey('detail-where-entrance'),
            tile: const _Tile(icon: Icons.login, light: true),
            lines: [bold('入口'), body(entrance)],
          ),
          const SizedBox(height: 8),
        ],
        for (final (i, card) in cards.indexed) ...[
          row(
            key: ValueKey('detail-where-card-$i'),
            tile: _Tile(kind: card.area.bayKind),
            selected: selectable ? card.area.id == selectedId : null,
            onTap: selectable && card.area.id != null
                ? () => onSelect!(
                    card.area.id == selectedId ? null : card.area.id,
                  )
                : null,
            lines: [
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  bold(card.name),
                  if (selectable && card.area.id == selectedId)
                    Container(
                      key: const ValueKey('detail-where-selected'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: c.ink,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '目前選定',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.surface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              if (card.sub.isNotEmpty) small(card.sub),
              if (card.state.isNotEmpty)
                Text(
                  card.state,
                  style: TextStyle(fontSize: 12, color: c.conditional),
                ),
              if (card.limit.isNotEmpty) small(card.limit, color: c.ink),
              if (card.guide.isNotEmpty) body(card.guide),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (guide.isNotEmpty) ...[
          row(
            key: const ValueKey('detail-where-guide'),
            tile: const _Tile(icon: Icons.signpost_outlined, light: true),
            lines: [bold('停車指引'), body(guide)],
          ),
          const SizedBox(height: 8),
        ],
        if (photos.isNotEmpty) ...[
          SpotPhotoThumbs(photos: photos),
          const SizedBox(height: 10),
        ],
        if (closedNote.isNotEmpty) ...[
          Text(
            closedNote,
            key: const ValueKey('detail-where-closed'),
            style: TextStyle(fontSize: 13, color: c.muted, height: 1.45),
          ),
          const SizedBox(height: 10),
        ],
        if (pendingNote.isNotEmpty) ...[
          Text(
            pendingNote,
            key: const ValueKey('detail-where-pending'),
            style: TextStyle(fontSize: 13, color: c.muted, height: 1.45),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 6),
        Semantics(
          header: true,
          child: Text(
            '地址與座標',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: c.ink,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (address.isNotEmpty)
                    Text(
                      address,
                      key: const ValueKey('detail-address'),
                      style: TextStyle(fontSize: 15, color: c.ink, height: 1.5),
                    ),
                  Text(
                    coordinates,
                    key: const ValueKey('detail-coordinates'),
                    style: TextStyle(
                      fontSize: 13,
                      color: c.muted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (copied)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        '已複製地址與座標',
                        key: const ValueKey('detail-copied'),
                        style: TextStyle(fontSize: 12, color: c.link),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox.square(
              dimension: isCupertino ? 44 : 48,
              child: IconButton(
                key: const ValueKey('detail-copy'),
                tooltip: '複製地址與座標',
                onPressed: onCopy,
                style: IconButton.styleFrom(
                  side: BorderSide(color: c.border, width: 1.5),
                ),
                icon: Icon(
                  copied ? Icons.check : Icons.content_copy,
                  size: 20,
                  color: c.ink,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 有沒有位・怎麼算錢 folded into one row where no motorcycle may park
/// (A2b): the main message is not drowned by a car's spaces and rates, yet
/// the data stays one tap away, opened in place.
class NotParkableFold extends StatelessWidget {
  const NotParkableFold({
    super.key,
    required this.expanded,
    required this.onToggle,
  });
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const ValueKey('detail-fold-toggle'),
              onTap: onToggle,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                constraints: BoxConstraints(minHeight: isCupertino ? 44 : 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.visibility_off_outlined, color: c.muted),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            notParkableFoldTitle,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: c.ink,
                              height: 1.4,
                            ),
                          ),
                          Text(
                            notParkableFoldSub,
                            style: TextStyle(fontSize: 12, color: c.muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: c.ink,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!expanded) ...[
          const SizedBox(height: 8),
          Text(
            notParkableFoldHint,
            style: TextStyle(fontSize: 12, color: c.muted, height: 1.45),
          ),
        ],
      ],
    );
  }
}
