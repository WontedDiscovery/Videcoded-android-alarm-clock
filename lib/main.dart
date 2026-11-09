import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();
final notifier = FlutterLocalNotificationsPlugin();
final store = Store();
String? initialRingKey; // 點通知啟動 App 時，要直接打開的響鈴
String? openRingKey; // 目前開著的響鈴頁，避免重複開
const dayNames = ['一', '二', '三', '四', '五', '六', '日'];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  tzdata.initializeTimeZones();
  await notifier.initialize(
    const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    onDidReceiveNotificationResponse: (r) => openRing(keyFromPayload(r.payload)),
  );
  final launch = await notifier.getNotificationAppLaunchDetails();
  if (launch?.didNotificationLaunchApp ?? false) {
    initialRingKey = keyFromPayload(launch?.notificationResponse?.payload);
  }
  await store.settleExpired();
  await store.reschedule();
  store.startTicker();
  runApp(const WakeApp());
}

class WakeApp extends StatelessWidget {
  const WakeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '醒動鬧鐘',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

// ───────── 共用工具 ─────────
String hm(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

String dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String exerciseName(String e) => switch (e) {
      'jj' => '開合跳',
      'raise' => '舉手',
      _ => '深蹲',
    };

String dayText(List<int> days) =>
    days.length == 7 ? '每天' : '週${days.map((d) => dayNames[d - 1]).join('、')}';

String resultText(String r) => switch (r) {
      'success' => '成功',
      'failed' => '失敗',
      _ => '一般關閉',
    };

int levelOf(int p) {
  const th = [0, 100, 250, 450, 700];
  if (p >= 700) return 5 + (p - 700) ~/ 300;
  var lv = 1;
  for (var i = 1; i < th.length; i++) {
    if (p >= th[i]) lv = i + 1;
  }
  return lv;
}

String? keyFromPayload(String? payload) {
  final parts = payload?.split('|');
  if (parts == null || parts.length != 2) return null;
  return '${parts[0]}_${parts[1]}';
}

void openRing(String? key) {
  if (key == null || key == openRingKey || store.find(key) == null) return;
  navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => RingPage(pendingKey: key)));
}

