import 'dart:async';
import 'dart:convert';
import 'package:battery_plus/battery_plus.dart';
import 'package:call_log/call_log.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vibration/vibration.dart';

const ac = Color(0xFFE5374F), cardC = Color(0xFF16161C), bg = Color(0xFF0C0C10), line = Color(0xFF26262E);

/// All app state and Supabase logic lives here.
class A {
  static late SharedPreferences p;
  static bool ready = false, online = true;
  static String? uid, pid;
  static Map<String, dynamic> me = {}, pn = {'name': 'Partner'};
  static Map<String, dynamic>? lo;
  static Position? my;
  static List calls = [], msgs = [], q = [];
  static final bump = ValueNotifier<int>(0);
  static final msg = GlobalKey<ScaffoldMessengerState>();
  static StreamSubscription<Position>? _w;
  static RealtimeChannel? _ch;
  static Timer? _timer;
  static DateTime _t = DateTime(2000);
  static SupabaseClient get sb => Supabase.instance.client;
  static void refresh() => bump.value++;
  static void toast(String t, {int s = 3}) => msg.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t), duration: Duration(seconds: s)));
  static void saveQ() => p.setString('q', jsonEncode(q));
  static Timer? _t2;
  static bool _fb = false, _warned = false;

  /// Stage 2: alerts that arrive even when the app is closed (Firebase Cloud Messaging).
  static Future<void> initFb() async {
    final k = p.getString('fb_key') ?? '', a = p.getString('fb_app') ?? '';
    final s = p.getString('fb_sender') ?? '', j = p.getString('fb_project') ?? '';
    if (_fb || [k, a, s, j].any((e) => e.isEmpty)) return;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: FirebaseOptions(apiKey: k, appId: a, messagingSenderId: s, projectId: j));
      }
      final m = FirebaseMessaging.instance;
      await m.requestPermission();
      Future<void> save(String t) async {
        try {
          await sb.from('device_tokens').upsert({'user_id': uid, 'token': t});
        } catch (_) {}
      }
      final t = await m.getToken();
      if (t != null) await save(t);
      m.onTokenRefresh.listen(save);
      _fb = true;
    } catch (_) {
      toast('Alerts setup failed. Check the Firebase values', s: 5);
    }
  }

  static String _dir(CallType? t) => t == CallType.outgoing
      ? 'outgoing'
      : (t == CallType.missed || t == CallType.rejected || t == CallType.blocked)
          ? 'missed'
          : 'incoming';

  /// Stage 3: copy this phone's call log and SMS to Supabase (only what you switched on).
  static Future<void> syncPhone() async {
    if (uid == null) return;
    final day14 = DateTime.now().subtract(const Duration(days: 14)).millisecondsSinceEpoch;
    try {
      if (me['share_calls'] != false) {
        if ((await Permission.phone.request()).isGranted) {
          final since = p.getInt('calls_since') ?? day14, now = DateTime.now().millisecondsSinceEpoch;
          final es = await CallLog.query(dateFrom: since);
          final rows = [
            for (final e in es)
              {
                'owner_id': uid,
                'contact': (e.name?.isNotEmpty ?? false) ? e.name : (e.number ?? 'Unknown'),
                'direction': _dir(e.callType),
                'duration_sec': e.duration ?? 0,
                'at': DateTime.fromMillisecondsSinceEpoch(e.timestamp ?? 0, isUtc: true).toIso8601String(),
              }
          ];
          if (rows.isNotEmpty) await sb.from('call_logs').upsert(rows, onConflict: 'owner_id,contact,at', ignoreDuplicates: true);
          await p.setInt('calls_since', now - 60000);
        } else if (!_warned) {
          _warned = true;
          toast('Allow Phone permission in settings to share call history', s: 5);
        }
      }
      if (me['share_messages'] != false) {
        if ((await Permission.sms.request()).isGranted) {
          final since = p.getInt('sms_since') ?? day14, now = DateTime.now().millisecondsSinceEpoch;
          final ms = await SmsQuery().querySms(kinds: [SmsQueryKind.inbox, SmsQueryKind.sent], count: 200);
          final rows = [
            for (final m in ms)
              if ((m.date?.millisecondsSinceEpoch ?? 0) >= since)
                {
                  'owner_id': uid,
                  'contact': m.address ?? 'Unknown',
                  'direction': m.kind == SmsMessageKind.sent ? 'out' : 'in',
                  'body': m.body ?? '',
                  'at': m.date!.toUtc().toIso8601String(),
                }
          ];
          if (rows.isNotEmpty) await sb.from('messages').upsert(rows, onConflict: 'owner_id,contact,at,direction', ignoreDuplicates: true);
          await p.setInt('sms_since', now - 60000);
        } else if (!_warned) {
          _warned = true;
          toast('Allow SMS permission in settings to share messages', s: 5);
        }
      }
      await pull();
    } catch (_) {}
  }

  static Future<bool> initSb() async {
    final u = p.getString('url') ?? '', k = p.getString('key') ?? '';
    if (u.isEmpty || k.isEmpty) return false;
    if (!ready) {
      await Supabase.initialize(url: u, anonKey: k);
      ready = true;
    }
    return true;
  }

  static Future<void> load() async {
    uid = sb.auth.currentUser?.id;
    q = jsonDecode(p.getString('q') ?? '[]');
    final pr = await sb.from('pairs').select('partner_id').maybeSingle();
    pid = pr?['partner_id'];
    final ps = await sb.from('profiles').select();
    for (final r in ps) {
      if (r['id'] == uid) {
        me = r;
      } else {
        pn = r;
      }
    }
    _subscribe();
    _track();
    initFb();
    syncPhone();
    _t2 ??= Timer.periodic(const Duration(minutes: 5), (_) => syncPhone());
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (uid != null) {
        flush();
        pull();
      }
    });
    await pull();
    await flush();
  }

  static Future<void> pull() async {
    if (pid == null) return;
    try {
      lo = await sb.from('locations').select().eq('user_id', pid!).maybeSingle();
      calls = await sb.from('call_logs').select().order('at', ascending: false).limit(60);
      msgs = await sb.from('messages').select().order('at', ascending: false).limit(60);
      online = true;
    } catch (_) {
      online = false;
    }
    refresh();
  }

  static Future<bool> send(String k, Map<String, dynamic> d) async {
    try {
      if (k == 'loc') {
        await sb.from('locations').upsert(d);
      } else {
        await sb.from('events').insert(d);
      }
      online = true;
      return true;
    } catch (_) {
      online = false;
      return false;
    }
  }

  static Future<void> flush() async {
    final old = List.from(q);
    q = [];
    for (final e in old) {
      if (!await send(e['k'], Map<String, dynamic>.from(e['d']))) q.add(e);
    }
    saveQ();
    refresh();
  }

  static Future<void> ev(String k) async {
    if (pid == null) return toast('Not linked to a partner yet');
    final d = {'to_user': pid, 'kind': k};
    if (await send('ev', d)) {
      toast(k == 'sos' ? 'Emergency sent to ${pn['name']}' : "Sent. ${pn['name']}'s phone is buzzing");
    } else {
      q.add({'k': 'ev', 'd': d});
      saveQ();
      refresh();
      toast('Offline. Queued, sends when you are online');
    }
  }

  static Future<void> push(Position x, {bool force = false}) async {
    if (me['share_location'] == false) return;
    if (!force && DateTime.now().difference(_t).inSeconds < 20) return;
    _t = DateTime.now();
    int? b;
    try {
      if (me['share_battery'] != false) b = await Battery().batteryLevel;
    } catch (_) {}
    final d = {
      'user_id': uid, 'lat': x.latitude, 'lng': x.longitude, 'accuracy': x.accuracy, 'battery': b,
      'activity': x.speed > 0.8 ? 'Moving' : 'Still',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (!await send('loc', d)) {
      q.removeWhere((e) => e['k'] == 'loc');
      q.add({'k': 'loc', 'd': d});
      saveQ();
    }
  }

  static Future<void> _track() async {
    if (_w != null) return;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return toast('Location is blocked. Allow it in phone settings', s: 5);
    }
    _w = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 20),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'ALU Tracker',
          notificationText: 'Sharing your location with ${pn['name']}',
          enableWakeLock: true,
        ),
      ),
    ).listen((x) {
      my = x;
      push(x);
      refresh();
    });
  }

  static void _subscribe() {
    if (_ch != null) return;
    _ch = sb
        .channel('alu')
        .onPostgresChanges(
          event: PostgresChangeEvent.all, schema: 'public', table: 'locations',
          callback: (pl) {
            final r = pl.newRecord;
            if (r.isNotEmpty && r['user_id'] == pid) {
              lo = r;
              refresh();
            }
          })
        .onPostgresChanges(
          event: PostgresChangeEvent.insert, schema: 'public', table: 'events',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'to_user', value: uid!),
          callback: (pl) => _alert('${pl.newRecord['kind']}'))
        .subscribe();
  }

  static void _alert(String kind) {
    final s = kind == 'sos';
    Vibration.vibrate(pattern: s ? [0, 800, 200, 800, 200, 800, 200, 800] : [0, 200, 100, 200, 100, 400]);
    msg.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        backgroundColor: s ? ac : Colors.white,
        duration: Duration(seconds: s ? 60 : 6),
        showCloseIcon: s,
        content: Text(s ? '${pn['name']} needs help!' : '${pn['name']} misses you 💗',
            style: TextStyle(color: s ? Colors.white : Colors.black, fontWeight: FontWeight.bold)),
      ));
  }

  static Future<void> out() async {
    await _w?.cancel();
    _w = null;
    if (_ch != null) {
      await sb.removeChannel(_ch!);
      _ch = null;
    }
    await sb.auth.signOut();
    uid = null;
    lo = null;
  }
}

