import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../api.dart';
import '../config.dart';

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

  /// Razlika serverskog i lokalnog sata (ms), da tajmer ne zavisi od sata telefona.
  int clockOffset = 0;

  AppState() {
    api.onUnauthorized = (msg) {
      if (status == AuthStatus.loggedIn) {
        logout();
        toast(msg);
      }
    };
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
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
    s.on('kicked', (data) {
      final reason = (data as Map)['reason']?.toString();
      if (reason != null) toast(reason);
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

  Future<void> watch(String tableId) async {
    _watching.add(tableId);
    await _watch(tableId);
  }

  Future<void> _watch(String tableId) async {
    final res = await emit('table:watch', {'tableId': tableId});
    if (res['ok'] == true) {
      _onTable(Map<String, dynamic>.from(res['state'] as Map));
    } else if (res['error'] != null) {
      toast(res['error'].toString());
    }
  }

  Future<void> unwatch(String tableId) async {
    _watching.remove(tableId);
    tables.remove(tableId);
    await emit('table:unwatch', {'tableId': tableId});
  }
}