Future<void> askNotificationPermission() async {
  await notifier
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

Future<void> askExactAlarmPermission() async {
  await notifier
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestExactAlarmsPermission();
}

// ───────── 資料模型 ─────────
class Alarm {
  Alarm({
    required this.id,
    required this.hour,
    required this.minute,
    required this.days,
    required this.exercise,
    required this.target,
    required this.penalty,
    this.enabled = true,
  });

  final int id;
  int hour;
  int minute;
  List<int> days; // 1 = 週一 … 7 = 週日
  String exercise; // jj 開合跳 / raise 舉手 / squat 深蹲
  int target;
  bool penalty; // 貪睡懲罰
  bool enabled;

  String get timeText => hm(hour, minute);

  Map<String, dynamic> toJson() => {
        'id': id,
        'hour': hour,
        'minute': minute,
        'days': days,
        'exercise': exercise,
        'target': target,
        'penalty': penalty,
        'enabled': enabled,
      };

  factory Alarm.fromJson(Map<String, dynamic> j) => Alarm(
        id: j['id'],
        hour: j['hour'],
        minute: j['minute'],
        days: List<int>.from(j['days'] as List),
        exercise: j['exercise'],
        target: j['target'],
        penalty: j['penalty'],
        enabled: j['enabled'],
      );
}

class Pending {
  Pending({
    required this.alarmId,
    required this.ringStart,
    required this.snooze,
    required this.target,
    required this.ids,
  });

  final int alarmId;
  final int ringStart; // 本次響鈴起算時間（毫秒）
  final int snooze; // 第幾次貪睡（0 = 原本的鬧鈴）
  final int target;
  final List<int> ids; // 已排程的通知編號，結束時要取消

  String get key => '${alarmId}_$ringStart';

  Map<String, dynamic> toJson() => {
        'alarmId': alarmId,
        'ringStart': ringStart,
        'snooze': snooze,
        'target': target,
        'ids': ids,
      };

  factory Pending.fromJson(Map<String, dynamic> j) => Pending(
        alarmId: j['alarmId'],
        ringStart: j['ringStart'],
        snooze: j['snooze'],
        target: j['target'],
        ids: List<int>.from(j['ids'] as List),
      );
}

class WakeLog {
  WakeLog({
    required this.day,
    required this.alarmId,
    required this.result,
    required this.reps,
    required this.target,
    required this.snooze,
  });

  final String day;
  final int alarmId;
  final String result; // success / failed / normalClose
  final int reps;
  final int target;
  final int snooze;

  Map<String, dynamic> toJson() => {
        'day': day,
        'alarmId': alarmId,
        'result': result,
        'reps': reps,
        'target': target,
        'snooze': snooze,
      };

  factory WakeLog.fromJson(Map<String, dynamic> j) => WakeLog(
        day: j['day'],
        alarmId: j['alarmId'],
        result: j['result'],
        reps: j['reps'],
        target: j['target'],
        snooze: j['snooze'],
      );
}

// ───────── 狀態與排程 ─────────
class Store extends ChangeNotifier {
  static const int windowMs = 3 * 60 * 1000; // 響鈴後 3 分鐘內要完成
  static const int burstCount = 6; // 每次響鈴連發 6 則通知
  static const int burstGapMs = 30 * 1000; // 每則間隔 30 秒

  List<Alarm> alarms = [];
  List<Pending> pending = [];
  List<WakeLog> logs = [];
  int streak = 0;
  int points = 0;
  bool normalClose = false;
  int nextId = 1;

  SharedPreferences? _prefs;
  Timer? _ticker;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString('state');
    if (raw == null) return;
    final d = jsonDecode(raw) as Map<String, dynamic>;
    alarms = [for (final e in d['alarms'] as List) Alarm.fromJson(e as Map<String, dynamic>)];
    pending = [for (final e in d['pending'] as List) Pending.fromJson(e as Map<String, dynamic>)];
    logs = [for (final e in d['logs'] as List) WakeLog.fromJson(e as Map<String, dynamic>)];
    streak = d['streak'] as int;
    points = d['points'] as int;
    normalClose = d['normalClose'] as bool;
    nextId = d['nextId'] as int;
  }

  Future<void> save() async {
    final data = {
      'alarms': alarms.map((a) => a.toJson()).toList(),
      'pending': pending.map((p) => p.toJson()).toList(),
      'logs': logs.map((l) => l.toJson()).toList(),
      'streak': streak,
      'points': points,
      'normalClose': normalClose,
      'nextId': nextId,
    };
    await _prefs!.setString('state', jsonEncode(data));
    notifyListeners();
  }

  int newId() => nextId++;

  Alarm? alarmById(int id) {
    for (final a in alarms) {
      if (a.id == id) return a;
    }
    return null;
  }

  Pending? find(String key) {
    for (final p in pending) {
      if (p.key == key) return p;
    }
    return null;
  }

  Pending? activeRing() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final p in pending) {
      if (p.ringStart <= now && now < p.ringStart + windowMs) return p;
    }
    return null;
  }

  void startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      await settleExpired();
      notifyListeners();
    });
  }

  // 補排 7 天內還沒排的響鈴（已排過的不會重排）
  Future<void> reschedule() async {
    final now = DateTime.now();
    for (final a in alarms) {
      if (!a.enabled) continue;
      for (var d = 0; d <= 7; d++) {
        final t = DateTime(now.year, now.month, now.day + d, a.hour, a.minute);
        if (!t.isAfter(now) || !a.days.contains(t.weekday)) continue;
        final start = t.millisecondsSinceEpoch;
        if (find('${a.id}_$start') != null) continue;
        await _addBurst(a, start, 0);
      }
    }
    await save();
  }

  Future<void> rebuildSchedule() async {
    for (final a in alarms) {
      await _cancelFuture(a.id);
    }
    await reschedule();
  }

  Future<void> upsert(Alarm a) async {
    await _cancelFuture(a.id);
    final i = alarms.indexWhere((x) => x.id == a.id);
    if (i >= 0) {
      alarms[i] = a;
    } else {
      alarms.add(a);
    }
    await reschedule();
  }

  Future<void> setEnabled(Alarm a, bool on) async {
    a.enabled = on;
    if (!on) await _cancelFuture(a.id);
    await reschedule();
  }

  Future<void> remove(int id) async {
    for (final p in pending.where((e) => e.alarmId == id).toList()) {
      await _drop(p);
    }
    alarms.removeWhere((a) => a.id == id);
    await save();
  }

  // 完成或結束：取消剩下的通知、寫入紀錄、更新連續天數與積分
  Future<void> resolve(String key, String result, {int reps = 0}) async {
    final p = find(key);
    if (p == null) return;
    await _drop(p);
    if (result == 'success') {
      streak += 1;
      points += (p.snooze > 0 ? 5 : 10) + (streak % 7 == 0 ? 20 : 0);
    } else {
      streak = 0;
    }
    logs.insert(
      0,
      WakeLog(
        day: dayKey(DateTime.now()),
        alarmId: p.alarmId,
        result: result,
        reps: reps,
        target: p.target,
        snooze: p.snooze,
      ),
    );
    if (logs.length > 200) logs.removeRange(200, logs.length);
    await save();
  }

  Future<void> snooze(String key) async {
    final p = find(key);
    if (p == null || p.snooze >= 2) return;
    await _drop(p);
    final a = alarmById(p.alarmId);
    if (a != null) {
      final start = DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch;
      await _addBurst(a, start, p.snooze + 1);
    }
    await save();
  }

  // 時限已過但還沒結算的（例如沒開 App），補記為失敗
  Future<void> settleExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final p in pending.where((e) => e.ringStart + windowMs <= now).toList()) {
      await resolve(p.key, 'failed');
    }
  }

  Future<void> _addBurst(Alarm a, int start, int snooze) async {
    final target = min(50, a.target + (a.penalty ? 5 * snooze : 0));
    final ids = <int>[];
    for (var k = 0; k < burstCount; k++) {
      final id = nextId++;
      ids.add(id);
      await _zoned(id, start + k * burstGapMs, '${a.id}|$start',
          '${a.timeText} 起床！${exerciseName(a.exercise)} $target 下');
    }
    pending.add(Pending(alarmId: a.id, ringStart: start, snooze: snooze, target: target, ids: ids));
  }

  Future<void> _drop(Pending p) async {
    pending.remove(p);
    for (final id in p.ids) {
      await notifier.cancel(id);
    }
  }

  Future<void> _cancelFuture(int alarmId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final p in pending.where((e) => e.alarmId == alarmId && e.ringStart > now).toList()) {
      await _drop(p);
    }
  }

  Future<void> _zoned(int id, int atMs, String payload, String body) async {
    final when = tz.TZDateTime.fromMillisecondsSinceEpoch(tz.getLocation('UTC'), atMs);
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'wake_alarm',
        '鬧鐘',
        channelDescription: '醒動鬧鐘響鈴',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
      ),
    );
    try {
      await notifier.zonedSchedule(id, '起床！', body, when, details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          payload: payload);
    } catch (_) {
      // 沒有精準鬧鐘權限時，改用非精準排程
      await notifier.zonedSchedule(id, '起床！', body, when, details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          payload: payload);
    }
  }
}