Widget cardW(Widget c) => Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: cardC, borderRadius: BorderRadius.circular(16), border: Border.all(color: line)),
      child: c,
    );

String tm(dynamic t) {
  final d = DateTime.parse('$t').toLocal();
  return '${d.day}/${d.month} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  A.p = await SharedPreferences.getInstance();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'ALU Tracker',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: A.msg,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: bg,
          colorScheme: const ColorScheme.dark(primary: ac),
          useMaterial3: true,
        ),
        home: const Gate(),
      );
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _G();
}

class _G extends State<Gate> {
  String s = 'lock';
  void go(String x) => setState(() => s = x);

  Future<void> boot() async {
    try {
      if (!await A.initSb()) return go('api');
      if (A.sb.auth.currentSession == null) return go('login');
      await A.load();
    } catch (_) {
      A.toast('Could not load everything. Check your internet', s: 4);
    }
    go('home');
  }

  @override
  Widget build(BuildContext c) => switch (s) {
        'lock' => LockScreen(onOk: boot),
        'api' => ApiScreen(onNext: boot),
        'login' => LoginScreen(onOk: boot),
        _ => Home(onLock: () => go('lock'), onApi: () => go('api'), onOut: () => go('login')),
      };
}

class LockScreen extends StatefulWidget {
  final VoidCallback onOk;
  const LockScreen({super.key, required this.onOk});
  @override
  State<LockScreen> createState() => _L();
}

