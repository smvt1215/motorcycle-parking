import '../../ui/adaptive/adaptive.dart';

const clusterBadgeSize = 56.0;

/// The preview map and Google bitmap markers use the same painter.
class ClusterBadge extends StatelessWidget {
  const ClusterBadge({super.key, required this.count});
  final int count;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$count 個停車點，點擊放大地圖',
    child: SizedBox.square(
      dimension: clusterBadgeSize,
      child: CustomPaint(painter: ClusterBadgePainter(count)),
    ),
  );
}

class ClusterBadgePainter extends CustomPainter {
  const ClusterBadgePainter(this.count);
  final int count;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 2;
    canvas.drawCircle(center, radius, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      radius - 3,
      Paint()..color = const Color(0xff007f9c),
    );
    final text = TextPainter(
      text: TextSpan(
        text: '$count',
        style: TextStyle(
          color: Colors.white,
          fontSize: count < 1000 ? 20 : 16,
          fontWeight: FontWeight.w700,
          fontFamily: 'Outfit',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
    text.dispose();
  }

  @override
  bool shouldRepaint(ClusterBadgePainter oldDelegate) =>
      oldDelegate.count != count;
}