// ───────── 動作判定（ML Kit 姿態辨識） ─────────
enum Phase { start, target, unknown }

double _angle(PoseLandmark a, PoseLandmark b, PoseLandmark c) {
  final v1x = a.x - b.x, v1y = a.y - b.y;
  final v2x = c.x - b.x, v2y = c.y - b.y;
  final denom = sqrt((v1x * v1x + v1y * v1y) * (v2x * v2x + v2y * v2y));
  if (denom == 0) return 180;
  final cosv = ((v1x * v2x + v1y * v2y) / denom).clamp(-1.0, 1.0);
  return acos(cosv) * 180 / pi;
}

// 回傳 start（起始姿勢）/ target（目標姿勢）/ unknown（中間狀態）；關鍵點看不到時回傳 null
Phase? classifyPose(String exercise, Map<PoseLandmarkType, PoseLandmark> lm) {
  PoseLandmark? g(PoseLandmarkType t) {
    final l = lm[t];
    return (l != null && l.likelihood >= 0.5) ? l : null;
  }

  if (exercise == 'squat') {
    final angles = <double>[];
    for (final side in [
      [PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle],
      [PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle],
    ]) {
      final a = g(side[0]), b = g(side[1]), c = g(side[2]);
      if (a != null && b != null && c != null) angles.add(_angle(a, b, c));
    }
    if (angles.isEmpty) return null;
    final avg = angles.reduce((x, y) => x + y) / angles.length;
    if (avg > 160) return Phase.start;
    if (avg < 100) return Phase.target;
    return Phase.unknown;
  }

  final nose = g(PoseLandmarkType.nose);
  final ls = g(PoseLandmarkType.leftShoulder);
  final rs = g(PoseLandmarkType.rightShoulder);
  final lw = g(PoseLandmarkType.leftWrist);
  final rw = g(PoseLandmarkType.rightWrist);
  if (nose == null || ls == null || rs == null || lw == null || rw == null) return null;
  final wristsDown = lw.y > ls.y && rw.y > rs.y; // 影像座標的 y 向下增加
  final wristsUp = lw.y < nose.y && rw.y < nose.y;

  if (exercise == 'raise') {
    if (wristsDown) return Phase.start;
    if (wristsUp) return Phase.target;
    return Phase.unknown;
  }

  // 開合跳：手放下且腳併攏 = 起始；手舉高且腳張開 = 目標
  final la = g(PoseLandmarkType.leftAnkle);
  final ra = g(PoseLandmarkType.rightAnkle);
  if (la == null || ra == null) return null;
  final shoulderW = (ls.x - rs.x).abs();
  final ankleW = (la.x - ra.x).abs();
  if (wristsDown && ankleW < 1.1 * shoulderW) return Phase.start;
  if (wristsUp && ankleW > 1.5 * shoulderW) return Phase.target;
  return Phase.unknown;
}