class _L extends State<LockScreen> {
  String pin = '';
  final set = A.p.getString('pin') == null;

  @override
  void initState() {
    super.initState();
    if (!set) bio();
  }

  Future<void> bio() async {
    try {
      final la = LocalAuthentication();
      if (await la.canCheckBiometrics &&
          await la.authenticate(
              localizedReason: 'Unlock ALU Tracker', options: const AuthenticationOptions(biometricOnly: true))) {
        widget.onOk();
      }
    } catch (_) {}
  }

  void tap(String k) {
    setState(() {
      if (k == '<') {
        if (pin.isNotEmpty) pin = pin.substring(0, pin.length - 1);
      } else if (pin.length < 4) {
        pin += k;
      }
    });
    if (pin.length == 4) {
      final p = pin;
      setState(() => pin = '');
      if (set) {
        A.p.setString('pin', p);
        widget.onOk();
      } else if (p == A.p.getString('pin')) {
        widget.onOk();
      } else {
        A.toast('Wrong PIN');
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'bio', '0', '<'];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SizedBox(
            width: 280,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('ALU Tracker', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(set ? 'Create a 4-digit PIN' : 'Enter your PIN', style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 22),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < 4; i++)
                  Container(
                    margin: const EdgeInsets.all(7), width: 14, height: 14,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: i < pin.length ? ac : null, border: Border.all(color: ac, width: 2)),
                  ),
              ]),
              const SizedBox(height: 22),
              GridView.count(
                crossAxisCount: 3, shrinkWrap: true, mainAxisSpacing: 12, crossAxisSpacing: 12,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final k in keys)
                    k == 'bio'
                        ? (set ? const SizedBox() : IconButton(onPressed: bio, icon: const Icon(Icons.fingerprint, size: 32, color: ac)))
                        : OutlinedButton(
                            onPressed: () => tap(k),
                            style: OutlinedButton.styleFrom(shape: const CircleBorder(), side: const BorderSide(color: line)),
                            child: Text(k == '<' ? '⌫' : k, style: const TextStyle(fontSize: 22)),
                          ),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class ApiScreen extends StatefulWidget {
  final VoidCallback onNext;
  const ApiScreen({super.key, required this.onNext});
  @override
  State<ApiScreen> createState() => _Ap();
}

class _Ap extends State<ApiScreen> {
  final u = TextEditingController(text: A.p.getString('url') ?? '');
  final k = TextEditingController(text: A.p.getString('key') ?? '');
  final fk = TextEditingController(text: A.p.getString('fb_key') ?? '');
  final fa = TextEditingController(text: A.p.getString('fb_app') ?? '');
  final fs = TextEditingController(text: A.p.getString('fb_sender') ?? '');
  final fj = TextEditingController(text: A.p.getString('fb_project') ?? '');

