import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../api.dart';
import '../config.dart';
import '../push/push.dart';
import '../sound.dart';
import '../widgets/playing_card.dart';

enum AuthStatus { loading, loggedOut, loggedIn }

/// Glavno stanje aplikacije: prijava, balans, lobi i stolovi uživo (Socket.IO).
class AppState extends ChangeNotifier {
  final api = Api();
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();

  AuthStatus status = AuthStatus.loading;
  Map<String, dynamic>? user;
  int balance = 0;

  io.Socket? _socket;
  bool connected = false;

  /// Stolovi u lobiju (ažurira server).
  List<Map<String, dynamic>> lobby = [];
  bool _inLobby = false;

  /// Stanje stolova koje korisnik gleda (iz njegovog ugla).
  final Map<String, ValueNotifier<Map<String, dynamic>?>> tables = {};
  final Set<String> _watching = {};

  /// Chat svakog stola (poslednje poruke) i broj nepročitanih.
  final Map<String, ValueNotifier<List<Map<String, dynamic>>>> chats = {};
  final Map<String, ValueNotifier<int>> unread = {};
  String? openChat;

  ValueNotifier<List<Map<String, dynamic>>> chatOf(String id) => chats.putIfAbsent(id, () => ValueNotifier([]));
  ValueNotifier<int> unreadOf(String id) => unread.putIfAbsent(id, () => ValueNotifier(0));

  Future<bool> sendChat(String tableId, String text) => run('table:chat', {'tableId': tableId, 'text': text});

  /// Razlika serverskog i lokalnog sata (ms), da tajmer ne zavisi od sata telefona.
  int clockOffset = 0;

  /// Prikaz iznosa za stolom u velikim blajndovima umesto u žetonima.
  bool showBB = false;

  /// Karte u boji (cela karta obojena po znaku, kao na ClubGG) umesto klasičnih belih.
  bool fourColor = false;

  /// Svoje karte su sakrivene dok ih igrač ne dodirne.
  bool hideCards = false;

  /// Kad igrač ostane bez novca na stolu, sam se dopuni do najvećeg ulaza.
  bool autoRebuy = false;

  /// Zvukovi za stolom.
  bool soundOn = true;

  Future<void> setSound(bool v) async {
    soundOn = v;
    Sounds.enabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sound', v);
  }

  Future<void> setSetting(String key, bool v) async {
    switch (key) {
      case 'fourColor':
        fourColor = v;
        CardStyle.fourColor = v;
      case 'hideCards':
        hideCards = v;
      case 'autoRebuy':
        autoRebuy = v;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, v);
  }

  Future<void> setShowBB(bool v) async {
    showBB = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showBB', v);
  }

  AppState() {
    // Prisutnost: kad igrač ode u drugu aplikaciju, server mu šalje obaveštenje kad je na potezu.
    _lifecycle = AppLifecycleListener(onStateChange: (state) => _sendPresence(state == AppLifecycleState.resumed));
    api.onUnauthorized = (msg) {
      if (status == AuthStatus.loggedIn) {
        logout();
        toast(msg);
      }
    };
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    showBB = prefs.getBool('showBB') ?? false;
    fourColor = prefs.getBool('fourColor') ?? false;
    CardStyle.fourColor = fourColor;
    soundOn = prefs.getBool('sound') ?? true;
    Sounds.enabled = soundOn;
    final token = prefs.getString('token');
    if (token == null) {
      status = AuthStatus.loggedOut;
      notifyListeners();
      return;
    }
    api.token = token;
    try {
      _onUser(await api.get('/me'));
    } on ApiException catch (e) {
      if (e.status == 0) {
        // Bez interneta: ostajemo prijavljeni, veza će se uspostaviti kad internet proradi.
        status = AuthStatus.loggedIn;
        user = {'displayName': '', 'username': ''};
        notifyListeners();
        _connect();
      } else {
        await logout();
      }
    }
  }