class RepCounter {
  RepCounter(this.exercise);
  final String exercise;
  int count = 0;
  Phase _confirmed = Phase.unknown;
  Phase _candidate = Phase.unknown;
  int _frames = 0;
  bool _sawTarget = false;

  // 連續 3 幀同一姿勢才算數（防抖動）；完整「起始 → 目標 → 起始」才計 1 下
  String? feed(Map<PoseLandmarkType, PoseLandmark> lm) {
    final seen = classifyPose(exercise, lm);
    if (seen == null) return '請讓身體完整入鏡';
    if (seen == _candidate) {
      _frames++;
    } else {
      _candidate = seen;
      _frames = 1;
    }
    if (_frames >= 3 && seen != Phase.unknown && seen != _confirmed) {
      _confirmed = seen;
      if (seen == Phase.target) _sawTarget = true;
      if (seen == Phase.start && _sawTarget) {
        count++;
        _sawTarget = false;
      }
    }
    return null;
  }
}

// ───────── 頁面：首頁 ─────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (initialRingKey != null) openRing(initialRingKey);
      initialRingKey = null;
      await askNotificationPermission();
      await store.rebuildSchedule();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final active = store.activeRing();
        return Scaffold(
          appBar: AppBar(
            title: const Text('醒動鬧鐘'),
            actions: [
              IconButton(
                icon: const Icon(Icons.bar_chart),
                onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => const StatsPage())),
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => const SettingsPage())),
              ),
            ],
          ),
          body: ListView(
            children: [
              if (active != null)
                Card(
                  color: Colors.red.shade100,
                  child: ListTile(
                    leading: const Icon(Icons.alarm_on),
                    title: const Text('正在響鈴！'),
                    subtitle: const Text('點這裡開始運動，3 分鐘內完成才算成功'),
                    onTap: () => openRing(active.key),
                  ),
                ),
              Card(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '連續 ${store.streak} 天｜積分 ${store.points}｜Lv.${levelOf(store.points)}',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
              for (final a in store.alarms)
                ListTile(
                  title: Text(a.timeText, style: const TextStyle(fontSize: 34)),
                  subtitle: Text('${dayText(a.days)}・${exerciseName(a.exercise)} ${a.target} 下'),
                  trailing: Switch(value: a.enabled, onChanged: (v) => store.setEnabled(a, v)),
                  onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => AlarmEditPage(alarm: a))),
                ),
              if (store.alarms.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('還沒有鬧鐘，點右下角 ＋ 新增')),
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => const AlarmEditPage())),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }
}