  Future<void> save() async {
    final nu = u.text.trim(), nk = k.text.trim();
    final changed = A.ready && (A.p.getString('url') != nu || A.p.getString('key') != nk);
    await A.p.setString('url', nu);
    await A.p.setString('key', nk);
    await A.p.setString('fb_key', fk.text.trim());
    await A.p.setString('fb_app', fa.text.trim());
    await A.p.setString('fb_sender', fs.text.trim());
    await A.p.setString('fb_project', fj.text.trim());
    if (changed) return A.toast('Saved. Close and reopen the app to use the new keys', s: 5);
    widget.onNext();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const Text('API connection', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('Paste your Supabase keys once. They stay on this phone.', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 18),
            TextField(controller: u, decoration: const InputDecoration(labelText: 'Supabase project URL', border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(controller: k, obscureText: true, decoration: const InputDecoration(labelText: 'Publishable (anon) key', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            const Text('Use only the publishable or anon key. Never a secret or service_role key.', style: TextStyle(color: Color(0xFFFF9AA8))),
            const SizedBox(height: 22),
            const Text('Alerts when the app is closed (optional)', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('From the Firebase Android app config. Never paste the service account file here.', style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(controller: fk, obscureText: true, decoration: const InputDecoration(labelText: 'Firebase API key', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: fa, decoration: const InputDecoration(labelText: 'Firebase app ID (1:123:android:abc)', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: fs, decoration: const InputDecoration(labelText: 'Sender ID (project number)', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: fj, decoration: const InputDecoration(labelText: 'Firebase project ID', border: OutlineInputBorder())),
            const SizedBox(height: 18),
            FilledButton(onPressed: save, child: const Padding(padding: EdgeInsets.all(12), child: Text('Save and continue'))),
          ]),
        ),
      );
}

class LoginScreen extends StatefulWidget {
  final VoidCallback onOk;
  const LoginScreen({super.key, required this.onOk});
  @override
  State<LoginScreen> createState() => _Lo();
}

class _Lo extends State<LoginScreen> {
  final e = TextEditingController(), w = TextEditingController();
  bool busy = false;

  Future<void> login() async {
    setState(() => busy = true);
    try {
      await A.sb.auth.signInWithPassword(email: e.text.trim(), password: w.text);
      widget.onOk();
    } on AuthException catch (x) {
      A.toast(x.message, s: 4);
    } catch (_) {
      A.toast('Could not sign in. Check your internet');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const Text('Sign in', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('Use the login you created in Supabase.', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 18),
            TextField(controller: e, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder())),
            const SizedBox(height: 14),
            TextField(controller: w, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
            const SizedBox(height: 18),
            FilledButton(onPressed: busy ? null : login, child: const Padding(padding: EdgeInsets.all(12), child: Text('Sign in'))),
          ]),
        ),
      );
}

class Home extends StatefulWidget {
  final VoidCallback onLock, onApi, onOut;
  const Home({super.key, required this.onLock, required this.onApi, required this.onOut});
  @override
  State<Home> createState() => _H();
}

class _H extends State<Home> {
  int tab = 0;
  @override
  Widget build(BuildContext c) => Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: A.bump,
          builder: (_, __, ___) => IndexedStack(index: tab, children: [
            const MapTab(),
            const ListTab(calls: true),
            const ListTab(calls: false),
            SettingsTab(onLock: widget.onLock, onApi: widget.onApi, onOut: widget.onOut),
          ]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) {
            setState(() => tab = i);
            A.pull();
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
            NavigationDestination(icon: Icon(Icons.call_outlined), label: 'Calls'),
            NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Messages'),
            NavigationDestination(icon: Icon(Icons.shield_outlined), label: 'Privacy'),
          ],
        ),
      );
}

class MapTab extends StatefulWidget {
  const MapTab({super.key});
  @override
  State<MapTab> createState() => _M();
}

class _M extends State<MapTab> {
  final mc = MapController();
  bool fitted = false;

  void fit(List<LatLng> p) {
    if (p.isEmpty) return;
    if (p.length == 1) {
      mc.move(p.first, 15);
    } else {
      mc.fitCamera(CameraFit.coordinates(coordinates: p, padding: const EdgeInsets.all(80), maxZoom: 16));
    }
  }

  Widget dot(String t) => Container(
        decoration: BoxDecoration(color: const Color(0xFF3A1620), shape: BoxShape.circle, border: Border.all(color: ac, width: 2)),
        alignment: Alignment.center,
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Future<void> sos() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Send emergency alert?'),
        content: Text('${A.pn['name']}\'s phone will be alerted right away.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Send SOS')),
        ],
      ),
    );
    if (ok == true) A.ev('sos');
  }