  void toast(String msg) {
    messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- Prisutnost i obaveštenja na telefonu ----------

  // ignore: unused_field
  late final AppLifecycleListener _lifecycle;
  bool _visible = true;

  void _sendPresence(bool visible) {
    _visible = visible;
    _socket?.emit('presence', {'visible': visible});
  }

  /// "unsupported", "ios-install" (iPhone: dodati na početni ekran), "default", "granted", "denied"
  String get pushStatus => WebPush.status();

  /// Uključuje obaveštenja na ovom uređaju (traži dozvolu). Vraća true ako je uspelo.
  Future<bool> enablePush() async {
    try {
      final key = (await api.get('/push/key'))['key'] as String? ?? '';
      if (key.isEmpty) return false;
      final sub = await WebPush.subscribe(key);
      if (sub.isEmpty) return false;
      await api.post('/push/subscribe', jsonDecode(sub) as Map<String, dynamic>);
      pushOn = true;
      return true;
    } catch (_) {
      return false;
    } finally {
      notifyListeners();
    }
  }

  /// Obaveštenja su uključena na ovom uređaju (postoji pretplata).
  bool pushOn = false;

  /// Posle prijave: ako su obaveštenja uključena na ovom uređaju, osveži pretplatu na serveru
  /// (ako ih je igrač isključio, ne uključuju se ponovo sama).
  Future<void> _refreshPush() async {
    final sub = await WebPush.current();
    pushOn = sub.isNotEmpty;
    notifyListeners();
    if (!pushOn) return;
    try {
      await api.post('/push/subscribe', jsonDecode(sub) as Map<String, dynamic>);
    } catch (_) {}
  }

  /// Isključuje obaveštenja na ovom uređaju (i briše pretplatu na serveru).
  Future<void> disablePush() async {
    final endpoint = await WebPush.unsubscribe();
    pushOn = false;
    notifyListeners();
    if (endpoint.isNotEmpty) {
      try {
        await api.post('/push/unsubscribe', {'endpoint': endpoint});
      } catch (_) {}
    }
  }

  /// Otvara sto (postavlja glavni okvir aplikacije posle prijave).
  void Function(String tableId)? openTable;

  /// Važno obaveštenje sa dugmetom (npr. "Sto se otvorio" → IGRAJ).
  void notify(String msg, {String? action, String? tableId, Duration duration = const Duration(seconds: 10)}) {
    Sounds.play('turn', volume: 0.5);
    messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w700)),
        duration: duration,
        action: action == null || tableId == null
            ? null
            : SnackBarAction(label: action, onPressed: () => openTable?.call(tableId)),
      ));
  }

  /// Beleške o drugim igračima (id igrača → tekst); vidi ih samo ovaj igrač.
  Map<String, String> notes = {};

  Future<void> loadNotes() async {
    try {
      final res = await api.get('/me/notes');
      notes = (res as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> saveNote(String targetId, String text) async {
    await api.post('/me/notes/$targetId', {'text': text});
    if (text.trim().isEmpty) {
      notes.remove(targetId);
    } else {
      notes[targetId] = text.trim();
    }
    notifyListeners();
  }

  Future<void> login(String username, String password) async {
    final res = await api.post('/auth/login', {'username': username, 'password': password});
    if (res['user']['role'] != 'PLAYER') {
      throw ApiException('Ovo je nalog agenta. Agenti rade u admin panelu.', 403);
    }
    api.token = res['accessToken'];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', api.token!);
    _onUser(res['user']);
  }

  void _onUser(Map<String, dynamic> u) {
    user = u;
    balance = (u['balance'] as num?)?.toInt() ?? 0;
    status = AuthStatus.loggedIn;
    loadNotes();
    _refreshPush();
    notifyListeners();
    _connect();
  }

  Future<void> refreshMe() async {
    try {
      final u = await api.get('/me');
      user = u;
      balance = (u['balance'] as num).toInt();
      notifyListeners();
    } catch (_) {}
  }

  /// Nova slika profila (već smanjena), ili null za brisanje.
  Future<void> setAvatar(List<int>? bytes) async {
    final u = bytes == null ? await api.delete('/me/avatar') : await api.post('/me/avatar', {'data': base64Encode(bytes)});
    user = {...?user, 'avatarUrl': u['avatarUrl']};
    notifyListeners();
  }

  Future<void> logout() async {
    _socket?.dispose();
    _socket = null;
    connected = false;
    api.token = null;
    user = null;
    lobby = [];
    tables.clear();
    _watching.clear();
    _inLobby = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    status = AuthStatus.loggedOut;
    notifyListeners();
  }

  // ---------- Socket ----------

  void _connect() {
    _socket?.dispose();
    final s = io.io(
      apiBaseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setPath('/socket.io')
          .setAuth({'token': api.token})
          .disableAutoConnect()
          // Nova veza za svaku prijavu: inače biblioteka ponovo koristi staru vezu
          // (sa tokenom prethodnog naloga) i server misli da je to prethodni igrač.
          .enableForceNew()
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .build(),
    );
    _socket = s;
    s.onConnect((_) {
      connected = true;
      notifyListeners();
    });
    s.on('session', (_) {
      s.emit('presence', {'visible': _visible});
      // Posle (ponovnog) povezivanja: ponovo se prijavi na lobi i stolove koje gledamo.
      if (_inLobby) joinLobby();
      for (final id in _watching) {
        _watch(id);
      }
    });
    s.onDisconnect((_) {
      connected = false;
      notifyListeners();
    });
    s.on('auth:error', (data) {
      final msg = (data is Map ? data['error'] : null)?.toString() ?? 'Prijavite se ponovo.';
      if (status == AuthStatus.loggedIn) {
        logout();
        toast(msg);
      }
    });
    s.on('lobby', (data) {
      lobby = (data as List).cast<Map<String, dynamic>>();
      notifyListeners();
    });
    s.on('balance', (data) {
      balance = ((data as Map)['balance'] as num).toInt();
      notifyListeners();
    });
    s.on('table:state', (data) => _onTable(Map<String, dynamic>.from(data as Map)));
    s.on('table:chat', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      final id = m['tableId'] as String;
      final list = chatOf(id);
      list.value = [...list.value, Map<String, dynamic>.from(m['message'] as Map)].reversed.take(50).toList().reversed.toList();
      if (openChat != id) unreadOf(id).value++;
    });
    s.on('kicked', (data) {
      final reason = (data as Map)['reason']?.toString();
      if (reason != null) toast(reason);
    });
    // Zakazani sto se upravo otvorio.
    s.on('table:opened', (data) {
      final m = data as Map;
      final blinds = '${m['smallBlind']}/${m['bigBlind']} RSD';
      notify('Sto „${m['name']}“ (${m['variant'] == 'OMAHA' ? 'PLO' : 'NLH'} $blinds) se otvorio!',
          action: 'IGRAJ', tableId: m['tableId'] as String);
    });
    // Lista čekanja: oslobodilo se mesto za ovog igrača.
    s.on('waitlist:offer', (data) {
      final m = data as Map;
      notify('Mesto za stolom „${m['name']}“ je slobodno! Imate ${m['seconds']} s da sednete.',
          action: 'SEDI', tableId: m['tableId'] as String, duration: Duration(seconds: (m['seconds'] as num).toInt()));
    });
    s.connect();
  }

  void _onTable(Map<String, dynamic> st) {
    final server = (st['serverTime'] as num?)?.toInt();
    if (server != null) clockOffset = server - DateTime.now().millisecondsSinceEpoch;
    tableNotifier(st['id'] as String).value = st;
  }

  ValueNotifier<Map<String, dynamic>?> tableNotifier(String id) => tables.putIfAbsent(id, () => ValueNotifier(null));

  int get serverNow => DateTime.now().millisecondsSinceEpoch + clockOffset;

  Future<Map<String, dynamic>> emit(String event, [Map<String, dynamic>? data]) async {
    final s = _socket;
    if (s == null || !connected) return {'ok': false, 'error': 'Nema veze sa serverom.'};
    try {
      final res = await s.emitWithAckAsync(event, data ?? {}).timeout(const Duration(seconds: 10));
      return Map<String, dynamic>.from(res as Map);
    } catch (_) {
      return {'ok': false, 'error': 'Server ne odgovara. Pokušajte ponovo.'};
    }
  }

  /// Šalje radnju i prikazuje grešku ako je ima. Vraća true ako je uspelo.
  Future<bool> run(String event, Map<String, dynamic> data) async {
    final res = await emit(event, data);
    if (res['ok'] != true) toast(res['error']?.toString() ?? 'Greška.');
    return res['ok'] == true;
  }

  Future<void> joinLobby() async {
    _inLobby = true;
    final res = await emit('lobby:join');
    if (res['ok'] == true) {
      lobby = (res['tables'] as List).cast<Map<String, dynamic>>();
      notifyListeners();
    }
  }

  /// Vraća false ako sto ne može da se otvori (npr. zakazan za kasnije).
  Future<bool> watch(String tableId) async {
    _watching.add(tableId);
    // Posle ponovnog otvaranja aplikacije veza se tek uspostavlja: sačekaj je malo.
    for (var i = 0; i < 100 && !connected; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    final ok = await _watch(tableId);
    if (!ok) _watching.remove(tableId);
    return ok;
  }

  Future<bool> _watch(String tableId) async {
    final res = await emit('table:watch', {'tableId': tableId});
    if (res['ok'] == true) {
      _onTable(Map<String, dynamic>.from(res['state'] as Map));
      chatOf(tableId).value = ((res['chat'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      return true;
    } else if (res['error'] != null) {
      toast(res['error'].toString());
    }
    return false;
  }

  Future<void> unwatch(String tableId) async {
    _watching.remove(tableId);
    tables.remove(tableId);
    chats.remove(tableId);
    unread.remove(tableId);
    await emit('table:unwatch', {'tableId': tableId});
  }
}