// ───────── 頁面：新增／編輯鬧鐘 ─────────
class AlarmEditPage extends StatefulWidget {
  const AlarmEditPage({super.key, this.alarm});
  final Alarm? alarm;

  @override
  State<AlarmEditPage> createState() => _AlarmEditPageState();
}

class _AlarmEditPageState extends State<AlarmEditPage> {
  late int _hour;
  late int _minute;
  late int _target;
  late String _exercise;
  late bool _penalty;
  late Set<int> _days;

  @override
  void initState() {
    super.initState();
    final a = widget.alarm;
    _hour = a?.hour ?? 7;
    _minute = a?.minute ?? 0;
    _target = a?.target ?? 20;
    _exercise = a?.exercise ?? 'jj';
    _penalty = a?.penalty ?? false;
    _days = a == null ? {1, 2, 3, 4, 5, 6, 7} : a.days.toSet();
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: _hour, minute: _minute));
    if (t != null) {
      setState(() {
        _hour = t.hour;
        _minute = t.minute;
      });
    }
  }

  Future<void> _save() async {
    if (_days.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請至少選一天')));
      return;
    }
    final days = _days.toList()..sort();
    await store.upsert(
      Alarm(
        id: widget.alarm?.id ?? store.newId(),
        hour: _hour,
        minute: _minute,
        days: days,
        exercise: _exercise,
        target: _target,
        penalty: _penalty,
        enabled: widget.alarm?.enabled ?? true,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('刪除這個鬧鐘？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('刪除')),
        ],
      ),
    );
    if (ok == true) {
      await store.remove(widget.alarm!.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.alarm == null ? '新增鬧鐘' : '編輯鬧鐘'),
        actions: [
          if (widget.alarm != null)
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
          TextButton(onPressed: _save, child: const Text('儲存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('響鈴時間'),
            trailing: Text(hm(_hour, _minute), style: const TextStyle(fontSize: 28)),
            onTap: _pickTime,
          ),
          const SizedBox(height: 8),
          const Text('重複日'),
          Wrap(
            spacing: 6,
            children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(dayNames[d - 1]),
                  selected: _days.contains(d),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _days.add(d);
                    } else {
                      _days.remove(d);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('甦醒動作'),
          DropdownButton<String>(
            value: _exercise,
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: 'jj', child: Text('開合跳')),
              DropdownMenuItem(value: 'raise', child: Text('舉手')),
              DropdownMenuItem(value: 'squat', child: Text('深蹲')),
            ],
            onChanged: (v) => setState(() => _exercise = v ?? _exercise),
          ),
          const SizedBox(height: 16),
          Text('目標次數：$_target 下'),
          Slider(
            min: 5,
            max: 50,
            divisions: 45,
            value: _target.toDouble(),
            label: '$_target',
            onChanged: (v) => setState(() => _target = v.round()),
          ),
          SwitchListTile(
            title: const Text('貪睡懲罰（每貪睡一次 +5 下）'),
            value: _penalty,
            onChanged: (v) => setState(() => _penalty = v),
          ),
        ],
      ),
    );
  }
}