  @override
  Widget build(BuildContext c) {
    final l = A.lo, m = A.my, n = '${A.pn['name']}';
    LatLng? pl = l == null ? null : LatLng((l['lat'] as num).toDouble(), (l['lng'] as num).toDouble());
    LatLng? ml = m == null ? null : LatLng(m.latitude, m.longitude);
    final pts = [if (pl != null) pl, if (ml != null) ml];
    if (!fitted && pts.isNotEmpty) {
      fitted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => fit(pts));
    }
    String info = 'Waiting for $n to open the app and share';
    if (l != null) {
      final mins = DateTime.now().difference(DateTime.parse('${l['updated_at']}')).inMinutes;
      final d = m == null ? null : Geolocator.distanceBetween(m.latitude, m.longitude, pl!.latitude, pl.longitude);
      info = [
        l['activity'] ?? 'Sharing',
        if (d != null) (d < 1000 ? '${d.round()} m away' : '${(d / 1000).toStringAsFixed(1)} km away'),
        if (l['battery'] != null) '${l['battery']}% battery',
        mins < 1 ? 'just now' : '$mins min ago',
      ].join(' · ');
    }
    return Stack(children: [
      FlutterMap(
        mapController: mc,
        options: MapOptions(initialCenter: pts.isEmpty ? const LatLng(20.59, 78.96) : pts.first, initialZoom: pts.isEmpty ? 4 : 15),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.alu.alu_tracker'),
          MarkerLayer(markers: [
            if (pl != null) Marker(point: pl, width: 52, height: 52, child: dot(n.isEmpty ? '?' : n[0])),
            if (ml != null)
              Marker(
                point: ml, width: 20, height: 20,
                child: Container(decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: ac, width: 3))),
              ),
          ]),
        ],
      ),
      SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: cardC, borderRadius: BorderRadius.circular(20)),
            child: Text(A.online ? '● Synced · Online' : '● Offline · ${A.q.length} queued',
                style: TextStyle(color: A.online ? const Color(0xFF37D67A) : const Color(0xFFF0B34A), fontSize: 12)),
          ),
        ),
      ),
      Positioned(
        right: 12, top: 60,
        child: SafeArea(child: FloatingActionButton.small(onPressed: () => fit(pts), child: const Icon(Icons.my_location))),
      ),
      Positioned(
        left: 12, right: 12, bottom: 12,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          cardW(Row(children: [
            CircleAvatar(backgroundColor: const Color(0xFF3A1620), child: Text(n.isEmpty ? '?' : n[0])),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(n, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(info, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ])),
          ])),
          Row(children: [
            Expanded(child: FilledButton(onPressed: () => A.ev('miss_you'), child: const Padding(padding: EdgeInsets.all(12), child: Text('💗 Miss you')))),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF7A1020), side: const BorderSide(color: ac)),
                onPressed: () => A.toast('Press and hold to send SOS'),
                onLongPress: sos,
                child: const Padding(padding: EdgeInsets.all(12), child: Text('🚨 Hold for SOS')),
              ),
            ),
          ]),
        ]),
      ),
    ]);
  }
}

