/// Structured parking fees, shared by the app and the admin site; pure Dart
/// so both import the same rules. The JSON shape matches the `fee` column
/// (supabase/migrations/202610250010_spot_fee.sql) and
/// `validFee` in supabase/functions/submit-report/validate.ts.
library;

/// How a vehicle pays. Heavy bikes may also follow another vehicle's rate.
enum FeeMode {
  free('free'),
  posted('posted'),
  hourly('hourly'),
  perVisit('per_visit'),
  daily('daily'),
  sameAsScooter('same_as_scooter'),
  sameAsCar('same_as_car');

  const FeeMode(this.wire);

  /// The value stored as `mode`.
  final String wire;

  /// Modes that follow another vehicle's rate, only for heavy bikes.
  bool get follows => this == sameAsScooter || this == sameAsCar;
}

/// One vehicle's rate. [amount] and caps are whole yuan, periods minutes.
class Rate {
  const Rate(
    this.mode, {
    this.amount,
    this.perMinutes,
    this.dailyCap,
    this.maxMinutes,
  });
  final FeeMode mode;
  final int? amount, perMinutes, dailyCap, maxMinutes;

  /// The rate in [json], or null when it is not one the column accepts:
  /// an unknown mode or key, or any value out of range, optional or not.
  static Rate? fromJson(Object? json, {required bool heavy}) {
    if (json is! Map) return null;
    final mode = FeeMode.values
        .where((m) => m.wire == json['mode'])
        .firstOrNull;
    if (mode == null || (mode.follows && !heavy)) return null;
    const ranges = {
      'amount': (0, 10000),
      'per_minutes': (1, 1440),
      'daily_cap': (0, 10000),
      'max_minutes': (1, 1440),
    };
    final values = <String, int>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (key == 'mode') continue;
      if (!_keys[mode]!.contains(key)) return null;
      final (min, max) = ranges[key]!;
      if (value is! int || value < min || value > max) return null;
      values[key as String] = value;
    }
    final rate = Rate(
      mode,
      amount: values['amount'],
      perMinutes: values['per_minutes'],
      dailyCap: values['daily_cap'],
      maxMinutes: values['max_minutes'],
    );
    return rate.complete ? rate : null;
  }

  /// The keys besides `mode` each mode may carry, as the column allows.
  static const _keys = {
    FeeMode.free: <String>{},
    FeeMode.posted: <String>{},
    FeeMode.sameAsScooter: <String>{},
    FeeMode.sameAsCar: <String>{},
    FeeMode.hourly: {'amount', 'per_minutes', 'daily_cap'},
    FeeMode.perVisit: {'amount', 'max_minutes'},
    FeeMode.daily: {'amount'},
  };

  /// Whether the mode has every value it needs to be shown or stored.
  bool get complete => switch (mode) {
    FeeMode.hourly => amount != null && perMinutes != null,
    FeeMode.perVisit || FeeMode.daily => amount != null,
    _ => true,
  };

  /// Only the keys this mode uses, as the column requires.
  Map<String, Object> toJson() => {
    'mode': mode.wire,
    if (mode == FeeMode.hourly) ...{
      'amount': ?amount,
      'per_minutes': ?perMinutes,
      'daily_cap': ?dailyCap,
    },
    if (mode == FeeMode.perVisit) ...{
      'amount': ?amount,
      'max_minutes': ?maxMinutes,
    },
    if (mode == FeeMode.daily) 'amount': ?amount,
  };

  /// The rate as riders read it, e.g. 每小時 20 元，當日上限 100 元.
  String get text => switch (mode) {
    FeeMode.free => '免費',
    FeeMode.posted => '依現場公告',
    FeeMode.hourly =>
      '${_every(perMinutes ?? 60)} ${amount ?? 0} 元'
          '${dailyCap == null ? '' : '，當日上限 $dailyCap 元'}',
    FeeMode.perVisit =>
      '每次 ${amount ?? 0} 元'
          '${maxMinutes == null ? '' : '（${_span(maxMinutes!)}內）'}',
    FeeMode.daily => '每日 ${amount ?? 0} 元',
    FeeMode.sameAsScooter => '比照機車費率',
    FeeMode.sameAsCar => '比照汽車費率',
  };

  @override
  bool operator ==(Object other) =>
      other is Rate &&
      other.mode == mode &&
      other.amount == amount &&
      other.perMinutes == perMinutes &&
      other.dailyCap == dailyCap &&
      other.maxMinutes == maxMinutes;

  @override
  int get hashCode =>
      Object.hash(mode, amount, perMinutes, dailyCap, maxMinutes);
}

String _every(int minutes) => minutes == 60
    ? '每小時'
    : minutes % 60 == 0
    ? '每 ${minutes ~/ 60} 小時'
    : '每 $minutes 分鐘';

String _span(int minutes) =>
    minutes % 60 == 0 ? '${minutes ~/ 60} 小時' : '$minutes 分鐘';

/// A rate per vehicle; a null vehicle is unconfirmed.
class Fee {
  const Fee({this.scooter, this.heavy});
  final Rate? scooter, heavy;

  /// The fee in [json]; vehicles whose rate is not valid read as unconfirmed.
  static Fee fromJson(Object? json) => json is Map
      ? Fee(
          scooter: Rate.fromJson(json['scooter'], heavy: false),
          heavy: Rate.fromJson(json['heavy'], heavy: true),
        )
      : const Fee();

  bool get isEmpty => scooter == null && heavy == null;

  Map<String, Object> toJson() => {
    if (scooter case final rate?) 'scooter': rate.toJson(),
    if (heavy case final rate?) 'heavy': rate.toJson(),
  };

  /// One line for both vehicles, in the style of the imported fee notes:
  /// 每日 30 元（大型重機比照機車費率）, or 機車免費；大型重機每小時 20 元.
  String get summary {
    final s = scooter?.text;
    final h = heavy;
    if (h == null) return s == null ? '' : '$s（大型重機費率未確認）';
    if (s == null) return '大型重機${h.text}';
    return h.mode.follows ? '$s（大型重機${h.text}）' : '機車$s；大型重機${h.text}';
  }

  @override
  bool operator ==(Object other) =>
      other is Fee && other.scooter == scooter && other.heavy == heavy;

  @override
  int get hashCode => Object.hash(scooter, heavy);
}

/// The `fee_note` text stored beside [fee]: its summary, or the default
/// note when neither vehicle is known.
String feeNoteOf(Fee? fee) =>
    fee == null || fee.isEmpty ? '請依現場公告' : fee.summary;