// ───────── 頁面：響鈴／運動偵測 ─────────
class RingPage extends StatefulWidget {
  const RingPage({super.key, required this.pendingKey});
  final String pendingKey;

  @override
  State<RingPage> createState() => _RingPageState();
}

class _RingPageState extends State<RingPage> {
  CameraController? _cam;
  PoseDetector? _detector;
  RepCounter? _counter;
  Timer? _timer;
  bool _busy = false; // 上一幀還沒處理完，就丟掉新的幀
  bool _finished = false;
  bool _left = false;
  String _hint = '準備相機中…';
  int _remainMs = Store.windowMs;

  @override
  void initState() {
    super.initState();
    openRingKey = widget.pendingKey;
    final p = store.find(widget.pendingKey);
    if (p != null) {
      final a = store.alarmById(p.alarmId);
      if (a != null) _counter = RepCounter(a.exercise);
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
    _startCamera();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (openRingKey == widget.pendingKey) openRingKey = null;
    _stopCamera();
    super.dispose();
  }

  void _setHint(String s) {
    if (mounted) setState(() => _hint = s);
  }

  void _tick() {
    if (!mounted || _finished || _left) return;
    final p = store.find(widget.pendingKey);
    if (p == null) {
      _leave();
      return;
    }
    final remain = p.ringStart + Store.windowMs - DateTime.now().millisecondsSinceEpoch;
    if (remain <= 0) {
      _finish('failed', reps: _counter?.count ?? 0);
      return;
    }
    setState(() => _remainMs = remain);
  }

  Future<void> _startCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        _setHint('沒有相機權限，請到設定開啟。鬧鐘仍會響，時限內沒完成就記為失敗');
        return;
      }
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _setHint('找不到相機');
        return;
      }
      var cam = cams.first;
      for (final c in cams) {
        if (c.lensDirection == CameraLensDirection.front) {
          cam = c;
          break;
        }
      }
      final ctrl = CameraController(
        cam,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await ctrl.initialize();
      if (!mounted || _finished) {
        await ctrl.dispose();
        return;
      }
      _detector = PoseDetector(
        options: PoseDetectorOptions(mode: PoseDetectionMode.stream, model: PoseDetectionModel.base),
      );
      setState(() => _cam = ctrl);
      await ctrl.startImageStream(_onFrame);
      _setHint('請面向鏡頭，做出動作');
    } catch (e) {
      _setHint('相機啟動失敗：$e');
    }
  }

  void _onFrame(CameraImage image) {
    if (_busy || _finished || _cam == null || _detector == null || _counter == null) return;
    _busy = true;
    _process(image).whenComplete(() {
      _busy = false;
    });
  }

  Future<void> _process(CameraImage image) async {
    try {
      final cam = _cam!;
      final rotation = InputImageRotationValue.fromRawValue(cam.description.sensorOrientation);
      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (rotation == null || format == null || image.planes.isEmpty) return;
      final buffer = BytesBuilder(copy: false);
      for (final plane in image.planes) {
        buffer.add(plane.bytes);
      }
      final input = InputImage.fromBytes(
        bytes: buffer.takeBytes(),
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );
      final poses = await _detector!.processImage(input);
      if (!mounted || _finished) return;
      final counter = _counter!;
      final hint = poses.isEmpty ? '請讓全身入鏡' : counter.feed(poses.first.landmarks);
      setState(() => _hint = hint ?? '很好，繼續！');
      final target = store.find(widget.pendingKey)?.target ?? 0;
      if (target > 0 && counter.count >= target) {
        await _finish('success', reps: counter.count);
      }
    } catch (_) {
      // 單一幀出錯就略過，不影響下一幀
    }
  }

  Future<void> _finish(String result, {int reps = 0}) async {
    if (_finished) return;
    _finished = true;
    if (store.find(widget.pendingKey) == null) {
      _leave();
      return;
    }
    await store.resolve(widget.pendingKey, result, reps: reps);
    final msg = switch (result) {
      'success' => '完成！成功起床 🎉',
      'failed' => '時限已過，這次記為失敗',
      _ => '已一般關閉（未完成）',
    };
    messengerKey.currentState?.showSnackBar(SnackBar(content: Text(msg)));
    _leave();
  }

  Future<void> _snooze() async {
    if (_finished) return;
    _finished = true;
    await store.snooze(widget.pendingKey);
    _leave();
  }

  Future<void> _normalClose() => _finish('normalClose');

  void _leave() {
    if (_left || !mounted) return;
    _left = true;
    _timer?.cancel();
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  Future<void> _stopCamera() async {
    final c = _cam;
    _cam = null;
    try {
      if (c != null) {
        if (c.value.isStreamingImages) await c.stopImageStream();
        await c.dispose();
      }
    } catch (_) {}
    await _detector?.close();
    _detector = null;
  }

  @override
  Widget build(BuildContext context) {
    final p = store.find(widget.pendingKey);
    final target = p?.target ?? 0;
    final count = _counter?.count ?? 0;
    final secs = max(0, _remainMs) ~/ 1000;
    final timeText = '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    final cam = _cam;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: cam != null && cam.value.isInitialized
                  ? Center(
                      child: AspectRatio(
                        aspectRatio: 1 / cam.value.aspectRatio,
                        child: CameraPreview(cam),
                      ),
                    )
                  : Center(child: Text(_hint, style: const TextStyle(color: Colors.white))),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$count / $target 下',
                    style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: target == 0 ? 0.0 : min(1.0, count / target)),
                  const SizedBox(height: 8),
                  Text('剩餘 $timeText｜$_hint', style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if ((p?.snooze ?? 2) < 2)
                        OutlinedButton(onPressed: _snooze, child: const Text('貪睡 5 分鐘')),
                      if (store.normalClose)
                        TextButton(
                          onPressed: _normalClose,
                          child: const Text('一般關閉', style: TextStyle(color: Colors.white70)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────── 頁面：統計 ─────────
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final success = store.logs.where((l) => l.result == 'success').length;
        return Scaffold(
          appBar: AppBar(title: const Text('統計與紀錄')),
          body: ListView(
            children: [
              ListTile(title: const Text('目前連續天數'), trailing: Text('${store.streak} 天')),
              ListTile(
                title: const Text('積分／等級'),
                trailing: Text('${store.points} 分｜Lv.${levelOf(store.points)}'),
              ),
              ListTile(title: const Text('成功次數'), trailing: Text('$success 次')),
              const Divider(),
              for (final l in store.logs.take(100))
                ListTile(
                  title: Text('${l.day}　${resultText(l.result)}'),
                  subtitle: Text('完成 ${l.reps} / ${l.target} 下${l.snooze > 0 ? '・貪睡 ${l.snooze} 次' : ''}'),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ───────── 頁面：設定 ─────────
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) => Scaffold(
        appBar: AppBar(title: const Text('設定')),
        body: ListView(
          children: [
            SwitchListTile(
              title: const Text('允許「一般關閉」'),
              subtitle: const Text('不運動直接關閉，這次記為未完成（預設關閉）'),
              value: store.normalClose,
              onChanged: (v) {
                store.normalClose = v;
                store.save();
              },
            ),
            ListTile(
              title: const Text('授權通知'),
              subtitle: const Text('Android 13 以上需要'),
              onTap: askNotificationPermission,
            ),
            ListTile(
              title: const Text('授權精準鬧鐘'),
              subtitle: const Text('Android 12 以上需要，會開啟系統設定頁'),
              onTap: askExactAlarmPermission,
            ),
            ListTile(
              title: const Text('重建鬧鐘排程'),
              subtitle: const Text('授權精準鬧鐘後，點這裡讓鬧鐘重新排程'),
              onTap: () => store.rebuildSchedule(),
            ),
            ListTile(
              title: const Text('授權相機'),
              onTap: () => Permission.camera.request(),
            ),
          ],
        ),
      ),
    );
  }
}