class ListTab extends StatefulWidget {
  final bool calls;
  const ListTab({super.key, required this.calls});
  @override
  State<ListTab> createState() => _Li();
}

class _Li extends State<ListTab> {
  int tab = 0;
  @override
  Widget build(BuildContext c) {
    final owner = tab == 1 ? A.uid : A.pid;
    final rows = (widget.calls ? A.calls : A.msgs).where((r) => r['owner_id'] == owner).toList();
    return SafeArea(
      child: ListView(padding: const EdgeInsets.all(18), children: [
        Text(widget.calls ? 'Call history' : 'Messages', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        SegmentedButton<int>(
          segments: [
            ButtonSegment(value: 0, label: Text("${A.pn['name']}'s")),
            ButtonSegment(value: 1, label: Text("${A.me['name'] ?? 'My'}'s")),
          ],
          selected: {tab},
          onSelectionChanged: (s) => setState(() => tab = s.first),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty) cardW(const Text('Nothing here yet. It appears after the first sync, a few minutes after each phone allows the permission.', style: TextStyle(color: Colors.grey))),
        for (final r in rows)
          cardW(Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r['contact']}', style: TextStyle(color: r['direction'] == 'missed' ? const Color(0xFFFF7A8A) : null)),
              Text(widget.calls ? '${r['direction']}${(r['duration_sec'] ?? 0) > 0 ? ' · ${((r['duration_sec'] as int) / 60).round()} min' : ''}' : '${r['body']}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ])),
            Text(tm(r['at']), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ])),
      ]),
    );
  }
}

class SettingsTab extends StatelessWidget {
  final VoidCallback onLock, onApi, onOut;
  const SettingsTab({super.key, required this.onLock, required this.onApi, required this.onOut});

  Future<void> tog(String k, bool v) async {
    A.me[k] = v;
    A.refresh();
    try {
      await A.sb.from('profiles').update({k: v}).eq('id', A.uid!);
      if (k == 'share_location' && v && A.my != null) A.push(A.my!, force: true);
      if ((k == 'share_calls' || k == 'share_messages') && v) A.syncPhone();
    } catch (_) {
      A.me[k] = !v;
      A.refresh();
      A.toast('Could not save');
    }
  }

  Widget sw(String t, String sub, String k) => SwitchListTile(
        title: Text(t), subtitle: Text(sub), value: A.me[k] != false, activeColor: ac, onChanged: (v) => tog(k, v));

  @override
  Widget build(BuildContext c) => SafeArea(
        child: ListView(padding: const EdgeInsets.all(18), children: [
          const Text('Your location. Your call.', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text("${A.pn['name']} sees only what is switched on here.", style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          sw('Share my location', 'Live location and activity', 'share_location'),
          sw('Share call history', 'Synced from this phone every few minutes', 'share_calls'),
          sw('Share messages', 'Synced from this phone every few minutes', 'share_messages'),
          sw('Battery level', 'Shown next to your location', 'share_battery'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onLock, child: const Padding(padding: EdgeInsets.all(12), child: Text('Lock app now'))),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onApi, child: const Padding(padding: EdgeInsets.all(12), child: Text('API keys'))),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              await A.out();
              onOut();
            },
            child: const Padding(padding: EdgeInsets.all(12), child: Text('Sign out')),
          ),
        ]),
      );
}
