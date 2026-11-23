import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../sound.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/action_bar.dart';
import '../widgets/avatar.dart';
import '../widgets/hand_history.dart';
import '../widgets/playing_card.dart';
import '../widgets/table_chat.dart';
import '../widgets/brand.dart';
import '../widgets/chips.dart';
import 'home_shell.dart';
import 'tournaments.dart' show TourBar, TournamentScreen, clockLeft;
import '../i18n.dart';

typedef Json = Map<String, dynamic>;

/// Potez izabran unapred, dok igrač još nije na redu.
/// Potez unapred (štiklira se pre nego što igrač dođe na red), kao na GG.
/// Bez uloga za dorovnavanje: Check/Fold, Check, Call any. Sa ulogom: Fold, Call X, Call any.
enum PreAction { checkFold, check, fold, call, callAny }

/// Koliko igrač treba da doplati da bi dorovnao (0 = može check).
int toCallOf(Json st) {
  final mySeat = st['mySeat'] as int;
  if (mySeat < 0) return 0;
  final seats = (st['seats'] as List).cast<Json?>();
  final me = seats[mySeat]!;
  final top = seats.fold<int>(0, (m, x) => x == null ? m : max(m, x['bet'] as int));
  return min(top - (me['bet'] as int), me['stack'] as int).clamp(0, 1 << 31);
}

/// Moje karte koje mogu da pokažem ostalima (posle fold-a ili na kraju ruke), ili null.
List<String>? showableCards(Json st) {
  final mySeat = st['mySeat'] as int;
  if (mySeat < 0 || st['ritPending'] == true) return null;
  final me = (st['seats'] as List)[mySeat] as Json?;
  if (me == null) return null;
  final cards = (me['cards'] as List?)?.cast<String>() ?? const <String>[];
  final result = st['result'] as Json?;
  final openedAtEnd = ((result?['shown'] as List?) ?? const []).any((x) => x['seat'] == mySeat);
  final shown = ((me['myShown'] as List?) ?? const []).cast<int>();
  final ok = cards.isNotEmpty &&
      !openedAtEnd &&
      shown.length < cards.length &&
      ((result != null && st['inProgress'] != true) || (st['inProgress'] == true && me['inHand'] == true && me['folded'] == true));
  return ok ? cards : null;
}

/// Napušta sto (uz potvrdu ako igrač sedi za njim) i zatvara njegov tab.
Future<void> leaveTable(BuildContext context, AppState app, String tableId) async {
  final st = app.tableNotifier(tableId).value;
  final seated = st != null && (st['mySeat'] as int) >= 0;
  // Turnir: sa stola se ne ustaje; prozor se zatvara, a igrač je na pauzi (karte mu se same bacaju).
  if (seated && st['tournament'] != null) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Close ${st['name']}?', 'Zatvoriti ${st['name']}?')),
        content: Text(tr('You stay in the tournament. While the table is closed you are sitting out and your hands are folded automatically.',
            'Ostajete u turniru. Dok je sto zatvoren, na pauzi ste i karte vam se same bacaju.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Stay', 'Ostani'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Close', 'Zatvori'))),
        ],
      ),
    );
    if (ok != true) return;
    await app.run('table:sitout', {'tableId': tableId, 'value': true});
    app.closeTable(tableId);
    return;
  }
  if (seated) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Leave ${st['name']}?', 'Napustiti ${st['name']}?')),
        content: Text(st['inProgress'] == true
            ? tr('If you are in a hand, you fold. Your chips go back to your account.', 'Ako ste u ruci, odustajete. Žetoni se vraćaju na nalog.')
            : tr('Your chips go back to your account.', 'Žetoni se vraćaju na nalog.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Stay', 'Ostani'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Leave', 'Izađi'))),
        ],
      ),
    );
    if (ok != true) return;
    if (!await app.run('table:leave', {'tableId': tableId})) return;
  }
  app.closeTable(tableId);
}

class TableScreen extends StatefulWidget {
  final String tableId;

  /// Sto je trenutno prikazan (ostali otvoreni stolovi rade u pozadini, u svojim tabovima).
  final bool active;
  const TableScreen({super.key, required this.tableId, this.active = true});

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends State<TableScreen> {
  late final AppState app;
  Timer? _ticker;
  PreAction? _pre;
  int _preHand = -1;
  /// Za "Call X": iznos koji je igrač izabrao (ako se promeni, izbor se poništava).
  int _preCall = 0;
  bool _sending = false;

  /// Sakrivene karte su privremeno otkrivene (dodir na svoje karte).
  bool _peek = false;
  int _rebuyHand = -1;
  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    app = context.read<AppState>();
    app.watch(widget.tableId).then((ok) {
      // Sto nije dostupan (npr. zakazan za kasnije): zatvori njegov tab.
      if (!ok && mounted) app.closeTable(widget.tableId);
    });
    app.tableNotifier(widget.tableId).addListener(_onState);
    // Osvežavanje tajmera za potez.
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final st = app.tableNotifier(widget.tableId).value;
      if (mounted && widget.active && (st?['deadline'] != null || st?['tournament'] != null)) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant TableScreen old) {
    super.didUpdateWidget(old);
    // Kad se igrač vrati na ovaj sto: prozor za rebuy koji je čekao dok je bio na drugom stolu.
    if (widget.active && !old.active) {
      final st = app.tableNotifier(widget.tableId).value;
      if (st != null) _maybeRebuyDialog(st);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    app.tableNotifier(widget.tableId).removeListener(_onState);
    app.unwatch(widget.tableId);
    app.refreshMe();
    super.dispose();
  }

  /// Kad igrač dođe na red, a ima izabran potez unapred — odigraj ga odmah.
  void _onState() {
    final st = app.tableNotifier(widget.tableId).value;
    if (st != null) _autoRebuy(st);
    if (st != null) _maybeRebuyDialog(st);
    if (st == null || _pre == null || _sending) return;
    if (st['handNo'] != _preHand) {
      setState(() => _pre = null);
      return;
    }
    final legal = st['legal'] as Json?;
    if (legal == null) {
      // Još nismo na redu: neko je povisio → Check/Fold postaje Fold, Check i Call X se poništavaju.
      final toCall = toCallOf(st);
      final p = _pre!;
      PreAction? next = p;
      if (toCall > 0 && p == PreAction.checkFold) next = PreAction.fold;
      if (toCall > 0 && p == PreAction.check) next = null;
      if (p == PreAction.call && toCall != _preCall) next = null;
      if (toCall == 0 && p == PreAction.fold) next = PreAction.checkFold;
      if (next != p) setState(() => _pre = next);
      return;
    }
    final pre = _pre!;
    _pre = null;
    final canCheck = legal['check'] == true;
    final call = legal['call'] as int;
    final String? action = switch (pre) {
      PreAction.checkFold || PreAction.fold => canCheck ? 'check' : 'fold',
      PreAction.check => canCheck ? 'check' : null,
      PreAction.call => !canCheck && call == _preCall ? 'call' : (canCheck ? 'check' : null),
      PreAction.callAny => canCheck ? 'check' : 'call',
    };
    if (action == null) {
      setState(() {});
      return;
    }
    _sending = true;
    app.run('table:act', {'tableId': widget.tableId, 'action': action}).whenComplete(() => _sending = false);
  }

  /// Automatski re-buy: kad igrač ostane bez novca na stolu, dopuni do najvećeg ulaza.
  void _autoRebuy(Json st) {
    final mySeat = st['mySeat'] as int;
    if (!app.autoRebuy || mySeat < 0) return;
    final me = (st['seats'] as List)[mySeat] as Json;
    if (me['stack'] != 0 || me['inHand'] == true || _rebuyHand == st['handNo']) return;
    final amount = min(st['maxBuyIn'] as int, app.balance);
    if (amount <= 0) return;
    _rebuyHand = st['handNo'] as int;
    app.run('table:topup', {'tableId': widget.tableId, 'amount': amount});
  }

  void _setPre(Json st, PreAction? p) {
    setState(() {
      _pre = _pre == p ? null : p;
      _preHand = st['handNo'] as int;
      _preCall = toCallOf(st);
    });
  }

  /// Nazad u lobi: sto ostaje otvoren u svom tabu (i dalje sedite za njim).
  void _back(Json? st) => app.showLobby();

  /// Ustajanje od stola (uz potvrdu) i zatvaranje njegovog taba.
  Future<void> _leave() => leaveTable(context, app, widget.tableId);

  @override
  Widget build(BuildContext context) {
    final showBB = context.select<AppState, bool>((a) => a.showBB);
    context.select<AppState, bool>((a) => a.hideCards);
    context.select<AppState, bool>((a) => a.fourColor);
    return ValueListenableBuilder<Json?>(
      valueListenable: app.tableNotifier(widget.tableId),
      builder: (context, st, _) {
        final money = Money((st?['bigBlind'] as int?) ?? 0, showBB);
        final wide = MediaQuery.of(context).size.width >= 900;
        return KeyedSubtree(
          child: Scaffold(
            key: _scaffold,
            backgroundColor: bg,
            // Tastatura (chat u panelu) ne sme da skupi sto; panel se sam pomera iznad nje.
            resizeToAvoidBottomInset: false,
            // Telefon: igrači, ruke i chat u panelu koji se izvlači sa desne strane.
            endDrawer: st == null || wide
                ? null
                : Drawer(
                    width: min(380, MediaQuery.of(context).size.width * 0.88),
                    backgroundColor: const Color(0xFF0E0B09),
                    // Kad se otvori tastatura (chat), panel se skupi iznad nje da se vidi šta se kuca.
                    child: Padding(
                      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
                      child: SafeArea(child: TableSidePanel(st: st, table: app.tableNotifier(widget.tableId), money: money)),
                    ),
                  ),
            onEndDrawerChanged: (open) {
              app.openChat = open ? widget.tableId : null;
              if (open) app.unreadOf(widget.tableId).value = 0;
            },
            body: LuxBackground(
              child: st == null ? const Center(child: CircularProgressIndicator(color: gold)) : _body(st, money, wide),
            ),
          ),
        );
      },
    );
  }

  Widget _tableArea(Json st, Money money, bool wide) {
    return LayoutBuilder(builder: (_, c) {
      // Sto zadržava dobru srazmeru i stoji u sredini.
      // Računar: sto je širi i niži (da donja traka ništa ne seče).
      final w = min(c.maxWidth, c.maxHeight * (wide ? 1.95 : 1.6));
      final h = min(c.maxHeight, w * 2.0);
      return Center(
        child: SizedBox(
          width: w,
          height: h,
          child: ValueListenableBuilder<List<Json>>(
            valueListenable: app.chatOf(widget.tableId),
            builder: (_, chat, __) => _TableView(
              st: st,
              size: Size(w, h),
              money: money,
              chat: chat,
              wide: wide,
              hideMine: app.hideCards && !_peek,
              onTapMine: () => setState(() => _peek = !_peek),
              onSit: (i) => _sit(st, i),
              onTapPlayer: (s) => _playerInfo(st, s),
              active: widget.active,
            ),
          ),
        ),
      );
    });
  }

  Widget _panel(Json st, Money money, bool wide) {
    final mySeat = st['mySeat'] as int;
    if (mySeat < 0) return _WaitPanel(st: st, app: app);
    return _MyPanel(
      st: st,
      app: app,
      money: money,
      wide: wide,
      pre: _pre,
      onPre: (p) => _setPre(st, p),
      onTopUp: () => _topUp(st, (st['seats'] as List)[mySeat] as Json),
    );
  }

  Widget _body(Json st, Money money, bool wide) {
    final mySeat = st['mySeat'] as int;
    if (wide) {
      // Računar: gornji meni, sto u sredini, igrači/ruke/chat desno, potezi dole (kao u dizajnu).
      if (widget.active) app.openChat = widget.tableId;
      return Column(children: [
        LuxTopBar(
          // Sto turnira pripada stranici Tournaments, cash sto stranici Cash Game.
          selected: st['tournament'] != null ? tabTournaments : tabCash,
          onSelect: (i) => app.goHome?.call(i),
          leading: IconButton(
            tooltip: tr('Back to lobby', 'Nazad u lobi'),
            onPressed: () => _back(st),
            icon: const Icon(Icons.arrow_back_ios_new, color: gold, size: 20),
          ),
        ),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Stack(children: [
                Positioned.fill(
                    child: Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 0), child: _tableArea(st, money, true))),
                Positioned(left: 14, top: 12, child: _TableInfoCard(st: st, now: app.serverNow)),

                // Snaga moje ruke: donji levi ugao prostora sa stolom (iznad trake sa potezima).
                if (st['myHand'] != null && (st['mySeat'] as int) >= 0 && !_TableViewState.waitingForPlayers(st))
                  Positioned(left: 14, bottom: 10, child: _HandPill(st['myHand'] as String, big: true)),
                Positioned(
                  right: 14,
                  top: 12,
                  child: Row(children: [
                    const _SoundButton(),
                    const SizedBox(width: 8),
                    _UnitToggle(showBB: money.inBB, onToggle: app.setShowBB),
                    if (mySeat >= 0) ...[
                      const SizedBox(width: 8),
                      _MenuButton(st: st, onTap: () => _menu(st)),
                    ],
                  ]),
                ),
              ]),
            ),
            SizedBox(
              width: 340,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                // Turnir: nivo, pauza, mesto i fond iznad liste igrača (ne prekriva sto).
                child: Column(children: [
                  if (st['tournament'] != null) ...[
                    _TourInfoButton(tour: st['tournament'] as Json),
                    const SizedBox(height: 10),
                  ],
                  Expanded(child: TableSidePanel(st: st, table: app.tableNotifier(widget.tableId), money: money, wide: true)),
                ]),
              ),
            ),
          ]),
        ),
        _panel(st, money, true),
      ]);
    }
    return SafeArea(
      child: Column(children: [
        _TopBar(
          st: st,
          showBB: money.inBB,
          onBack: () => _back(st),
          onToggle: app.setShowBB,
          onPanel: () => _scaffold.currentState?.openEndDrawer(),
          unread: app.unreadOf(widget.tableId),
          onMenu: mySeat >= 0 ? () => _menu(st) : null,
        ),
        if (st['tournament'] != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            // Dodir na traku otvara sve o turniru (info, rang lista, nagrade, stolovi).
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TournamentScreen(id: (st['tournament'] as Json)['id'] as String))),
              child: TourBar(tour: st['tournament'] as Json, now: app.serverNow),
            ),
          ),
        // Sto preko celog ekrana; potezi (i potezi unapred) stoje preko donje ivice stola.
        Expanded(
          child: Stack(children: [
            // Dole ostaje mesto za dugmad, da se uvek vidi moja pločica (ime i stek).
            Positioned.fill(child: Padding(padding: const EdgeInsets.only(bottom: 66), child: _tableArea(st, money, false))),
            Positioned(left: 0, right: 0, bottom: 0, child: _panel(st, money, false)),
          ]),
        ),
      ]),
    );
  }

  /// Ostali ste bez žetona: prozor Rebuy / Leave table sa tajmerom (2 min), jednom po isteku.
  int? _rebuyShown;
  void _maybeRebuyDialog(Json st) {
    final until = st['rebuyUntil'] as int?;
    if (until == null || until == _rebuyShown || !mounted || !widget.active) return;
    // Prvo se odigra kraj ruke (karte, pobednik, žetoni), pa tek onda prozor.
    if (st['result'] != null) return;
    _rebuyShown = until;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _RebuyDialog(until: until, app: app, tableId: widget.tableId),
      );
      if (!mounted) return;
      final now = app.tableNotifier(widget.tableId).value;
      if (choice == 'rebuy' && now != null && (now['mySeat'] as int) >= 0) {
        await _topUp(now, (now['seats'] as List)[now['mySeat'] as int] as Json);
        // Ako nije dopunio, prozor se ponovo pojavi dok rok ne istekne.
        final after = app.tableNotifier(widget.tableId).value;
        if (after?['rebuyUntil'] == until) _rebuyShown = null;
        if (after != null) _maybeRebuyDialog(after);
      } else if (choice == 'leave') {
        await app.run('table:leave', {'tableId': widget.tableId});
        app.closeTable(widget.tableId);
      }
    });
  }

  /// Mali prozor na sredini ekrana: statistika igrača za ovim stolom (i beleška za druge igrače).
  void _playerInfo(Json st, Json seat) {
    final isMe = seat['userId'] == app.user?['id'];
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _PlayerStatsDialog(
        tableId: widget.tableId,
        seat: seat,
        isMe: isMe,
        money: Money((st['bigBlind'] as int?) ?? 0, app.showBB),
        onNote: isMe
            ? null
            : () {
                Navigator.pop(ctx);
                _noteDialog(seat);
              },
      ),
    );
  }

  /// Beleška o drugom igraču (vidi je samo ovaj igrač).
  Future<void> _noteDialog(Json seat) async {
    final id = seat['userId'] as String;
    final ctrl = TextEditingController(text: app.notes[id] ?? '');
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.edit_note, color: gold),
          const SizedBox(width: 8),
          Expanded(child: Text('${tr('Note', 'Beleška')}: ${seat['name']}', overflow: TextOverflow.ellipsis)),
        ]),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 4,
              maxLength: 500,
              decoration: InputDecoration(hintText: tr('e.g. "bluffs a lot", "plays only strong hands"', 'npr. „mnogo blefira“, „igra samo jake ruke“')),
            ),
            Text(tr('Only you can see this note.', 'Ovu belešku vidite samo vi.'), style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ]),
        ),
        actions: [
          if (app.notes.containsKey(id))
            TextButton(
              onPressed: () {
                ctrl.text = '';
                Navigator.pop(ctx, true);
              },
              child: Text(tr('Delete', 'Obriši'), style: const TextStyle(color: accent)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel', 'Otkaži'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Save', 'Sačuvaj'))),
        ],
      ),
    );
    if (save != true) return;
    try {
      await app.saveNote(id, ctrl.text);
      if (mounted) setState(() {});
    } catch (e) {
      app.toast(tr('Note was not saved.', 'Beleška nije sačuvana.'));
    }
  }

  void _menu(Json st) {
    final me = (st['seats'] as List)[st['mySeat'] as int] as Json;
    final sittingOut = me['sittingOut'] == true;
    final prefs = (st['myPrefs'] as Json?) ?? const {};
    var straddle = prefs['straddle'] == true;
    final tour = st['tournament'] as Json?;
    showModalBottomSheet(
      context: context,
      backgroundColor: panel,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          StatefulBuilder(
            builder: (ctx, setLocal) => Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.swap_horiz),
                title: Text(tr('Auto-switch tables', 'Automatski prelaz na sto')),
                subtitle: Text(tr('When it is your turn at another open table, jump to that table', 'Kad ste na potezu za drugim otvorenim stolom, pređi na taj sto')),
                value: app.autoSwitch,
                onChanged: (v) async {
                  await app.setSetting('autoSwitch', v);
                  setLocal(() {});
                },
              ),
              if (st['straddle'] == true)
                SwitchListTile(
                  secondary: const Icon(Icons.keyboard_double_arrow_up),
                  title: const Text('Straddle'),
                  subtitle: Text(tr('When you are first after the big blind, you post 2 big blinds before the cards', 'Kad ste prvi posle velikog blajnda, pre karata stavljate 2 velika blajnda')),
                  value: straddle,
                  onChanged: (v) async {
                    setLocal(() => straddle = v);
                    await app.run('table:prefs', {'tableId': widget.tableId, 'straddle': v});
                  },
                ),
            ]),
          ),
          const Divider(height: 1, color: Colors.white12),
          // Pokaži svoje karte ostalima (posle fold-a ili na kraju ruke).
          if (showableCards(st) case final cards?) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(children: [
                const Icon(Icons.visibility, color: goldLight),
                const SizedBox(width: 16),
                Expanded(child: Text(tr('Show cards', 'Pokaži karte'), style: const TextStyle(fontSize: 16))),
                for (var k = 0; k < cards.length; k++)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Opacity(
                      opacity: (((me['myShown'] as List?) ?? const []).contains(k)) ? 0.35 : 1,
                      child: GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          app.run('table:show', {'tableId': widget.tableId, 'cards': [k]});
                        },
                        child: PlayingCard(code: cards[k], width: cards.length > 2 ? 30 : 36),
                      ),
                    ),
                  ),
              ]),
            ),
            ListTile(
              leading: const Icon(Icons.check_box_outlined, color: goldLight),
              title: Text(cards.length > 2 ? tr('Show all', 'Pokaži sve') : tr('Show both', 'Pokaži obe')),
              onTap: () {
                Navigator.pop(ctx);
                app.run('table:show', {'tableId': widget.tableId, 'cards': [for (var k = 0; k < cards.length; k++) k]});
              },
            ),
            const Divider(height: 1, color: Colors.white12),
          ],
          if (tour == null)
            ListTile(
              leading: const Icon(Icons.add_circle),
              title: const Text('Rebuy'),
              onTap: () {
                Navigator.pop(ctx);
                _topUp(st, me);
              },
            ),
          // Turnir: rebuy i add-on (kad su dozvoljeni).
          if (tour != null && tour['canRebuy'] == true)
            ListTile(
              leading: const Icon(Icons.add_circle, color: goldLight),
              title: const Text('Rebuy'),
              subtitle: Text('${rsd((tour['rebuy'] as Json)['price'])} → ${chips((tour['rebuy'] as Json)['chips'])} ${tr('chips', 'žetona')}'),
              onTap: () {
                Navigator.pop(ctx);
                app.run('tour:rebuy', {'id': tour['id']});
              },
            ),
          if (tour != null && tour['canAddon'] == true)
            ListTile(
              leading: const Icon(Icons.add_box, color: goldLight),
              title: const Text('Add-on'),
              subtitle: Text('${rsd((tour['addon'] as Json)['price'])} → ${chips((tour['addon'] as Json)['chips'])} ${tr('chips', 'žetona')}'),
              onTap: () {
                Navigator.pop(ctx);
                app.run('tour:addon', {'id': tour['id']});
              },
            ),
          ListTile(
            leading: Icon(sittingOut ? Icons.play_arrow : Icons.pause),
            title: Text(sittingOut ? tr("I'm back", 'Vraćam se') : tr('Sit out next hand', 'Pauza od sledeće ruke')),
            onTap: () {
              Navigator.pop(ctx);
              app.run('table:sitout', {'tableId': widget.tableId, 'value': !sittingOut});
            },
          ),
          if (tour == null)
          ListTile(
            leading: const Icon(Icons.logout, color: accent),
            title: Text(tr('Leave table', 'Napusti sto')),
            onTap: () async {
              Navigator.pop(ctx);
              await _leave();
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _sit(Json st, int seat) async {
    final min = st['minBuyIn'] as int;
    final max = st['maxBuyIn'] as int;
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => ChipsDialog(
        title: 'Buy-in',
        min: min,
        max: max,
        balance: app.balance,
        confirm: tr('Sit', 'Sedi'),
        info: '${tr('Blinds', 'Blajndovi')} ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} · ${tr('buy-in', 'ulaz')} ${chips(min)} – ${chips(max)}',
      ),
    );
    if (amount == null) return;
    await app.run('table:sit', {'tableId': widget.tableId, 'seat': seat, 'buyIn': amount});
  }

  Future<void> _topUp(Json st, Json me) async {
    final room = (st['maxBuyIn'] as int) - (me['stack'] as int);
    if (room <= 0) {
      app.toast(tr('You already have the maximum for this table.', 'Već imate najviše što je dozvoljeno za ovim stolom.'));
      return;
    }
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => ChipsDialog(
        title: 'Rebuy',
        min: 1,
        max: room,
        balance: app.balance,
        confirm: 'Rebuy',
        info: tr('You have ${chips(me['stack'])} on the table, max ${chips(st['maxBuyIn'])}. Rebuy applies from the next hand.',
            'Na stolu imate ${chips(me['stack'])}, najviše ${chips(st['maxBuyIn'])}. Dopuna važi od sledeće ruke.'),
      ),
    );
    if (amount == null) return;
    await app.run('table:topup', {'tableId': widget.tableId, 'amount': amount});
  }
}

/// Prozor dilera za run it twice (ispod pota): pitanje, ko je pristao/odbio, rok,
/// i dugmad YES/NO za igrača koji još nije odgovorio. Vide ga svi za stolom.
class _RitPanel extends StatefulWidget {
  final Json st;
  final bool wide;
  const _RitPanel({required this.st, required this.wide});

  @override
  State<_RitPanel> createState() => _RitPanelState();
}

class _RitPanelState extends State<_RitPanel> {
  Timer? _t;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 200), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final st = widget.st;
    final seats = (st['seats'] as List).cast<Json?>();
    final ask = ((st['ritAsk'] as List?) ?? const []).cast<int>();
    final yes = ((st['ritYes'] as List?) ?? const []).cast<int>();
    final no = ((st['ritNo'] as List?) ?? const []).cast<int>();
    final me = st['mySeat'] as int;
    final deadline = st['ritDeadline'] as int?;
    final left = deadline == null ? 0.0 : ((deadline - app.serverNow) / 10000).clamp(0.0, 1.0);
    final canAnswer = ask.contains(me) && !yes.contains(me) && !no.contains(me) && no.isEmpty && !_sent;
    final fs = widget.wide ? 13.0 : 11.5;

    Future<void> answer(bool v) async {
      setState(() => _sent = true);
      final ok = await app.run('table:rit', {'tableId': st['id'], 'yes': v});
      if (!ok && mounted) setState(() => _sent = false);
    }

    return Container(
      width: widget.wide ? 300 : 236,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xEE120E0B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: gold),
        boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 12)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.filter_2, size: fs + 3, color: goldLight),
          const SizedBox(width: 6),
          GoldText(tr('Dealer: Run it twice?', 'Diler: Run it twice?'), style: TextStyle(fontWeight: FontWeight.w900, fontSize: fs + 1.5)),
        ]),
        const SizedBox(height: 6),
        for (final i in ask)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(children: [
              Expanded(
                child: Text((seats[i]?['name'] as String?) ?? '?',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: fs, fontWeight: FontWeight.w700, color: i == me ? goldLight : Colors.white)),
              ),
              if (no.contains(i))
                Text('✗ No', style: TextStyle(fontSize: fs, fontWeight: FontWeight.w900, color: const Color(0xFFFF6B6B)))
              else if (yes.contains(i))
                Text('✓ Yes', style: TextStyle(fontSize: fs, fontWeight: FontWeight.w900, color: const Color(0xFF5FD39A)))
              else
                Text('…', style: TextStyle(fontSize: fs, fontWeight: FontWeight.w900, color: Colors.white54)),
            ]),
          ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(value: left, minHeight: 3, color: goldLight, backgroundColor: Colors.white10),
        ),
        if (canAnswer) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: LuxButton(title: 'NO', height: widget.wide ? 38 : 32, gradient: redGradient, onTap: () => answer(false))),
            const SizedBox(width: 8),
            Expanded(child: LuxButton(title: 'YES', height: widget.wide ? 38 : 32, onTap: () => answer(true))),
          ]),
        ],
      ]),
    );
  }
}

/// Prozor kad igrač ostane bez žetona: Rebuy ili Leave table, sa odbrojavanjem.
/// Kad vreme istekne, server podiže igrača sa stola i oslobađa mesto.
class _RebuyDialog extends StatefulWidget {
  final int until;
  final AppState app;
  final String tableId;
  const _RebuyDialog({required this.until, required this.app, required this.tableId});

  @override
  State<_RebuyDialog> createState() => _RebuyDialogState();
}

class _RebuyDialogState extends State<_RebuyDialog> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final st = widget.app.tableNotifier(widget.tableId).value;
      // Dopunio je (npr. na drugom uređaju), ustao ili je vreme isteklo: prozor se zatvara.
      if (st == null || st['rebuyUntil'] != widget.until || widget.app.serverNow > widget.until + 1500) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left0 = ((widget.until - widget.app.serverNow) / 1000).ceil().clamp(0, 999);
    final total = ((widget.until - widget.app.serverNow) / 120000).clamp(0.0, 1.0);
    final left = min(left0, 120);
    return Dialog(
      backgroundColor: const Color(0xFF15110E),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: gold.withOpacity(0.6))),
      // Mali, skoro kvadratni prozor i na računaru (kao na telefonu).
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GoldText(tr('Out of chips', 'Nemate žetona'), style: const TextStyle(fontFamily: 'Cinzel', fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(tr('Rebuy to keep playing, or leave the table so another player can sit.', 'Dopunite da nastavite, ili napustite sto da drugi igrač može da sedne.'),
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 14),
          Text('${left ~/ 60}:${two(left % 60)}', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: goldLight)),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: total, minHeight: 4, color: goldLight, backgroundColor: Colors.white10),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: LuxButton(title: tr('Leave table', 'Napusti sto'), height: 46, gradient: redGradient, onTap: () => Navigator.pop(context, 'leave')),
            ),
            const SizedBox(width: 10),
            Expanded(child: LuxButton(title: 'Rebuy', icon: Icons.add_circle, height: 46, onTap: () => Navigator.pop(context, 'rebuy'))),
          ]),
        ]),
      ),
      ),
    );
  }
}

/// Statistika igrača za ovim stolom (kao na GG / ClubGG): VPIP, PFR, dobijene ruke,
/// najveći pot i najbolja pokazana ruka. Zatvara se dugmetom ili dodirom pored prozora.
class _PlayerStatsDialog extends StatefulWidget {
  final String tableId;
  final Json seat;
  final bool isMe;
  final Money money;
  final VoidCallback? onNote;
  const _PlayerStatsDialog({required this.tableId, required this.seat, required this.isMe, required this.money, this.onNote});

  @override
  State<_PlayerStatsDialog> createState() => _PlayerStatsDialogState();
}

class _PlayerStatsDialogState extends State<_PlayerStatsDialog> {
  Json? _stats;
  String? _error;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    app.api
        .get('/me/table-stats?tableId=${widget.tableId}&userId=${widget.seat['userId']}')
        .then((r) => mounted ? setState(() => _stats = Map<String, dynamic>.from(r as Map)) : null)
        .catchError((_) => mounted ? setState(() => _error = tr('Stats are not available right now.', 'Statistika trenutno nije dostupna.')) : null);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final s = _stats;
    final note = app.notes[widget.seat['userId']];
    Widget tile(String value, String label, {String? hint, Color color = Colors.white}) => Expanded(
          child: Tooltip(
            message: hint ?? '',
            child: Container(
              margin: const EdgeInsets.all(3),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(10)),
              child: Column(children: [
                FittedBox(child: Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color))),
                const SizedBox(height: 2),
                Text(label, style: const TextStyle(fontSize: 11, color: Colors.white60, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        );
    String p(num v) => '${bbNumber(v.toDouble())} %';

    return Dialog(
      backgroundColor: const Color(0xFF15110E),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: gold.withOpacity(0.5))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Avatar(name: widget.seat['name'] as String, url: widget.seat['avatarUrl'] as String?, size: 46, borderColor: gold),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.seat['name'] as String,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  GoldText(widget.money(widget.seat['stack']), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                ]),
              ),
              IconButton(
                tooltip: tr('Close', 'Zatvori'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white60),
              ),
            ]),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(tr('Stats at this table', 'Statistika za ovim stolom'), style: TextStyle(fontSize: 12, color: gold, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.white60)))
            else if (s == null)
              const Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator(color: gold, strokeWidth: 2))
            else ...[
              Row(children: [
                tile(chips(s['hands'] as num), 'Hands'),
                tile(p(s['vpip'] as num), 'VPIP', hint: tr('Hands where the player voluntarily put chips in preflop', 'Ruke u kojima je igrač sam uložio pre flopa')),
                tile(p(s['pfr'] as num), 'PFR', hint: tr('Hands where the player raised preflop', 'Ruke u kojima je igrač povisio pre flopa')),
              ]),
              Row(children: [
                tile('${p(s['threeBet'] as num)} (${s['threeBets']}×)', '3-bet',
                    hint: 'Re-raises preflop (percent of chances)'),
                tile(p(s['winRate'] as num), tr('Hands won', 'Dobijene ruke'), hint: tr('${s['won']} of ${s['hands']} hands', '${s['won']} od ${s['hands']} ruku')),
                tile(widget.money(s['biggestPot']), tr('Biggest pot', 'Najveći pot'), color: goldLight),
              ]),
              Container(
                width: double.infinity,
                margin: const EdgeInsets.all(3),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(10)),
                child: s['bestHand'] == null
                    ? Text(tr('Best hand: no cards shown yet', 'Najbolja ruka: još nije pokazao karte'), style: const TextStyle(color: Colors.white54, fontSize: 12.5))
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(tr('Best hand shown · showdowns: ${s['showdowns']}', 'Najbolja pokazana ruka · otvaranja: ${s['showdowns']}'),
                            style: const TextStyle(fontSize: 11, color: Colors.white60, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Row(children: [
                          for (final c in ((s['bestHand'] as Json)['cards'] as List).cast<String>())
                            Padding(padding: const EdgeInsets.only(right: 3), child: PlayingCard(code: c, width: 26)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text((s['bestHand'] as Json)['name'] as String,
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                          ),
                        ]),
                      ]),
              ),
            ],
            if (widget.onNote != null) ...[
              const SizedBox(height: 4),
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                leading: const Icon(Icons.edit_note, color: gold),
                title: Text(note ?? tr('Add a note about this player', 'Dodaj belešku o ovom igraču'),
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: note == null ? Colors.white60 : Colors.white)),
                trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                onTap: widget.onNote,
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close', 'Zatvori'))),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Dole kad igrač ne sedi: poziv da sedne, lista čekanja kad je sto pun,
/// ili poruka da je mesto sačuvano za njega.
class _WaitPanel extends StatefulWidget {
  final Json st;
  final AppState app;
  const _WaitPanel({required this.st, required this.app});

  @override
  State<_WaitPanel> createState() => _WaitPanelState();
}

class _WaitPanelState extends State<_WaitPanel> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.st['reservedForMe'] != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final full = !(st['seats'] as List).contains(null);
    final waiting = ((st['waitlist'] as List?) ?? const []).length;
    final reserved = st['reservedForMe'] as int?;
    const style = TextStyle(color: Colors.white70, fontSize: 13);
    Widget child;
    if (reserved != null) {
      final left = ((reserved - widget.app.serverNow) / 1000).ceil().clamp(0, 999);
      child = Row(children: [
        const Icon(Icons.event_seat, color: goldLight),
        const SizedBox(width: 10),
        Expanded(
          child: Text(tr('A seat is saved for you! Tap an empty seat to sit ($left s).', 'Mesto je sačuvano za vas! Dodirnite prazno mesto da sednete ($left s).'),
              style: const TextStyle(color: goldLight, fontWeight: FontWeight.w800, fontSize: 13.5)),
        ),
      ]);
    } else if (st['onWaitlist'] == true) {
      child = Row(children: [
        const Icon(Icons.hourglass_top, color: gold),
        const SizedBox(width: 10),
        Expanded(
          child: Text(tr('Waiting list: you are ${st['waitPosition']} of $waiting. We will let you know when a seat opens.', 'Lista čekanja: vi ste ${st['waitPosition']} od $waiting. Javićemo vam kad se oslobodi mesto.'), style: style),
        ),
        TextButton(
          onPressed: () => widget.app.run('table:waitlist', {'tableId': st['id'], 'join': false}),
          child: Text(tr('Leave list', 'Napusti listu')),
        ),
      ]);
    } else if (full) {
      child = Row(children: [
        Expanded(
          child: Text(waiting > 0 ? tr('Table is full · waiting: $waiting', 'Sto je pun · čeka: $waiting') : tr('Table is full.', 'Sto je pun.'), style: style),
        ),
        SizedBox(
          width: 200,
          child: LuxButton(
            title: tr('Join waiting list', 'Lista čekanja'),
            icon: Icons.playlist_add,
            height: 42,
            onTap: () => widget.app.run('table:waitlist', {'tableId': st['id'], 'join': true}),
          ),
        ),
      ]);
    } else {
      child = st['tournament'] != null
          ? Text(tr('You are watching this tournament table.', 'Gledate sto turnira.'), style: style)
          : Text(tr('Tap an empty seat to sit down.', 'Dodirnite prazno mesto da sednete.'), style: style);
    }
    return Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 12), child: child);
  }
}

/// Zvuk uključen / isključen (pamti se).
class _SoundButton extends StatelessWidget {
  const _SoundButton();

  @override
  Widget build(BuildContext context) {
    final on = context.select<AppState, bool>((a) => a.soundOn);
    return _RoundIcon(
      icon: on ? Icons.volume_up : Icons.volume_off,
      tip: on ? tr('Sound off', 'Isključi zvuk') : tr('Sound on', 'Uključi zvuk'),
      onTap: () => context.read<AppState>().setSound(!on),
    );
  }
}

/// Dugme menija stola; zlatna tačka kad igrač može da pokaže karte.
class _MenuButton extends StatelessWidget {
  final Json st;
  final VoidCallback onTap;
  const _MenuButton({required this.st, required this.onTap});

  @override
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, children: [
        _RoundIcon(icon: Icons.menu, tip: tr('Menu', 'Meni'), onTap: onTap),
        if (showableCards(st) != null)
          Positioned(
            right: -1,
            top: -1,
            child: IgnorePointer(
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(color: goldLight, shape: BoxShape.circle, border: Border.all(color: Colors.black, width: 1.5)),
              ),
            ),
          ),
      ]);
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  const _RoundIcon({required this.icon, required this.tip, this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black45,
              shape: BoxShape.circle,
              border: Border.all(color: gold.withOpacity(0.45)),
            ),
            child: Icon(icon, size: 18, color: goldLight),
          ),
        ),
      );
}

/// Prekidač prikaza iznosa: dinari ili veliki blajndovi.
class _UnitToggle extends StatelessWidget {
  final bool showBB;
  final ValueChanged<bool> onToggle;
  const _UnitToggle({required this.showBB, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.black45, borderRadius: BorderRadius.circular(18), border: Border.all(color: gold.withOpacity(0.45))),
      padding: const EdgeInsets.all(3),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final opt in const [(false, 'CHIPS'), (true, 'BB')])
          GestureDetector(
            onTap: () => onToggle(opt.$1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration:
                  BoxDecoration(gradient: showBB == opt.$1 ? goldGradient : null, borderRadius: BorderRadius.circular(14)),
              child: Text(opt.$2,
                  style: TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w800, color: showBB == opt.$1 ? Colors.black : Colors.white70)),
            ),
          ),
      ]),
    );
  }
}

/// Kartica gore levo: igra, blajndovi i naziv stola.
/// Računar: dugme koje otvara prozor sa svim o turniru (info, rang lista, nagrade, stolovi).
class _TourInfoButton extends StatelessWidget {
  final Json tour;
  const _TourInfoButton({required this.tour});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: LuxButton(
        title: tr('TOURNAMENT INFO', 'INFORMACIJE O TURNIRU'),
        subtitle: tour['name'] as String?,
        onTap: () => showDialog(
          context: context,
          builder: (ctx) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 860,
                height: MediaQuery.of(ctx).size.height * 0.88,
                child: TournamentScreen(id: tour['id'] as String, closeIcon: true),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Poruka iz chata iznad igrača: beli oblačić sa repom ka igraču.
class _ChatBubble extends StatelessWidget {
  final String text;
  final bool tailRight;
  final bool wide;
  const _ChatBubble({required this.text, required this.tailRight, required this.wide});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: tailRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: wide ? 12 : 9, vertical: wide ? 8 : 6),
          decoration: BoxDecoration(
            color: const Color(0xFFFDF8EC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: gold, width: 1.2),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3))],
          ),
          child: Text(text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: const Color(0xFF1A1208), fontSize: wide ? 14.5 : 12.5, fontWeight: FontWeight.w600, height: 1.25)),
        ),
        Padding(
          padding: EdgeInsets.only(left: tailRight ? 0 : 10, right: tailRight ? 10 : 0),
          child: CustomPaint(size: const Size(14, 9), painter: _TailPainter(tailRight)),
        ),
      ],
    );
  }
}

class _TailPainter extends CustomPainter {
  final bool right;
  _TailPainter(this.right);
  @override
  void paint(Canvas canvas, Size size) {
    final path = right
        ? (Path()
          ..moveTo(0, 0)
          ..lineTo(size.width, 0)
          ..lineTo(size.width, size.height)
          ..close())
        : (Path()
          ..moveTo(0, 0)
          ..lineTo(size.width, 0)
          ..lineTo(0, size.height)
          ..close());
    canvas.drawPath(path, Paint()..color = const Color(0xFFFDF8EC));
    canvas.drawPath(path, Paint()
      ..color = gold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.right != right;
}

class _TableInfoCard extends StatelessWidget {
  final Json st;
  final int now;
  const _TableInfoCard({required this.st, this.now = 0});

  @override
  Widget build(BuildContext context) {
    final omaha = st['variant'] == 'OMAHA';
    final tour = st['tournament'] as Json?;
    if (tour != null) {
      // Turnir: uska kartica (ne prelazi preko stola), podaci jedan ispod drugog.
      return SizedBox(
        width: 168,
        child: LuxPanel(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          radius: 12,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('${omaha ? 'PLO' : 'NLH'} · ${omaha ? 'Omaha' : "Hold'em"}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            Text(st['name'] as String, style: const TextStyle(color: gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ..._tourLines(tour, now),
          ]),
        ),
      );
    }
    return LuxPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      radius: 12,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Row(mainAxisSize: MainAxisSize.min, children: [
          PlayingCard(width: 22),
          SizedBox(width: 2),
          PlayingCard(width: 22),
        ]),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(omaha ? 'Omaha' : "Texas Hold'em", style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          Text('${omaha ? 'PLO' : 'NLH'} ${chips(st['smallBlind'])}/${chips(st['bigBlind'])}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          Text(st['name'] as String, style: const TextStyle(color: gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
          if (tableExtras(st) != null)
            Text(tableExtras(st)!, style: const TextStyle(color: Colors.white60, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ]),
      ]),
    );
  }

  /// Turnir: nivo, blajndovi, sledeći blajndovi i za koliko, pauza i mesto.
  static List<Widget> _tourLines(Json t, int now) {
    const k = TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w600);
    const v = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800);
    Widget line(String a, String b, {Color? color}) => Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(a, style: k),
            Text(b, style: color == null ? v : v.copyWith(color: color)),
          ]),
        );
    final onBreak = t['onBreak'] == true;
    final ante = (t['ante'] as num? ?? 0) > 0 ? ' (${chips(t['ante'])})' : '';
    return [
      const SizedBox(height: 6),
      Container(height: 1, width: 144, color: Colors.white12),
      const SizedBox(height: 4),
      line(tr('Level ${t['level']}', 'Nivo ${t['level']}'), '${chips(t['sb'])}/${chips(t['bb'])}$ante', color: goldLight),
      if (onBreak) line(tr('Break', 'Pauza'), clockLeft((t['breakEndsAt'] as num?)?.toInt(), now), color: goldLight),
      if (!onBreak && t['levelEndsAt'] != null)
        line(tr('Next: ${chips(t['nextSb'])}/${chips(t['nextBb'])}', 'Sledeći: ${chips(t['nextSb'])}/${chips(t['nextBb'])}'),
            '${tr('in', 'za')} ${clockLeft((t['levelEndsAt'] as num?)?.toInt(), now)}'),
      if (!onBreak && t['nextBreakAt'] != null) line(tr('Break in', 'Pauza za'), clockLeft((t['nextBreakAt'] as num).toInt(), now)),
      line(tr('Rank', 'Mesto'), t['position'] != null ? '${t['position']}/${t['playersLeft']}' : '${t['playersLeft']}'),
    ];
  }
}

/// Posebna pravila stola: straddle i bomb pot (npr. "Straddle · Bomb pot svaka 5. ruka").
String? tableExtras(Json t) {
  final parts = <String>[
    if (t['straddle'] == true) 'Straddle',
    if (((t['bombPotEvery'] as int?) ?? 0) > 0) tr('Bomb pot every ${t['bombPotEvery']} hands', 'Bomb pot svake ${t['bombPotEvery']}. ruke'),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Telefon: sitne kontrole na vrhu (nazad, meni, sto, RSD/BB, panel sa igračima i chatom).
class _TopBar extends StatelessWidget {
  final Json st;
  final bool showBB;
  final VoidCallback onBack;
  final VoidCallback onPanel;
  final VoidCallback? onMenu;
  final ValueNotifier<int> unread;
  final ValueChanged<bool> onToggle;
  const _TopBar({
    required this.st,
    required this.showBB,
    required this.onBack,
    required this.onPanel,
    required this.onToggle,
    required this.unread,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final omaha = st['variant'] == 'OMAHA';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(children: [
        _RoundIcon(icon: Icons.arrow_back_ios_new, tip: tr('Back', 'Nazad'), onTap: onBack),
        const SizedBox(width: 6),
        if (onMenu != null) _MenuButton(st: st, onTap: onMenu!),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${omaha ? 'PLO' : 'NLH'} ${chips(st['smallBlind'])}/${chips(st['bigBlind'])}',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
            Text(st['name'] as String,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: gold, fontWeight: FontWeight.w600)),
          ]),
        ),
        const _SoundButton(),
        const SizedBox(width: 6),
        _UnitToggle(showBB: showBB, onToggle: onToggle),
        const SizedBox(width: 6),
        // Panel: igrači, ruke i chat (sa brojem nepročitanih poruka)
        ValueListenableBuilder<int>(
          valueListenable: unread,
          builder: (_, n, __) => Stack(clipBehavior: Clip.none, children: [
            _RoundIcon(icon: Icons.forum_outlined, tip: tr('Players, hands and chat', 'Igrači, ruke i chat'), onTap: onPanel),
            if (n > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(8)),
                  child: Text(n > 9 ? '9+' : '$n', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Bočni panel: igrači za stolom, ruke i chat (desno na računaru, izvlači se na telefonu).
class TableSidePanel extends StatelessWidget {
  final Json st;
  final ValueNotifier<Json?> table;
  final Money money;
  final bool wide;
  const TableSidePanel({super.key, required this.st, required this.table, required this.money, this.wide = false});

  @override
  Widget build(BuildContext context) {
    final players = (st['seats'] as List).cast<Json?>().whereType<Json>().toList();
    final playersList = ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final p in players)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(children: [
              Expanded(
                  child: Text(p['name'] as String,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, color: p['sittingOut'] == true ? Colors.white38 : null))),
              if (p['sittingOut'] == true)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text('SIT OUT', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: Colors.white38)),
                ),
              Text(money(p['stack']), style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ),
        if (players.isEmpty)
          Padding(
              padding: EdgeInsets.all(16), child: Text(tr('No one is seated.', 'Niko ne sedi.'), style: const TextStyle(color: Colors.white54))),
      ],
    );
    Widget tabs(List<String> labels) => Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(10)),
          child: TabBar(
            dividerHeight: 0,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(gradient: redGradient, borderRadius: BorderRadius.circular(8)),
            tabs: [for (final l in labels) Tab(height: 34, text: l)],
          ),
        );
    if (wide) {
      // Kao u dizajnu: gore igrači / ruke, dole chat.
      return Column(children: [
        Expanded(
          flex: 3,
          child: LuxPanel(
            padding: EdgeInsets.zero,
            child: DefaultTabController(
              length: 2,
              child: Column(children: [
                tabs(['Players (${players.length})', 'Hands']),
                Expanded(
                  child: TabBarView(children: [playersList, HandHistoryTabs(tableId: st['id'] as String, table: table)]),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          flex: 5,
          child: LuxPanel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(gradient: redGradient, borderRadius: BorderRadius.circular(8)),
                    child: const Text('Chat', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
              Expanded(child: TableChatView(tableId: st['id'] as String, compact: true)),
            ]),
          ),
        ),
      ]);
    }
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        const Padding(padding: EdgeInsets.only(top: 12), child: TrilingLogo(size: 22)),
        tabs(['Players (${players.length})', 'Hands', 'Chat']),
        Expanded(
          child: TabBarView(children: [
            playersList,
            HandHistoryTabs(tableId: st['id'] as String, table: table),
            TableChatView(tableId: st['id'] as String, compact: true),
          ]),
        ),
      ]),
    );
  }
}

/// Naziv i boja poteza za prikaz kod igrača.
({String label, Color color}) actLabel(Json act, Money money) {
  final amount = act['amount'] as int? ?? 0;
  return switch (act['type'] as String) {
    'ante' => (label: 'ANTE', color: const Color(0xFF4A4F5C)),
    'bomb' => (label: 'BOMB', color: const Color(0xFFB3122A)),
    'straddle' => (label: 'STRADDLE', color: const Color(0xFF8A5A00)),
    'sb' => (label: 'SB', color: const Color(0xFF4A4F5C)),
    'bb' => (label: 'BB', color: const Color(0xFF4A4F5C)),
    'fold' => (label: 'FOLD', color: const Color(0xFF9B1C24)),
    'check' => (label: 'CHECK', color: const Color(0xFF2E7D5B)),
    'call' => (label: 'CALL', color: const Color(0xFF1B6FD8)),
    'bet' => (label: 'BET', color: const Color(0xFFE07A18)),
    'raise' => (label: 'RAISE', color: accent),
    'allin' => (label: 'ALL-IN ${money(amount)}', color: const Color(0xFF9B1BD8)),
    _ => (label: '', color: Colors.black),
  };
}

/// Raspored stola: gde su sedišta, ulozi i pot (isti proračun za crtanje i za animacije).
class _Layout {
  final Size size;
  final int n;
  final int base;
  final int mySeat;
  final bool wide;
  _Layout(this.size, this.n, this.base, this.mySeat, {this.wide = false});

  double get w => size.width;
  double get h => size.height;
  // Sto je pomeren naviše (prazan prostor gore), da dole ima mesta za svoju pločicu i oznake.
  Offset get center => Offset(w / 2, h * (wide ? 0.45 : 0.44));
  // Karte na stolu (+20%).
  double get cardW => min(min(w, h) > 600 ? 55.0 : 43.7, (w * 0.68) / 5 - 4);
  double get boardTop => center.dy - cardW * 1.4 / 2 - 6;
  double get potTop => boardTop - (min(w, h) > 600 ? 48 : 38);

  /// Gomila žetona sakupljenog pota (ispod karata, kao u velikim aplikacijama).
  /// Žetoni glavnog pota: iznad karata, odmah iznad natpisa POT.
  Offset get pile => Offset(center.dx, potTop - 10);

  /// Telefon: mesta po ivicama stola (levo i desno po visini, gore dva), da svih 9 igrača stane.
  /// (x, y) od -1 do 1; redom od mene (dole) u smeru kazaljke.
  static const _phoneSlots = <int, List<(double, double)>>{
    9: [(-1, 0.64), (-1, 0.2), (-0.96, -0.42), (-0.42, -0.98), (0.42, -0.98), (0.96, -0.42), (1, 0.2), (1, 0.64)],
    8: [(-1, 0.62), (-1, 0.18), (-0.9, -0.5), (0, -1), (0.9, -0.5), (1, 0.18), (1, 0.62)],
    7: [(-1, 0.5), (-1, -0.3), (-0.42, -0.96), (0.42, -0.96), (1, -0.3), (1, 0.5)],
    6: [(-1, 0.42), (-1, -0.45), (0, -1), (1, -0.45), (1, 0.42)],
    5: [(-1, 0.3), (-0.6, -0.85), (0.6, -0.85), (1, 0.3)],
    4: [(-1, 0.0), (0, -1), (1, 0.0)],
    3: [(-0.8, -0.6), (0.8, -0.6)],
    2: [(0, -1)],
  };

  Offset seat(int i) {
    final k = (i - base + n) % n;
    final angle = pi / 2 + 2 * pi * k / n;
    final slots = wide ? null : _phoneSlots[n];
    late Offset p;
    if (slots != null && k > 0) {
      final (sx, sy) = slots[k - 1];
      // Nagnut sto: gore (dalje) je uži nego dole.
      final narrow = 1 - 0.14 * (-sy).clamp(0.0, 1.0);
      p = center + Offset(w * 0.39 * narrow * sx, h * 0.40 * sy);
    } else {
      // Sto je nagnut kao na GG: gornja (dalja) strana je uža, donja (bliža) šira.
      final widen = 1 + 0.07 * sin(angle);
      p = center + Offset(w * (wide ? 0.43 : 0.39) * widen * cos(angle), h * (wide ? 0.37 : 0.40) * sin(angle));
    }
    if (i == mySeat) return p;
    // Telefon: mesta su već raspoređena oko karata na stolu.
    if (slots != null) {
      final plate0 = 52.0;
      // Otvorene karte gornjih igrača ne smeju preko gornje trake (pomeri igrača naniže koliko treba).
      final top = othersTop(p, 41.0);
      final dy = top < 2 ? 2 - top : 0.0;
      return Offset(p.dx.clamp(plate0 + 2, w - plate0 - 2), p.dy + dy);
    }
    // Pločica igrača sa strane ne sme da izađe van ekrana.
    final plate = wide ? 64.0 : 52.0;
    p = Offset(p.dx.clamp(plate + 2, w - plate - 2), p.dy);
    // Igrač sa strane čije karte (poleđine) zalaze u karte na stolu: spusti ga tačno toliko
    // da se ne dodiruju (računa se puna tabla od 5 karata, da raspored ne skače).
    final a = wide ? 54.0 : 41.0;
    final boardHalf = 5 * (cardW + 4) / 2 + 4;
    final boardBottom = boardTop + cardW * 1.4 + 4;
    final half = faceCardW(2) * 1.86 / 2 + 4;
    final left = min(p.dx - a / 2 - 6, p.dx - half), right = max(p.dx + (a + 50) / 2 + 2, p.dx + half), top = othersTop(p, a);
    final overlapsX = right > center.dx - boardHalf && left < center.dx + boardHalf;
    if (overlapsX && top < boardBottom + 4 && p.dy > boardTop) return Offset(p.dx, p.dy + (boardBottom + 4 - top));
    return p;
  }

  Offset dir(int i) {
    final d = center - seat(i);
    return d / max(1.0, d.distance);
  }

  /// Dugme dilera (zauzima malo mesta, ulog ne sme preko njega).
  int button = -1;

  /// Koliko karata je na stolu (za raspored uloga).
  int boardCount = 5;

  /// Visina onoga što stoji odmah ispod karata (drugi sto, bomb pot, sporedni potovi).
  double belowBoard = 0;

  /// Pola širine tog pojasa ispod karata.
  double belowBoardHalf = 0;

  /// Visina natpisa na stolu (znak kluba i podaci o igri/turniru), da ulozi ne padaju preko njega.
  double feltHeight = 0;
  Rect get feltRect {
    final top = boardTop + cardW * 1.4 + (wide ? 32 : 40);
    final half = min(w * 0.34, 170.0);
    return Rect.fromLTRB(center.dx - half, top, center.dx + half, top + feltHeight);
  }

  /// Veličina gomile uloga za svakog igrača koji ima ulog (žetoni + iznos).
  Map<int, Size> betSizes = {};

  double get myAvatar => wide ? 87.0 : 67.0;

  /// Otvorene karte (svoje i tuđe na kraju/all-in): iste veličine kao moje.
  double faceCardW(int count) => (count > 2 ? 28.0 : 34.0) * (myAvatar / 50) * 0.86 * (wide ? 1.2 : 1.14);

  /// Gornja ivica tuđeg sedišta: mesto i za velike otvorene karte iznad pločice.
  double othersTop(Offset p, double a) => min(p.dy - a / 2 - 16, p.dy + (a + 8) / 2 - 6 - faceCardW(2) * 1.4 - 6);
  double myTop(Offset p) => min(p.dy - myAvatar / 2, h - myAvatar - (wide ? 80 : 100));

  /// Prostor koji zauzima sedište: avatar sa kartama i pločica sa oznakom ispod.
  List<Rect> seatRects(int i) {
    final p = seat(i);
    if (i == mySeat) {
      final a = myAvatar, top = myTop(p);
      return [Rect.fromLTRB(p.dx - (a + 50) / 2, top - 8 - _myCardsLift(a), p.dx + (a + 50) / 2, top + a + 8 + (wide ? 66 : 54))];
    }
    final a = wide ? 54.0 : 41.0;
    final half = wide ? 64.0 : 52.0;
    return [
      Rect.fromLTRB(min(p.dx - a / 2 - 6, p.dx - faceCardW(2) * 0.93 - 4), othersTop(p, a),
          max(p.dx + (a + 50) / 2 + 2, p.dx + faceCardW(2) * 0.93 + 4), p.dy + a / 2),
      Rect.fromLTRB(p.dx - half, p.dy + a / 2 - 6, p.dx + half, p.dy + a / 2 + (wide ? 70 : 53)),
    ];
  }

  /// Sredina stola: žetoni pota, natpis POT i zajedničke karte.
  List<Rect> get middleRects {
    // Samo karte koje su stvarno na stolu (prazan sto ne zauzima mesto ulozima).
    final boardW = boardCount * (cardW + 4);
    final pileHalf = wide ? 36.0 : 28.0;
    return [
      Rect.fromLTRB(center.dx - pileHalf, potTop - (wide ? 40 : 34), center.dx + pileHalf, potTop),
      Rect.fromLTRB(center.dx - 74, potTop - 2, center.dx + 74, boardTop),
      if (boardCount > 0)
        Rect.fromLTRB(center.dx - boardW / 2 - 4, boardTop, center.dx + boardW / 2 + 4, boardTop + cardW * 1.4 + 4),
      if (belowBoard > 0)
        Rect.fromLTRB(center.dx - belowBoardHalf, boardTop + cardW * 1.4 + 4, center.dx + belowBoardHalf, boardTop + cardW * 1.4 + 8 + belowBoard),
    ];
  }

  static const _defaultBet = Size(64, 44);

  /// Pravac od igrača ka sredini stola (za mene pravo gore, iznad mojih karata).
  Offset betDir(int i) {
    final from = i == mySeat ? Offset(seat(i).dx, myTop(seat(i))) : seat(i);
    // Telefon: ulog ide pravo ka sredini stola (igrači sa strane ga imaju odmah pored sebe).
    final d = (wide || i == mySeat ? pile : center) - from;
    return d / max(1.0, d.distance);
  }

  /// Za raspored uloga: samo avatar i pločica tuđeg igrača (bez mesta za velike otvorene karte).
  List<Rect> betSeatRects(int i) {
    if (wide || i == mySeat) return seatRects(i);
    final p = seat(i);
    const a = 41.0, half = 52.0;
    return [Rect.fromLTRB(p.dx - half, p.dy - a / 2 - 16, p.dx + half, p.dy + a / 2 + 53)];
  }

  /// Centri gomila uloga: svaka na liniji od igrača ka sredini stola, odmah ispred
  /// njega, tako da ne dodiruje nijedno sedište, karte na stolu, pot, dugme dilera
  /// ni tuđi ulog. Veličina gomile se računa iz iznosa, pa ni veliki ulog ne seče ništa.
  late final Map<int, Offset> _bets = () {
    final out = <int, Offset>{};
    final blocked = <Rect>[
      for (var k = 0; k < n; k++) ...betSeatRects(k).map((r) => r.inflate(3)),
      ...middleRects,
      if (button >= 0) Rect.fromCenter(center: dealer(button), width: 26, height: 26),
    ];
    // Prvo ja, pa ostali redom.
    final order = [if (mySeat >= 0) mySeat, for (var k = 0; k < n; k++) if (k != mySeat) k];
    for (final i in order) {
      final sz = betSizes[i] ?? _defaultBet;
      final p = seat(i);
      final d = betDir(i);
      final from = i == mySeat ? Offset(p.dx, myTop(p)) : p;
      Rect box(Offset c) => Rect.fromCenter(center: c, width: sz.width + 6, height: sz.height + 4);
      bool inside(Rect r) => r.left > 2 && r.right < w - 2 && r.top > 2 && r.bottom < h - 2;
      // Samo na liniji igrač → pot (bez skretanja levo-desno): prvo mesto ispred igrača
      // koje ništa ne dodiruje; ako ga nema pre pota, prvo mesto van sedišta (bilo čijeg).
      final own = betSeatRects(i).map((r) => r.inflate(3)).toList();
      final seatsAll = [for (var k = 0; k < n; k++) ...betSeatRects(k).map((r) => r.inflate(3))];
      final reach = max((pile - from).distance, (center - from).distance);
      Offset? found;
      for (var dist = 0.0; dist < reach && found == null; dist += 2) {
        final c = from + d * dist;
        final r = box(c);
        if (inside(r) && !blocked.any(r.overlaps)) found = c;
      }
      if (found == null) {
        // Nema potpuno slobodnog mesta (uzan telefon, igrač sa strane): mesto na liniji koje
        // ne dodiruje nijedno sedište i najmanje prelazi preko karata/pota.
        // Najgore je preći preko karata na stolu (indeks 2), pa tek onda preko pota i natpisa.
        final mids = middleRects;
        double over(Rect r) {
          var a = 0.0;
          for (var k = 0; k < mids.length; k++) {
            final x = r.intersect(mids[k]);
            if (x.width > 0 && x.height > 0) a += x.width * x.height * (k == 2 ? 10 : 1);
          }
          return a;
        }
        final others = [
          ...seatsAll,
          if (button >= 0) Rect.fromCenter(center: dealer(button), width: 26, height: 26),
          // Ulozi koji su već postavljeni (da se gomile ne preklapaju).
          for (final e in out.entries)
            if (betSizes.containsKey(e.key))
              Rect.fromCenter(center: e.value, width: (betSizes[e.key]!.width) + 6, height: betSizes[e.key]!.height + 4),
        ];
        var bestOver = double.infinity;
        for (var dist = 0.0; dist < reach; dist += 2) {
          final c = from + d * dist;
          final r = box(c);
          if (!inside(r) || others.any(r.overlaps)) continue;
          final o = over(r);
          if (o < bestOver - 0.5) {
            bestOver = o;
            found = c;
          }
        }
      }
      for (var dist = 0.0; dist < 320 && found == null; dist += 2) {
        final c = from + d * dist;
        if (!own.any(box(c).overlaps)) found = c;
      }
      final c = found ?? from + d * 80;
      out[i] = c;
      if (betSizes.containsKey(i)) blocked.add(box(c));
    }
    return out;
  }();

  /// Centar gomile uloga igrača i.
  Offset bet(int i) => _bets[i] ?? seat(i);

  Offset dealer(int i) {
    final p = seat(i);
    // Oznaka D je u gornjem levom uglu pločice (pločica je već zauzeta mesta).
    if (i == mySeat) return Offset(p.dx - (wide ? 64 : 52), myTop(p) + myAvatar);
    final a = wide ? 54.0 : 41.0;
    return Offset(p.dx - (wide ? 64 : 52), p.dy + a / 2);
  }
}

/// Karta stola sa animacijom kao na GG: flop padne kao špil, raširi se i okrene;
/// turn i river padnu licem nadole i okrenu se.
class _BoardCard extends StatefulWidget {
  final String code;
  final double width;
  final int index;
  final bool spread;
  final bool highlight;
  final bool dim;
  const _BoardCard({
    required this.code,
    required this.width,
    required this.index,
    required this.spread,
    this.highlight = false,
    this.dim = false,
  });

  @override
  State<_BoardCard> createState() => _BoardCardState();
}

class _BoardCardState extends State<_BoardCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.spread ? 1050 : 750),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slot = widget.width + 4;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value;
        double seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);
        // 1) pad sa špila (licem nadole), 2) flop se raširi, 3) okretanje
        final drop = Curves.easeOutCubic.transform(seg(0, widget.spread ? 0.28 : 0.4));
        final spread = widget.spread ? Curves.easeInOutCubic.transform(seg(0.3, 0.62)) : 1.0;
        final flip = seg(widget.spread ? 0.64 : 0.45, 1);
        final dx = widget.spread ? -widget.index * slot * (1 - spread) : 0.0;
        final dy = -36 * (1 - drop);
        final showFace = flip >= 0.5;
        final sx = showFace ? Curves.easeOut.transform((flip - 0.5) * 2) : 1 - Curves.easeIn.transform(flip * 2);
        return Opacity(
          opacity: drop,
          child: Transform.translate(
            offset: Offset(dx, dy),
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(max(0.02, sx), 1, 1),
              child: showFace
                  ? PlayingCard(code: widget.code, width: widget.width, highlight: widget.highlight, dim: widget.dim)
                  : PlayingCard(width: widget.width),
            ),
          ),
        );
      },
    );
  }
}

/// Veliki zlatni WIN preko slike pobednika (iskoči, pa blago pulsira).
class _WinBadge extends StatefulWidget {
  final double size;
  const _WinBadge({required this.size});

  @override
  State<_WinBadge> createState() => _WinBadgeState();
}

class _WinBadgeState extends State<_WinBadge> with TickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..forward();
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pop.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.size;
    return AnimatedBuilder(
      animation: Listenable.merge([_pop, _pulse]),
      builder: (_, __) {
        final pop = Curves.elasticOut.transform(_pop.value);
        final glow = 8 + 14 * _pulse.value;
        return IgnorePointer(
          child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
            // Zlatni sjaj oko avatara
            Container(
              width: a + 14,
              height: a + 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: const Color(0xCCF2C14E), blurRadius: glow, spreadRadius: 2 + 3 * _pulse.value)],
              ),
            ),
            Transform.scale(
              scale: 0.2 + 0.8 * pop,
              child: Transform.rotate(
                angle: -0.08,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: a * 0.16, vertical: a * 0.04),
                  decoration: BoxDecoration(
                    gradient: goldGradient,
                    borderRadius: BorderRadius.circular(a * 0.2),
                    border: Border.all(color: const Color(0xFF5A3A08), width: 1.5),
                    boxShadow: [const BoxShadow(color: Colors.black87, blurRadius: 8), BoxShadow(color: const Color(0xAAF6E27A), blurRadius: glow)],
                  ),
                  child: Text('WIN',
                      style: TextStyle(
                          fontFamily: 'Cinzel',
                          fontWeight: FontWeight.w900,
                          fontSize: a * 0.36,
                          letterSpacing: 2,
                          color: const Color(0xFF2A1A05),
                          height: 1.1)),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }
}

/// Žetoni u letu: od uloga ka potu, ili od pota ka pobedniku.
class _Flight {
  final Key key;
  final Offset from;
  final Offset to;
  final String label;
  final int delayMs;
  final int amount;
  _Flight(this.from, this.to, this.label, this.amount, {this.delayMs = 0}) : key = UniqueKey();
}

/// Veliki ovalni sto preko celog ekrana. Igrač je uvek dole u sredini.
class _TableView extends StatefulWidget {
  final Json st;
  final Size size;
  final Money money;
  final List<Json> chat;
  final bool wide;

  /// Svoje karte prikaži poleđinom (podešavanje "Sakrij karte").
  final bool hideMine;
  final VoidCallback onTapMine;
  final void Function(int seat) onSit;

  /// Dodir na drugog igrača: beleška o njemu.
  final void Function(Json seat) onTapPlayer;
  const _TableView({
    super.key,
    required this.st,
    required this.size,
    required this.money,
    required this.chat,
    required this.onSit,
    required this.onTapMine,
    required this.onTapPlayer,
    this.wide = false,
    this.hideMine = false,
    this.active = true,
  });

  /// Sto je prikazan; sto u pozadini (drugi tab) pušta samo zvuk "tvoj potez".
  final bool active;

  @override
  State<_TableView> createState() => _TableViewState();
}

class _TableViewState extends State<_TableView> {
  /// Zvuk stola; sto u pozadini pušta samo "tvoj potez".
  void _play(String name, {double volume = 0.7}) {
    if (widget.active || name == 'turn') Sounds.play(name, volume: volume);
  }

  final List<_Flight> _flights = [];
  static const _flyMs = 450;

  // ---------- All-in: otkrivanje ulica jedna po jedna (kao na GG) ----------
  // Server odmah pošalje ceo sto i rezultat; aplikacija prvo pokaže karte igrača,
  // pa flop, turn i river sa pauzama, i tek onda ko je dobio.
  // Pauze moraju odgovarati serveru (RUNOUT_START_MS / RUNOUT_STREET_MS).
  static const _runoutStartMs = 1200;
  static const _runoutStreetMs = 2000;
  Json? _runoutBase; // stanje pre kraja ruke
  Json? _runoutFinal; // konačno stanje sa rezultatom
  int _reveal = 0; // koliko karata prvog stola je otkriveno
  int _reveal2 = 0; // drugi sto (run it twice)
  int _oddsBoard = 0; // za koliko karata stola se prikazuju šanse (menja se tek kad se nova karta okrene)
  final List<Timer> _runoutTimers = [];

  void _startRunout(Json a, Json b) {
    final res = b['result'] as Json;
    final from = res['runoutFrom'] as int;
    final board2 = res['board2'] as List?;
    _runoutBase = a;
    _runoutFinal = b;
    _reveal = from;
    _reveal2 = 0;
    _oddsBoard = from;
    var t = _runoutStartMs;
    void at(int ms, VoidCallback f) => _runoutTimers.add(Timer(Duration(milliseconds: ms), () {
          if (mounted && _runoutFinal != null) setState(f);
        }));
    for (final target in [3, 4, 5].where((x) => x > from)) {
      at(t, () {
        _reveal = target;
        _play('card', volume: 0.6);
      });
      // Novi procenat tek kad se karta okrene (do tada važi procenat pre te karte).
      at(t + (target == 3 ? 1050 : 750), () => _oddsBoard = target);
      t += _runoutStreetMs;
    }
    if (board2 != null) {
      for (final target in [3, 4, 5].where((x) => x > from)) {
        at(t, () {
          _reveal2 = target;
          _play('card', volume: 0.6);
        });
        t += _runoutStreetMs;
      }
    }
    // Posle poslednje karte: rezultat, WIN i žetoni ka pobedniku.
    _runoutTimers.add(Timer(Duration(milliseconds: t - _runoutStreetMs + 1300), () {
      if (mounted) _endRunout(effects: true);
    }));
  }

  void _endRunout({required bool effects}) {
    for (final t in _runoutTimers) {
      t.cancel();
    }
    _runoutTimers.clear();
    final base = _runoutBase, fin = _runoutFinal;
    _runoutBase = null;
    _runoutFinal = null;
    if (!mounted) return;
    setState(() {});
    if (effects && base != null && fin != null) {
      final result = fin['result'] as Json;
      final mySeat = fin['mySeat'] as int;
      final iWon = (result['pots'] as List).any((p) => (p['winners'] as List).any((w) => w['seat'] == mySeat));
      _play(iWon ? 'win' : 'chips', volume: iWon ? 0.8 : 0.5);
      _addFlights(_resultFlights(widget.st, 0), 0);
    }
  }

  /// Šta se prikazuje dok traje otkrivanje: karte igrača su otvorene, sto se otkriva postepeno,
  /// a stekovi, pot i rezultat ostaju kao pre kraja ruke.
  Json _display() {
    final fin = _runoutFinal;
    if (fin == null) return widget.st;
    final base = _runoutBase!;
    final res = fin['result'] as Json;
    final from = res['runoutFrom'] as int;
    final oldSeats = (base['seats'] as List).cast<Json?>();
    final newSeats = (fin['seats'] as List).cast<Json?>();
    final pot = (res['pots'] as List).fold<int>(0, (s, p) => s + (p['amount'] as int));
    return {
      ...fin,
      'board': (fin['board'] as List).take(_reveal).toList(),
      'runoutBoard2': res['board2'] == null ? null : (res['board2'] as List).take(max(_reveal2, from)).toList(),
      'ritFrom': from,
      'runoutOdds': _reveal2 > 0
          ? null
          : ((res['equity'] as List?) ?? const []).cast<Json>().where((e) => e['board'] == _oddsBoard).map((e) => e['odds']).firstOrNull,
      'result': null,
      // Glavni i sporedni potovi iz rezultata (drugi sto kod run it twice se ne broji posebno).
      'sidePots': _potsOf(res),
      'pot': pot,
      'collected': pot,
      'toAct': -1,
      'inProgress': true,
      'seats': [
        for (var i = 0; i < newSeats.length; i++)
          newSeats[i] == null
              ? null
              : <String, dynamic>{
                  ...newSeats[i]!,
                  'stack': _oldStack(oldSeats, i) ?? newSeats[i]!['stack'],
                  // Dok se otkriva sto, igrači u all-in-u i dalje imaju ALL-IN na pločici.
                  'allIn': i < oldSeats.length && oldSeats[i]?['allIn'] == true,
                  'inHand': i < oldSeats.length && oldSeats[i]?['inHand'] == true,
                  'bet': 0,
                },
      ],
    };
  }

  /// Iznosi potova iz rezultata; kod run it twice se polovine oba stola sabiraju.
  static List<int> _potsOf(Json res) {
    final all = (res['pots'] as List).cast<Json>();
    final r1 = [for (final p in all) if (p['run'] != 2) p['amount'] as int];
    final r2 = [for (final p in all) if (p['run'] == 2) p['amount'] as int];
    return [for (var k = 0; k < r1.length; k++) r1[k] + (k < r2.length ? r2[k] : 0)];
  }

  static Object? _oldStack(List<Json?> seats, int i) {
    if (i >= seats.length) return null;
    final s = seats[i];
    return s == null ? null : s['stack'];
  }

  @override
  void dispose() {
    for (final t in _runoutTimers) {
      t.cancel();
    }
    super.dispose();
  }

  /// Žetoni pota putuju do pobednika.
  List<_Flight> _resultFlights(Json b, int delay) {
    final result = b['result'] as Json?;
    if (result == null) return [];
    final lay = _layoutFor(b);
    final seats = (b['seats'] as List).cast<Json?>();
    final won = <int, int>{};
    for (final p in (result['pots'] as List)) {
      for (final win in (p['winners'] as List)) {
        won[win['seat'] as int] = (won[win['seat'] as int] ?? 0) + (win['amount'] as int);
      }
    }
    return [
      for (final e in won.entries)
        if (e.key < seats.length && seats[e.key] != null)
          _Flight(lay.pile, lay.seat(e.key), widget.money(e.value), e.value, delayMs: delay),
    ];
  }

  void _addFlights(List<_Flight> added, int delay) {
    if (added.isEmpty) return;
    setState(() => _flights.addAll(added));
    final keys = added.map((f) => f.key).toSet();
    Future.delayed(Duration(milliseconds: delay + _flyMs + 200), () {
      if (mounted) setState(() => _flights.removeWhere((f) => keys.contains(f.key)));
    });
  }

  bool _bombLabel(Json st) =>
      st['ritPending'] != true &&
      st['result'] == null &&
      st['closing'] != true &&
      (st['bombPot'] == true || (st['inProgress'] != true && st['nextBombIn'] == 1));

  List<int> _sidePots(Json st) {
    if (st['ritPending'] == true || st['result'] != null) return const [];
    final p = ((st['sidePots'] as List?) ?? const []).cast<int>();
    return p.length > 1 ? p : const [];
  }

  List<String>? _board2(Json st) => (((st['result'] as Json?)?['board2'] ?? st['runoutBoard2']) as List?)?.cast<String>();

  /// Šta sve stoji ispod karata (redom): drugi sto, oznaka bomb pota, sporedni potovi.
  double _belowBoard(Json st) {
    final cw = min(min(widget.size.width, widget.size.height) > 600 ? 55.0 : 46.0, (widget.size.width * 0.68) / 5 - 4);
    var h = 0.0;
    if (_board2(st) != null) h += cw * 1.4 + 6;
    if (_bombLabel(st)) h += widget.wide ? 26 : 22;
    final sp = _sidePots(st);
    if (sp.isNotEmpty) h += _sidePotsHeight(sp.length);
    return h;
  }

  double _sidePotsHeight(int n) {
    final perRow = widget.wide ? 5 : 3;
    final rows = (n + perRow - 1) ~/ perRow;
    return rows * (widget.wide ? 28.0 : 21.0) + 4;
  }

  /// Pola širine pojasa ispod karata (drugi sto, bomb pot, potovi).
  double _sidePotsHalf() => widget.wide ? widget.size.width * 0.38 : 112;

  double _belowBoardHalf(Json st) {
    final cw = min(min(widget.size.width, widget.size.height) > 600 ? 55.0 : 46.0, (widget.size.width * 0.68) / 5 - 4);
    var half = 0.0;
    if (_board2(st) != null) half = max(half, 5 * (cw + 4) / 2 + 4);
    if (_bombLabel(st)) half = max(half, widget.wide ? 80.0 : 70.0);
    if (_sidePots(st).isNotEmpty) half = max(half, _sidePotsHalf());
    return half;
  }

  _Layout _layoutFor(Json st) {
    final seats = (st['seats'] as List).cast<Json?>();
    final n = seats.length;
    final my = st['mySeat'] as int;
    final bb = st['bigBlind'] as int;
    return _Layout(widget.size, n, my >= 0 ? my : 0, my, wide: widget.wide)
      ..button = (st['button'] as int?) ?? -1
      ..boardCount = ((st['board'] as List?)?.length ?? 0)
      ..belowBoard = _belowBoard(st)
      ..belowBoardHalf = _belowBoardHalf(st)
      // Natpis na stolu: turnir ima više redova (na računaru bez znaka kluba).
      ..feltHeight = st['tournament'] != null
          ? (widget.wide ? 4 * 16.0 : min(widget.size.width, widget.size.height * 0.75) * 0.1 + 6 * 16.5)
          : (widget.wide ? 70.0 : 90.0)
      ..betSizes = {
        for (var i = 0; i < n; i++)
          if (((seats[i]?['bet'] as int?) ?? 0) > 0)
            i: _ChipPile.sizeOf(widget.money(seats[i]!['bet'] as int), seats[i]!['bet'] as int, bb, widget.wide),
      };
  }

  /// Zvuk za ono što se upravo desilo za stolom.
  void _playSounds(Json a, Json b) {
    final sameHand = a['handNo'] == b['handNo'];
    final mySeat = b['mySeat'] as int;
    // Nova ruka: deljenje karata.
    if (!sameHand && b['inProgress'] == true) {
      _play('card', volume: 0.6);
      if (b['toAct'] == mySeat && mySeat >= 0) Future.delayed(const Duration(milliseconds: 350), () => _play('turn'));
      return;
    }
    // Kraj ruke: pobeda (glasnije ako sam ja dobio).
    final result = b['result'] as Json?;
    if (result != null && a['result'] == null) {
      final iWon = (result['pots'] as List).any((p) => (p['winners'] as List).any((w) => w['seat'] == mySeat));
      _play(iWon ? 'win' : 'chips', volume: iWon ? 0.8 : 0.5);
      return;
    }
    // Novi potezi u ruci: check, fold ili žetoni.
    final oldActs = (a['actions'] as List?)?.length ?? 0;
    final acts = (b['actions'] as List?) ?? const [];
    if (sameHand && acts.length > oldActs) {
      final type = (acts.last as Json)['type'] as String?;
      switch (type) {
        case 'check':
          _play('check', volume: 0.6);
        case 'fold':
          _play('fold', volume: 0.5);
        case 'call' || 'bet' || 'raise' || 'allin' || 'straddle':
          _play('chips', volume: 0.6);
      }
    }
    // Nove karte na stolu.
    final oldBoard = (a['board'] as List?)?.length ?? 0;
    final board = (b['board'] as List?)?.length ?? 0;
    if (sameHand && board > oldBoard) Future.delayed(const Duration(milliseconds: 250), () => _play('card', volume: 0.6));
    // Na potezu sam.
    if (mySeat >= 0 && b['toAct'] == mySeat && (a['toAct'] != mySeat || !sameHand)) {
      Future.delayed(const Duration(milliseconds: 300), () => _play('turn'));
    }
  }

  @override
  void didUpdateWidget(covariant _TableView old) {
    super.didUpdateWidget(old);
    final a = old.st, b = widget.st;
    // Prikaz all-in-a je u toku: nova ruka ga prekida, ostale izmene samo pamtimo.
    if (_runoutFinal != null) {
      if (b['handNo'] != _runoutFinal!['handNo'] || b['result'] == null) {
        _endRunout(effects: false);
      } else {
        _runoutFinal = b;
        return;
      }
    }
    final res = b['result'] as Json?;
    final startRunout = res != null && a['result'] == null && res['runoutFrom'] != null && a['handNo'] == b['handNo'];
    if (!identical(a, b) && !startRunout) _playSounds(a, b);
    if (a['handNo'] != b['handNo'] && b['inProgress'] == true) return; // nova ruka: ništa ne leti
    final lay = _layoutFor(b);
    final oldLay = _layoutFor(a);
    final oldSeats = (a['seats'] as List).cast<Json?>();
    final streetEnded = a['inProgress'] == true && (a['street'] != b['street'] || b['inProgress'] != true);
    final added = <_Flight>[];
    var delay = 0;
    if (streetEnded) {
      // Kraj runde: ulozi svih igrača klize na sredinu stola.
      for (var i = 0; i < oldSeats.length; i++) {
        final bet = (oldSeats[i]?['bet'] as int?) ?? 0;
        if (bet > 0) added.add(_Flight(oldLay.bet(i), lay.pile, widget.money(bet), bet));
      }
      if (added.isNotEmpty) delay = _flyMs + 100;
    }
    if (startRunout) {
      // All-in: ulozi idu u pot, pa ulice jedna po jedna; rezultat tek posle.
      _addFlights(added, delay);
      _startRunout(a, b);
      return;
    }
    final result = b['result'] as Json?;
    if (result != null && a['result'] == null) {
      // Kraj ruke: pot putuje do pobednika.
      added.addAll(_resultFlights(b, delay));
    }
    _addFlights(added, delay);
  }

  /// Ruka je gotova, a za stolom nema dovoljno igrača za novu: sto se čisti
  /// (bez karata, pota i oznaka poteza) i čeka se drugi igrač.
  static bool waitingForPlayers(Json st) {
    if (st['inProgress'] == true || st['result'] != null) return false;
    final ready = (st['seats'] as List)
        .cast<Json?>()
        .where((s) => s != null && ((s['stack'] as int?) ?? 0) > 0 && s['sittingOut'] != true)
        .length;
    return ready < 2;
  }

  static Json _cleared(Json st) => {
        ...st,
        'board': const <String>[],
        'pot': 0,
        'collected': 0,
        'pots': const [],
        'seats': [
          for (final s in (st['seats'] as List).cast<Json?>())
            s == null ? null : <String, dynamic>{...s, 'cards': null, 'bet': 0, 'lastAct': null, 'bestHand': null, 'myShown': const []},
        ],
      };

  @override
  Widget build(BuildContext context) {
    final raw = _display();
    final idle = _runoutFinal == null && waitingForPlayers(raw);
    final st = idle ? _cleared(raw) : raw;
    final money = widget.money;
    final seats = (st['seats'] as List).cast<Json?>();
    final n = seats.length;
    final mySeat = st['mySeat'] as int;
    final lay = _layoutFor(st);
    final w = lay.w, h = lay.h;
    final app = context.read<AppState>();
    final seatW = widget.wide ? 124.0 : 88.0;

    final result = st['result'] as Json?;
    final won = <int, int>{};
    for (final p in (result?['pots'] as List? ?? [])) {
      for (final win in (p['winners'] as List)) {
        won[win['seat'] as int] = (won[win['seat'] as int] ?? 0) + (win['amount'] as int);
      }
    }
    final best = <String>{};
    for (final s in (result?['shown'] as List? ?? [])) {
      if (won.containsKey(s['seat'])) best.addAll((s['best'] as List).cast<String>());
    }
    final board = (st['board'] as List).cast<String>();
    final board2 = ((result?['board2'] ?? st['runoutBoard2']) as List?)?.cast<String>();
    // Koliko karata je bilo na stolu pre all-in-a (zajedničke za oba stola).
    final ritFrom = ((result?['runoutFrom'] ?? st['ritFrom']) as int?) ?? 0;
    // All-in: šanse za pobedu za trenutni broj karata na stolu.
    final odds = st['runoutOdds'] as Map?;
    double? equityOf(int seat) => (odds?['$seat'] as num?)?.toDouble();
    final maxEquity = odds == null || odds.isEmpty ? null : odds.values.map((v) => (v as num).toDouble()).reduce(max);
    final cardW = lay.cardW;
    final boardTop = lay.boardTop;
    final collected = (st['collected'] as int?) ?? 0;
    // Dok žetoni lete ka sredini, gomila pota još pokazuje stari iznos.
    final flyingIn = _flights.any((f) => f.to == lay.pile);

    final children = <Widget>[
      // Sto: zlatna linija, kožna ivica, zlatna linija i bordo čoja
      Positioned(
        // Nagib skraćuje sto po visini, pa je pre nagiba viši (gornja ivica ostaje kod gornjih igrača).
        left: w * 0.02,
        // Telefon: jači nagib, pa je sto pre nagiba viši (donja ivica ostaje ista, gornja kod gornjih igrača).
        top: -h * (widget.wide ? 0.07 : 0.295),
        width: w * 0.96,
        height: h * (widget.wide ? 0.93 : 1.19),
        // Nagib stola (perspektiva): dalja strana se smanjuje, kao na GG.
        child: Transform(
          alignment: Alignment.bottomCenter,
          // Telefon: jači nagib (sto kao da leži ispred igrača).
          transform: Matrix4.identity()
            ..setEntry(3, 2, widget.wide ? 0.0011 : 0.0014)
            ..rotateX(widget.wide ? -0.22 : -0.30),
          child: Container(
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(w),
            gradient: goldGradient,
            boxShadow: const [BoxShadow(color: Colors.black, blurRadius: 30, spreadRadius: 4)],
          ),
          child: Container(
            padding: EdgeInsets.all(min(w, h) * 0.028),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(w),
              gradient: const LinearGradient(
                  colors: [Color(0xFF3A2A1E), Color(0xFF140D09)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
            ),
            child: Container(
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(w), gradient: goldGradient),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(w),
                  gradient: const RadialGradient(colors: [feltLight, felt, feltDark], stops: [0, 0.65, 1], radius: 0.9),
                ),
              ),
            ),
          ),
        ),
        ),
      ),
      // Znak kluba i podaci o igri na čoji (ispod pota)
      Positioned(
        left: 0,
        right: 0,
        // Znak kluba i podaci o stolu ispod karata na stolu (i ispod rezultata ruke).
        // Računar: podignuto i malo manje, da natpis ne bude ispod mojih karata.
        top: lay.boardTop + lay.cardW * 1.4 + (widget.wide ? 32 : 40),
        child: IgnorePointer(child: _FeltInfo(st: st, w: min(w, h * 0.75) * (widget.wide ? 0.72 : 1), logoOnly: true, wide: widget.wide)),
      ),
      // POT iznad karata
      Positioned(
        left: 0,
        right: 0,
        top: lay.potTop,
        child: Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: (st['pot'] as int) > 0 ? 1 : 0,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: widget.wide ? 18 : 12, vertical: widget.wide ? 5 : 3),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF1C130D), Color(0xFF0A0706)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: gold, width: 1.5),
                boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 8)],
              ),
              child: GoldText('POT: ${money(st['pot'])}',
                  style: TextStyle(fontSize: widget.wide ? 16 : 12, fontWeight: FontWeight.w800)),
            ),
          ),
        ),
      ),
      // Karte na stolu: svaka nova karta "padne" na sto
      if (board2 == null)
        Positioned(
          left: 0,
          right: 0,
          top: boardTop,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var k = 0; k < board.length; k++)
                Padding(
                  key: ValueKey('board-${st['handNo']}-${board[k]}'),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _BoardCard(
                    code: board[k],
                    width: cardW,
                    index: k,
                    // Flop (prve tri karte zajedno) se raširi iz špila; turn i river se samo okrenu.
                    spread: k < 3,
                    highlight: best.contains(board[k]),
                    dim: best.isNotEmpty && !best.contains(board[k]),
                  ),
                ),
            ],
          ),
        )
      else
        // Run it twice (kao na GG): zajedničke karte u sredini, karte 1. stola malo iznad,
        // karte 2. stola malo ispod, na istim mestima (nema duplih karata).
        for (final (k, code, run) in [
          for (var k = 0; k < board.length; k++) (k, board[k], k < ritFrom ? 0 : 1),
          for (var k = ritFrom; k < board2.length; k++) (k, board2[k], 2),
        ])
          Positioned(
            key: ValueKey('rit-${st['handNo']}-$run-$code'),
            left: w / 2 - 5 * (cardW + 4) / 2 + k * (cardW + 4) + 2,
            top: boardTop + (run == 0 ? cardW * 0.7 + 3 : run == 1 ? 0 : cardW * 1.4 + 6),
            child: _BoardCard(
              code: code,
              width: cardW,
              index: k,
              spread: k < 3,
              highlight: best.contains(code),
              dim: best.isNotEmpty && !best.contains(code),
            ),
          ),
      // Sakupljeni pot: gomila žetona i iznos ispod karata
      // Žetoni glavnog pota iznad natpisa POT (iznos piše na natpisu)
      if (collected > 0 && !flyingIn)
        Positioned(
          left: lay.pile.dx - 50,
          // Žetoni rastu naviše od natpisa POT (visoka gomila ne prekriva iznos).
          bottom: h - lay.potTop + 2,
          width: 100,
          child: Center(child: ChipStacks(amount: collected, bigBlind: st['bigBlind'] as int, chipSize: widget.wide ? 21 : 16)),
        ),
      // Run it twice: diler pita igrače u all-in-u; svi za stolom vide ko je šta odgovorio.
      if (st['ritPending'] == true)
        Positioned(
          left: 0,
          right: 0,
          top: (board.isEmpty ? boardTop - 4 : boardTop + cardW * 1.4 + 6),
          child: Center(child: _RitPanel(st: st, wide: widget.wide)),
        ),
      // Bomb pot (ruka u toku) ili najava da je sledeća ruka bomb pot.
      if (_bombLabel(st))
        Positioned(
          left: 0,
          right: 0,
          top: boardTop + cardW * 1.4 + 8 + (board2 != null ? cardW * 1.4 + 6 : 0),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              decoration: BoxDecoration(
                gradient: redGradient,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: gold.withOpacity(0.7)),
              ),
              child: Text(st['bombPot'] == true ? '💣 BOMB POT' : tr('💣 Next hand: BOMB POT', '💣 Sledeća ruka: BOMB POT'),
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: widget.wide ? 13 : 11, letterSpacing: 1)),
            ),
          ),
        ),
      // Glavni i sporedni potovi (kad ih ima više): ispod karata, koliko god ih ima.
      if (_sidePots(st).isNotEmpty)
        Positioned(
          // Telefon: uzak pojas između velikih karata igrača sa strane (po tri pota u redu).
          left: w / 2 - _sidePotsHalf(),
          right: w / 2 - _sidePotsHalf(),
          top: boardTop +
              cardW * 1.4 +
              8 +
              (board2 != null ? cardW * 1.4 + 6 : 0) +
              (_bombLabel(st) ? (widget.wide ? 26 : 22) : 0),
          child: Center(child: _SidePots(pots: _sidePots(st), money: money, wide: widget.wide)),
        ),
      if (result != null || st['closing'] == true)
        Positioned(
          left: 0,
          right: 0,
          top: boardTop + cardW * 1.4 + 6 + (board2 != null ? cardW * 1.4 + 6 : 0),
          child: Center(
            child: result != null
                ? _ResultText(result: result, money: money, wide: widget.wide)
                : Text(tr('Table closes after this hand.', 'Sto se zatvara posle ove ruke.'), style: const TextStyle(color: gold, fontSize: 12)),
          ),
        ),
    ];

    // Ulozi, dugme i poruke crtaju se posle igrača, da ih pločice ne prekriju.
    final overlays = <Widget>[];
    for (var i = 0; i < n; i++) {
      final s = seats[i];
      final p = lay.seat(i);
      if (s == null) {
        // Za turnirski sto se ne seda (igrače raspoređuje turnir).
        if (mySeat >= 0 || st['tournament'] != null) continue;
        children.add(Positioned(
          left: p.dx - 27,
          top: p.dy - 27,
          child: GestureDetector(
            onTap: () => widget.onSit(i),
            child: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1B1D21),
                border: Border.all(color: Colors.white24, width: 1.5),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.keyboard_double_arrow_down, size: 16, color: Colors.white70),
                Text(tr('Sit', 'Sedi'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ));
        continue;
      }
      final isMe = i == mySeat;
      final bet = s['bet'] as int;
      if (bet > 0) {
        // Ulog "doklizi" od igrača do svog mesta ispred njega.
        final target = lay.bet(i);
        overlays.add(TweenAnimationBuilder<Offset>(
          key: ValueKey('bet-${st['handNo']}-${st['street']}-$i'),
          tween: Tween(begin: p, end: target),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
          builder: (_, o, child) {
            final sz = lay.betSizes[i] ?? _Layout._defaultBet;
            return Positioned(
              left: o.dx - sz.width / 2 - 20,
              top: o.dy - sz.height / 2,
              width: sz.width + 40,
              height: sz.height,
              child: Center(child: child),
            );
          },
          child: _ChipPile(text: money(bet), amount: bet, bigBlind: st['bigBlind'] as int, big: widget.wide),
        ));
      }
      // Poslednja poruka igrača iz chata (do 6 sekundi) iznad njegovog avatara.
      final recent = widget.chat.lastWhere(
        (m) => m['userId'] == s['userId'] && app.serverNow - (m['at'] as int) < 6000,
        orElse: () => const {},
      );
      if (recent.isNotEmpty) {
        // Oblačić iznad i sa strane karata igrača (ka sredini stola), da ne prekriva karte.
        final av = widget.wide ? (isMe ? 87.0 : 54.0) : (isMe ? 67.0 : 41.0);
        final toLeft = p.dx > w * 0.62;
        final bw = widget.wide ? 230.0 : 160.0;
        final cardsTop = p.dy - av / 2 - (isMe ? av * 0.75 : av * 0.45);
        overlays.add(Positioned(
          left: toLeft ? null : (p.dx + av * 0.55).clamp(4.0, w - bw - 4),
          right: toLeft ? (w - (p.dx - av * 0.55)).clamp(4.0, w - bw - 4) : null,
          bottom: h - max(cardsTop + 14, 40.0),
          width: bw,
          child: IgnorePointer(
            child: Align(
              alignment: toLeft ? Alignment.bottomRight : Alignment.bottomLeft,
              child: _ChatBubble(text: recent['text'] as String, tailRight: toLeft, wide: widget.wide),
            ),
          ),
        ));
      }
      // Vreme za potez: prvo osnovno vreme, pa TIME (dodatno vreme).
      double? timeLeft;
      int? bankLeft;
      final deadline = st['deadline'] as int?;
      final bankAt = st['timeBankAt'] as int?;
      if (st['toAct'] == i && deadline != null) {
        final now = app.serverNow;
        if (bankAt != null && now < bankAt) {
          timeLeft = ((bankAt - now) / ((st['actionSeconds'] as int) * 1000)).clamp(0.0, 1.0);
        } else {
          final bankMs = ((st['timeBankSeconds'] as num?) ?? 30) * 1000;
          timeLeft = ((deadline - now) / bankMs).clamp(0.0, 1.0);
          bankLeft = ((deadline - now) / 1000).ceil().clamp(0, 999);
        }
      }
      // Sedište je centrirano na avatar; svoje malo podignuto da stane cela pločica.
      // Svoj igrač je 15 % veći, ostali 15 % manji (svako na svom telefonu vidi sebe većeg).
      final avatarSize = widget.wide ? (isMe ? 87.0 : 54.0) : (isMe ? 67.0 : 41.0);
      final topY = isMe ? min(p.dy - avatarSize / 2, h - avatarSize - 56) : p.dy - avatarSize / 2;
      // Oznaka da imam belešku o ovom igraču (gore levo od avatara).
      if (!isMe && app.notes.containsKey(s['userId'])) {
        overlays.add(Positioned(
          left: p.dx - avatarSize / 2 - 10,
          top: topY - 6,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(color: const Color(0xFFE0B341), shape: BoxShape.circle, border: Border.all(color: Colors.black54)),
              child: const Icon(Icons.edit_note, size: 14, color: Colors.black),
            ),
          ),
        ));
      }
      // Bounty turnir: koliko vredi glava ovog igrača (uvek vidljivo za stolom).
      final head = ((st['tournament'] as Json?)?['heads'] as Map?)?[s['userId']] as num?;
      children.add(Positioned(
        left: p.dx - seatW / 2,
        top: topY,
        width: seatW,
        child: _SeatView(
          seat: s,
          isMe: isMe,
          bounty: head != null && head > 0 ? head.toInt() : null,
          hideCards: isMe && widget.hideMine,
          onTap: () => widget.onTapPlayer(s),
          avatarSize: avatarSize,
          won: won[i],
          timeLeft: timeLeft,
          timeBankLeft: bankLeft,
          best: best,
          money: money,
          // D, SB, BB u gornjem levom uglu pločice
          faceCardW: lay.faceCardW,
          // Velike otvorene karte igrača uz ivicu: pomeri ih ka sredini da ne izađu iz ekrana.
          faceDx: () {
            final c = ((s['cards'] as List?) ?? const []).length;
            if (c == 0) return 0.0;
            final cw = lay.faceCardW(c);
            final half = (cw + (c - 1) * cw * 0.86) / 2 + 3;
            if (p.dx - half < 4) return 4 - (p.dx - half);
            if (p.dx + half > w - 4) return (w - 4) - (p.dx + half);
            return 0.0;
          }(),
          badges: [
            if (st['button'] == i) 'D',
            if (st['inProgress'] == true && st['sbSeat'] == i) 'SB',
            if (st['inProgress'] == true && st['bbSeat'] == i) 'BB',
          ],
          equity: equityOf(i),
          equityLeader: equityOf(i) != null && equityOf(i) == maxEquity,
          handName: (result?['shown'] as List?)
              ?.cast<Json>()
              .where((x) => x['seat'] == i)
              .map((x) => x['handName'] as String)
              .firstOrNull,
        ),
      ));
    }

    // Žetoni u letu
    for (final f in _flights) {
      overlays.add(TweenAnimationBuilder<double>(
        key: f.key,
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: f.delayMs + _flyMs),
        builder: (_, t, child) {
          final delayFrac = f.delayMs / (f.delayMs + _flyMs);
          final u = Curves.easeInOut.transform(((t - delayFrac) / (1 - delayFrac)).clamp(0.0, 1.0));
          final o = Offset.lerp(f.from, f.to, u)!;
          return Positioned(
              left: o.dx - 70,
              top: o.dy - 40,
              width: 140,
              height: 80,
              child: Opacity(opacity: t < delayFrac ? 0 : 1, child: Center(child: child)));
        },
        child: _ChipPile(text: f.label, amount: f.amount, bigBlind: st['bigBlind'] as int, big: widget.wide),
      ));
    }

    final tourInfo = st['tournament'] as Json?;
    if (tourInfo?['onBreak'] == true && st['inProgress'] != true && st['result'] == null) {
      // Pauza turnira: ruke se ne dele do kraja pauze.
      children.add(Positioned(
        left: 0,
        right: 0,
        top: lay.boardTop - 6,
        child: Center(
          child: IgnorePointer(
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: widget.wide ? 26 : 18, vertical: widget.wide ? 14 : 10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: gold.withOpacity(0.7), width: 1.3),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                GoldText('BREAK', style: TextStyle(fontSize: widget.wide ? 20 : 16, fontWeight: FontWeight.w900, letterSpacing: 2)),
                const SizedBox(height: 4),
                Text('${tr('Play resumes in', 'Igra se nastavlja za')} ${clockLeft((tourInfo!['breakEndsAt'] as num?)?.toInt(), app.serverNow)}',
                    style: TextStyle(fontSize: widget.wide ? 14 : 12, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ),
      ));
    } else if (idle && (st['seats'] as List).any((x) => x != null)) {
      children.add(Positioned(
        left: 0,
        right: 0,
        top: lay.boardTop - 6,
        child: const Center(child: IgnorePointer(child: _WaitingBadge())),
      ));
    }
    return Stack(clipBehavior: Clip.none, children: [...children, ...overlays]);
  }
}

/// Gomila pravih žetona sa iznosom ispod (ulog igrača ili pot na sredini).
class _ChipPile extends StatelessWidget {
  final String text;
  final int amount;
  final int bigBlind;
  final bool big;
  const _ChipPile({required this.text, required this.amount, required this.bigBlind, this.big = false});

  /// Približna veličina gomile sa natpisom (za raspored uloga oko stola).
  static Size sizeOf(String text, int amount, int bigBlind, bool big) {
    final chips = chipStacksSize(amount, bigBlind, big ? 19 : 13.5);
    final labelW = text.length * (big ? 8.6 : 7.6) + 16;
    return Size(max(chips.width, labelW), chips.height + 2 + (big ? 21 : 18.5));
  }

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ChipStacks(amount: amount, bigBlind: bigBlind, chipSize: big ? 19 : 13.5),
      const SizedBox(height: 2),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: gold.withOpacity(0.35), width: 0.8),
        ),
        child: Text(text, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: big ? 13 : 11.5)),
      ),
    ]);
  }
}

/// Natpis na čoji: znak kluba, naziv stola i pravila igre.
class _FeltInfo extends StatelessWidget {
  final Json st;
  final double w;
  /// Na računaru su podaci o stolu u kartici gore levo, pa se na čoji vidi samo znak kluba.
  final bool logoOnly;
  /// Računar: ispod mojih karata je malo mesta, pa bez znaka kluba i bez reda sa mestom (piše u kartici gore levo).
  final bool wide;
  const _FeltInfo({required this.st, required this.w, this.logoOnly = false, this.wide = false});

  /// Turnir: šta piše na stolu (kao na velikim sajtovima). Pre kraja kasne prijave: koliko još traje,
  /// fond i broj ulaza; posle: koliko igrača do nagrada, sledeća nagrada i skok nagrade, moje mesto.
  static List<String> tourLines(Json t, int now) {
    String left(num? at) => at == null ? '' : clockLeft(at.toInt(), now);
    final lines = <String>[t['name'] as String? ?? ''];
    final ante = (t['ante'] as num? ?? 0) > 0 ? ' (${chips(t['ante'])})' : '';
    if (t['onBreak'] == true) {
      lines.add(tr('Break · ${left(t['breakEndsAt'] as num?)}', 'Pauza · još ${left(t['breakEndsAt'] as num?)}'));
    } else {
      final next = t['levelEndsAt'] != null ? ' [${tr('in', 'za')} ${left(t['levelEndsAt'] as num?)}]' : '';
      lines.add('${tr('Blinds', 'Blajndovi')} ${chips(t['sb'])} | ${chips(t['bb'])}$ante$next');
    }
    final prizes = ((t['prizes'] as List?) ?? const []).cast<num>();
    final paid = prizes.length;
    final playersLeft = (t['playersLeft'] as num? ?? 0).toInt();
    if (t['lateRegEndsAt'] != null) {
      lines.add(tr('Late registration · ${left(t['lateRegEndsAt'] as num?)}', 'Kasna prijava još ${left(t['lateRegEndsAt'] as num?)}'));
      lines.add(tr('Prize pool ${chips(t['prizePool'])} · ${t['entries']} entries', 'Fond ${chips(t['prizePool'])} · ${t['entries']} ulaza'));
      if (paid > 0) lines.add(tr(paid == 1 ? '1 place paid' : '$paid places paid', paid == 1 ? 'Plaća se 1 mesto' : 'Plaćeno $paid mesta'));
    } else if (paid > 0 && playersLeft > paid) {
      lines.add(tr('${playersLeft - paid} players to the money', 'Do nagrada još ${playersLeft - paid} igrača'));
      lines.add(tr('Min prize ${chips(prizes.last)} · ${paid} paid', 'Najmanja nagrada ${chips(prizes.last)} · plaćeno $paid'));
    } else if (paid > 0 && playersLeft > 1) {
      // U nagradama: sledeća nagrada (kad ispadne još jedan igrač) i prvi veći skok.
      final now0 = prizes[min(playersLeft, paid) - 1];
      final nextPrize = prizes[playersLeft - 2];
      lines.add(tr('In the money · next prize ${chips(nextPrize)}', 'U nagradama · sledeća nagrada ${chips(nextPrize)}'));
      int? jumpPlace;
      for (var q = playersLeft - 2; q >= 1; q--) {
        if (prizes[q - 1] > nextPrize) {
          jumpPlace = q;
          break;
        }
      }
      if (jumpPlace != null) lines.add(tr('Prize jump ${chips(prizes[jumpPlace - 1])} ($jumpPlace.)', 'Skok nagrade ${chips(prizes[jumpPlace - 1])} ($jumpPlace. mesto)'));
      if (playersLeft <= ((t['tableSize'] as num?) ?? 9)) lines.add(tr('1st prize ${chips(prizes.first)}', '1. nagrada ${chips(prizes.first)}'));
      if (now0 <= 0) lines.removeLast();
    }
    if (t['position'] != null) lines.add(tr('My rank ${t['position']} / $playersLeft', 'Moje mesto ${t['position']} / $playersLeft'));
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final tour = st['tournament'] as Json?;
    final omaha = st['variant'] == 'OMAHA';
    const faint = TextStyle(fontSize: 10.5, color: Color(0x99E8D9A8), height: 1.35);
    if (tour != null && st['replay'] != true) {
      // Turnir: znak kluba pa podaci turnira (jasnije i krupnije).
      var lines = tourLines(tour, context.read<AppState>().serverNow);
      if (wide && tour['position'] != null) lines = lines.sublist(0, lines.length - 1);
      return Column(children: [
        if (!wide) Opacity(
          opacity: 0.5,
          child: Column(children: [
            GoldText('♠', style: TextStyle(fontSize: w * 0.04, height: 1)),
            GoldText('TRILING', style: TextStyle(fontFamily: 'Cinzel', fontSize: w * 0.06, fontWeight: FontWeight.w800, height: 1)),
          ]),
        ),
        if (!wide) SizedBox(height: w * 0.015),
        for (var k = 0; k < lines.length; k++)
          Text(lines[k],
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: wide ? (k == 0 ? 13 : 11.5) : (k == 0 ? 13.5 : 12),
                fontWeight: k == 0 ? FontWeight.w800 : FontWeight.w600,
                color: const Color(0xB3EDE3C4),
                height: 1.35,
              )),
      ]);
    }
    return Column(children: [
      // Znak kluba na čoji: zlatni, providan
      Opacity(
        opacity: 0.55,
        child: Column(children: [
          GoldText('♠', style: TextStyle(fontSize: w * 0.05, height: 1)),
          GoldText('TRILING', style: TextStyle(fontFamily: 'Cinzel', fontSize: w * 0.075, fontWeight: FontWeight.w800, height: 1)),
          GoldText('— POKER KLUB —',
              style: TextStyle(fontFamily: 'Cinzel', fontSize: w * 0.025, fontWeight: FontWeight.w600, letterSpacing: 3)),
        ]),
      ),
      // Podaci o stolu, bledo na čoji (kao znak kluba)
      Opacity(
        opacity: 0.6,
        child: Column(children: [
          SizedBox(height: w * 0.02),
          Text(
              tour != null
                  ? '${omaha ? 'PLO' : 'NLH'} · Level ${tour['level']} · Blinds ${chips(tour['sb'])}/${chips(tour['bb'])} · Ante ${chips(tour['ante'])}'
                  : '${omaha ? 'PLO' : 'NLH'} · Blinds ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} · Ante ${chips(st['ante'] ?? 0)}',
              style: faint.copyWith(fontWeight: FontWeight.w700)),
          if (st['replay'] != true)
            Text(tour != null ? '${tour['name']} · ${tour['playersLeft']} ${tr('left', 'u igri')}' : '${tr('Buy-in', 'Ulaz')} ${chips(st['minBuyIn'])} – ${chips(st['maxBuyIn'])}', style: faint),
          if (st['replay'] != true)
          Text(
              [
                'Players ${(st['seats'] as List).where((x) => x != null && x['sittingOut'] != true).length}/${(st['seats'] as List).length}',
              ].join(' · '),
              style: faint),
          if (!logoOnly) Text(st['name'] as String, style: faint),
        ]),
      ),
    ]);
  }
}


class _ResultText extends StatelessWidget {
  final Json result;
  final Money money;
  final bool wide;
  const _ResultText({required this.result, required this.money, this.wide = false});

  @override
  Widget build(BuildContext context) {
    final pots = (result['pots'] as List).cast<Json>();
    final lines = <String>[];
    final twice = pots.any((p) => p['run'] != null);
    for (var k = 0; k < pots.length; k++) {
      final p = pots[k];
      final names = (p['winners'] as List).map((w) => w['name']).join(' i ');
      // Run it twice: svaki pot ima polovinu za 1. i 2. sto.
      final prefix = twice
          ? 'Board ${p['run']}: '
          : pots.length > 1
              ? (k == 0 ? 'Main: ' : 'Side: ')
              : '';
      final hand = p['handName'] != null && (wide || pots.length == 1) ? ' · ${p['handName']}' : '';
      lines.add('$prefix$names +${money(p['amount'])}$hand');
    }
    return Container(
      constraints: BoxConstraints(maxWidth: wide ? 300 : 200),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), borderRadius: BorderRadius.circular(10)),
      child: Text(lines.join('\n'),
          textAlign: TextAlign.center, style: const TextStyle(color: gold, fontWeight: FontWeight.w800, fontSize: 11.5)),
    );
  }
}

/// Igrač: avatar sa malim kartama preko njega, ispod ime i stek.
class _SeatView extends StatelessWidget {
  final Json seat;
  final bool isMe;
  final double avatarSize;
  final int? won;
  final double? timeLeft;

  /// Sekunde preostale od dodatnog vremena (TIME), ako je osnovno isteklo.
  final int? timeBankLeft;
  final String? handName;

  /// Oznake D / SB / BB (gornji levi ugao pločice).
  final List<String> badges;

  /// All-in: šansa za pobedu u procentima (i da li je najveća za stolom).
  final double? equity;
  final bool equityLeader;
  final Set<String> best;
  final Money money;

  /// Svoje karte sakrivene (poleđina) dok ih igrač ne dodirne.
  final bool hideCards;
  final VoidCallback? onTap;
  /// Bounty na glavi igrača (PKO turnir).
  final int? bounty;
  const _SeatView({
    this.bounty,
    required this.seat,
    required this.isMe,
    required this.avatarSize,
    this.hideCards = false,
    this.onTap,
    this.timeBankLeft,
    required this.won,
    required this.best,
    required this.money,
    this.timeLeft,
    this.handName,
    this.equity,
    this.equityLeader = false,
    this.badges = const [],
    this.faceCardW,
    this.faceDx = 0,
  });

  /// Pomeraj velikih otvorenih karata levo/desno (da ostanu u ekranu).
  final double faceDx;

  /// Širina otvorene karte (kao moje); tuđe otvorene karte su iste veličine.
  final double Function(int count)? faceCardW;

  @override
  Widget build(BuildContext context) {
    // Tuđe karte mogu biti delimično pokazane (null = poleđina).
    final cards = (seat['cards'] as List?)?.cast<String?>();
    final count = seat['cardCount'] as int;
    final folded = seat['folded'] == true;
    final acting = timeLeft != null;
    final name = seat['name'] as String;
    final away = seat['sittingOut'] == true && seat['inHand'] != true;
    final act = seat['lastAct'] as Json?;
    final a = avatarSize;

    // Oznaka ispod pločice: pobeda, potez ili stanje igrača.
    ({String label, Color color})? tag;
    final bank = timeBankLeft != null;
    const timeColor = Color(0xFFFF9F1C);
    if (equity != null) {
      // All-in: šansa za pobedu (kao na GG)
      tag = (label: '${bbNumber(equity!)} %', color: equityLeader ? const Color(0xFF1E8E4E) : const Color(0xFF3A3F4A));
    } else if (acting && bank) {
      // Osnovno vreme je isteklo: teče dodatno vreme.
      tag = (label: 'TIME $timeBankLeft', color: timeColor);
    } else if (won != null) {
      tag = (label: 'WIN +${money(won)}', color: gold);
    } else if (handName != null) {
      tag = (label: handName!, color: Colors.black87);
    } else if (act != null &&
        !acting &&
        !const ['sb', 'bb', 'ante'].contains(act['type']) &&
        // Kad na pločici već piše ALL-IN, ispod ne treba ljubičasto "ALL-IN iznos".
        !(seat['allIn'] == true && act['type'] == 'allin')) {
      tag = actLabel(act, money);
    } else if (seat['leaving'] == true) {
      tag = (label: 'LEAVING', color: const Color(0xFF2B2F38));
    } else if (away && (seat['stack'] as int) > 0) {
      // Na pauzi sa žetonima: ispod žetona piše SIT OUT (bez žetona piše na pločici umesto broja).
      tag = (label: 'SIT OUT', color: const Color(0xFF2B2F38));
    } else if (away) {
      tag = null;
    }

    // Karte preko gornjeg dela avatara: svoje i otvorene licem, tuđe poleđinom.
    Widget? cardsWidget;
    final scale = a / 50;
    // Tuđe karte otvorene licem (all-in, kraj ruke): velike kao moje, preko slike igrača.
    final bigFace = !isMe && cards != null && cards.any((c) => c != null) && faceCardW != null;
    if (bigFace) {
      final cw = faceCardW!(cards.length);
      cardsWidget = Row(mainAxisSize: MainAxisSize.min, children: [
        for (var k = 0; k < cards.length; k++)
          Transform.translate(
            offset: Offset(-k * cw * 0.14, 0),
            child: Transform.rotate(
              angle: (k - (cards.length - 1) / 2) * 0.07,
              child: cards[k] == null
                  ? PlayingCard(width: cw)
                  : PlayingCard(code: cards[k], width: cw, highlight: best.contains(cards[k])),
            ),
          ),
      ]);
    } else if (cards != null && cards.isNotEmpty) {
      // Moje karte su 20% veće (rastu naviše, da ne pređu preko pločice).
      final cw = (isMe ? (cards.length > 2 ? 28.0 : 34.0) : (cards.length > 2 ? 19.0 : 24.0)) * (isMe ? scale * 0.86 * (a > 80 ? 1.2 : 1.14) : scale);
      cardsWidget = Row(mainAxisSize: MainAxisSize.min, children: [
        for (var k = 0; k < cards.length; k++)
          Transform.translate(
            offset: Offset(-k * cw * 0.14, 0),
            child: Transform.rotate(
              angle: (k - (cards.length - 1) / 2) * 0.07,
              child: hideCards && won == null
                  ? PlayingCard(width: cw)
                  : PlayingCard(code: cards[k], width: cw, dim: folded, highlight: best.contains(cards[k])),
            ),
          ),
      ]);
    } else if (count > 0 && !folded) {
      final cw = 21.0 * scale;
      cardsWidget = Row(mainAxisSize: MainAxisSize.min, children: [
        for (var k = 0; k < count; k++)
          Transform.translate(
            offset: Offset(-k * cw * 0.45, 0),
            child: Transform.rotate(angle: (k - (count - 1) / 2) * 0.12, child: PlayingCard(width: cw)),
          ),
      ]);
    }

    final avatar = SizedBox(
      width: a + 8,
      height: a + 8,
      child: Stack(alignment: Alignment.center, children: [
        Avatar(
          name: name,
          url: seat['avatarUrl'] as String?,
          size: a,
          borderColor: won != null ? goldLight : (acting ? winGreen : gold),
          borderWidth: won != null || acting ? 3 : 2.2,
          shadow: [
            const BoxShadow(color: Colors.black54, blurRadius: 4),
            if (won != null) const BoxShadow(color: Color(0xAAF2C14E), blurRadius: 14),
          ],
        ),
        if (acting)
          SizedBox(
            width: a + 8,
            height: a + 8,
            child: CircularProgressIndicator(
              value: timeLeft,
              strokeWidth: 3.5,
              color: bank ? (timeLeft! < 0.3 ? accent : timeColor) : winGreen,
              backgroundColor: Colors.black38,
            ),
          ),
      ]),
    );

    final big = a >= 52;
    final plate = Container(
      constraints: BoxConstraints(minWidth: big ? 104 : (isMe ? 84 : 76)),
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: big ? 4 : 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xF21E1914), Color(0xF20C0A08)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: acting ? (bank ? timeColor : winGreen) : gold.withOpacity(0.55), width: acting ? 1.6 : 1),
        boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 6)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: big ? 13.5 : 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (seat['allIn'] == true)
            Text('ALL-IN', style: TextStyle(fontWeight: FontWeight.w800, fontSize: big ? 15 : 12, color: accent))
          else if (away && seat['stack'] == 0)
            Text('SIT OUT', style: TextStyle(fontWeight: FontWeight.w800, fontSize: big ? 15 : 12, color: Colors.white70))
          else
            GoldText(money(seat['stack']), style: TextStyle(fontWeight: FontWeight.w800, fontSize: big ? 16 : 12)),
        ]),
        // Traka vremena za potez ispod steka
        if (acting)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: timeLeft,
                minHeight: 3,
                color: bank ? timeColor : goldLight,
                backgroundColor: Colors.white10,
              ),
            ),
          ),
      ]),
    );

    return Opacity(
      opacity: (folded && !isMe && !bigFace) || away || (seat['stack'] == 0 && seat['inHand'] != true) ? 0.5 : 1,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Avatar i karte preko njega
        GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: a + 50,
            height: a + 8,
            child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
              avatar,
              // Svoje karte iznad avatara; tuđe (poleđine) gore desno, kao u dizajnu
              if (cardsWidget != null)
                isMe
                    ? Positioned(top: -a * 0.02 - _myCardsLift(a), child: cardsWidget)
                    : bigFace
                        ? Positioned(
                            bottom: 6,
                            left: -80,
                            right: -80,
                            child: Center(child: Transform.translate(offset: Offset(faceDx, 0), child: cardsWidget))) : Positioned(top: -a * 0.18, right: 0, child: cardsWidget),
              // Bounty: iznad otvorenih karata (moje i tuđe velike), inače sa strane avatara.
              if (bounty != null)
                if (isMe && cardsWidget != null)
                  Positioned(
                    top: -a * 0.02 - _myCardsLift(a) - _BountyPill.heightFor(a) - 3,
                    left: -60,
                    right: -60,
                    child: Center(child: _BountyPill(amount: bounty!, a: a)),
                  )
                else if (bigFace)
                  Positioned(
                    bottom: 6 + faceCardW!(cards.length) * 1.4 + 6,
                    left: -80,
                    right: -80,
                    child: Center(child: Transform.translate(offset: Offset(faceDx, 0), child: _BountyPill(amount: bounty!, a: a))),
                  )
                else
                  Positioned(left: 25 - a * 0.55, top: a * 0.55 - _BountyPill.heightFor(a) / 2 + 4, child: _BountyPill(amount: bounty!, a: a)),
              // Pobeda: veliki WIN preko slike igrača
              if (won != null) Positioned(top: a * 0.12, child: _WinBadge(size: a * 1.25)),
            ]),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -6),
          child: badges.isEmpty
              ? plate
              : Stack(clipBehavior: Clip.none, children: [
                  plate,
                  Positioned(
                    left: -7,
                    top: -9,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      for (final b in badges)
                        Container(
                          margin: const EdgeInsets.only(right: 2),
                          padding: EdgeInsets.symmetric(horizontal: b == 'D' ? 0 : 4),
                          constraints: BoxConstraints(minWidth: big ? 20 : 17, minHeight: big ? 20 : 17),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: b == 'D' ? Colors.white : const Color(0xFF2B2F38),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: b == 'D' ? gold : Colors.white38, width: 1.5),
                            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)],
                          ),
                          child: Text(b,
                              style: TextStyle(
                                  color: b == 'D' ? Colors.black : Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: big ? 10.5 : 9)),
                        ),
                    ]),
                  ),
                ]),
        ),
        if (tag != null)
          Transform.translate(
            offset: const Offset(0, -4),
            child: _Pop(
              key: ValueKey(won != null ? 'win-${seat['userId']}' : 'tag'),
              pop: won != null,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: big ? 2.5 : 1.5),
                decoration: BoxDecoration(color: tag.color, borderRadius: BorderRadius.circular(8)),
                // Ceo natpis (npr. "ALL-IN 5.630", "WIN +1.235"), bez skraćivanja.
                child: Text(
                  tag.label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                      fontSize: big ? 11.5 : 10, fontWeight: FontWeight.w900, color: won != null ? Colors.black : Colors.white),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Oznaka koja "iskoči" kad se pojavi (WIN).
class _Pop extends StatelessWidget {
  final bool pop;
  final Widget child;
  const _Pop({super.key, required this.pop, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!pop) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.elasticOut,
      builder: (_, t, c) => Transform.scale(scale: t, child: c),
      child: child,
    );
  }
}

/// Donji deo: potezi (kao u dizajnu).
class _MyPanel extends StatelessWidget {
  final Json st;
  final AppState app;
  final Money money;
  final bool wide;
  final PreAction? pre;
  final void Function(PreAction p) onPre;
  final VoidCallback onTopUp;
  const _MyPanel({
    required this.st,
    required this.app,
    required this.money,
    required this.pre,
    required this.onPre,
    required this.onTopUp,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    final me = (st['seats'] as List)[st['mySeat'] as int] as Json;
    final legal = st['legal'] as Json?;
    final tableId = st['id'] as String;
    final myHand = _TableViewState.waitingForPlayers(st) ? null : st['myHand'] as String?;
    final inHand = me['inHand'] == true && me['folded'] != true && st['inProgress'] == true;
    final h = wide ? 52.0 : 48.0;

    Widget? bottom;
    // Pokaži karte: posle fold-a ili kad je ruka gotova (a karte nisu već otvorene na kraju).
    // Pokazivanje karata je u meniju stola (☰), ne u traci dole.
    final tour = st['tournament'] as Json?;
    if (tour != null && tour['rebuyUntil'] != null && tour['canRebuy'] == true) {
      // Turnir: ostali ste bez žetona — rebuy dok ne istekne vreme (inače ispadate).
      final r = tour['rebuy'] as Json;
      bottom = Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(tr('Out of chips', 'Nemate žetona'), style: TextStyle(fontWeight: FontWeight.w800, fontSize: wide ? 15 : 13.5)),
            Text(tr('Rebuy in ${clockLeft((tour['rebuyUntil'] as num).toInt(), app.serverNow)} or you are out', 'Rebuy za ${clockLeft((tour['rebuyUntil'] as num).toInt(), app.serverNow)} ili ispadate'),
                style: TextStyle(color: Colors.white60, fontSize: wide ? 13 : 11.5)),
          ]),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LuxButton(
            title: 'REBUY',
            subtitle: '${rsd(r['price'])} → ${chips(r['chips'])}',
            height: h,
            onTap: () => app.run('tour:rebuy', {'id': tour['id']}),
          ),
        ),
      ]);
    } else if (legal != null) {
      bottom = ActionBar(
        legal: legal,
        pot: st['pot'] as int,
        myBet: me['bet'] as int,
        myStack: me['stack'] as int,
        bigBlind: st['bigBlind'] as int,
        potLimit: st['variant'] == 'OMAHA',
        money: money,
        wide: wide,
        onAction: (action, [amount]) =>
            app.run('table:act', {'tableId': tableId, 'action': action, if (amount != null) 'amount': amount}),
      );
    } else if (me['sittingOut'] == true) {
      bottom = LuxButton(
        title: tr("I'm back", 'Vraćam se'),
        icon: Icons.play_arrow,
        height: h,
        onTap: () => app.run('table:sitout', {'tableId': tableId, 'value': false}),
      );
    } else if (me['stack'] == 0 && me['inHand'] != true) {
      bottom = null; // umesto dugmeta iskače prozor Rebuy / Leave table (vidi _RebuyDialog)
    } else if (showableCards(st) case final cards?) {
      // Posle fold-a ili na kraju ruke: dugmad za pokazivanje karata (jedna po jedna ili sve).
      bottom = _ShowBar(
          cards: cards,
          shown: ((me['myShown'] as List?) ?? const []).cast<int>(),
          pending: ((me['myPendingShow'] as List?) ?? const []).cast<int>(),
          height: h,
          wide: wide,
          onShow: (idx) => app.run('table:show', {'tableId': tableId, 'cards': idx}));
    } else if (inHand && me['allIn'] != true) {
      // Potez unapred, kao na GG: zavisi od toga da li ima uloga za dorovnavanje.
      final toCall = toCallOf(st);
      Widget b(String label, PreAction a) =>
          Expanded(child: _PreButton(label: label, selected: pre == a, onTap: () => onPre(a), height: h));
      bottom = Row(children: [
        if (toCall == 0) ...[
          b('Check / Fold', PreAction.checkFold),
          const SizedBox(width: 8),
          b('Check', PreAction.check),
        ] else ...[
          b('Fold', PreAction.fold),
          const SizedBox(width: 8),
          b('Call ${money(toCall)}', PreAction.call),
        ],
        const SizedBox(width: 8),
        b('Call any', PreAction.callAny),
      ]);
    }


    if (!wide) {
      // Telefon: snaga ruke stoji levo odmah iznad donjih dugmadi (ne pomera se kad se otvori Raise).
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
        child: Stack(clipBehavior: Clip.none, children: [
          if (bottom != null) bottom else SizedBox(height: h, width: double.infinity),
          if (myHand != null) Positioned(left: 0, bottom: h + 6, child: _HandPill(myHand)),
        ]),
      );
    }

    // Računar: traka preko cele širine dole
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF14100C), Color(0xFF080605)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        border: Border(top: BorderSide(color: gold.withOpacity(0.35))),
      ),
      // Stalna visina (koliko zauzimaju potezi sa iznosima), da sto ne skače kad dođeš na potez.
      // (Snaga ruke na računaru stoji u donjem levom uglu stola, ne ovde.)
      child: SizedBox(height: 112, child: Align(alignment: Alignment.bottomCenter, child: bottom)),
    );
  }
}

/// Traka "Pokaži karte": tri izbora (prva karta, druga karta, obe) kao slike karata.
/// Izbor tokom ruke se pamti, a karte se otvaraju ostalima tek kad se ruka završi.
class _ShowBar extends StatelessWidget {
  final List<String> cards;
  final List<int> shown;
  final List<int> pending;
  final double height;
  final bool wide;
  final void Function(List<int> idx) onShow;
  const _ShowBar({required this.cards, required this.shown, required this.pending, required this.height, required this.wide, required this.onShow});

  @override
  Widget build(BuildContext context) {
    final cw = wide ? 34.0 : 29.0;
    final all = [for (var k = 0; k < cards.length; k++) k];
    final options = <List<int>>[
      for (var k = 0; k < cards.length; k++) [k],
      all,
    ];
    bool same(List<int> a, List<int> b) => a.length == b.length && a.every(b.contains);
    Widget option(List<int> idx) {
      final selected = same(idx, pending) || (shown.isNotEmpty && idx.every(shown.contains));
      final isAll = idx.length > 1;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Material(
            color: selected ? const Color(0x66C9A227) : Colors.black.withOpacity(0.45),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              // Ponovni dodir na izabrano poništava izbor (samo dok ruka traje).
              onTap: () => onShow(same(idx, pending) ? const [] : idx),
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: selected ? goldLight : Colors.white24, width: selected ? 2 : 1),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.visibility, size: wide ? 18 : 15, color: selected ? goldLight : Colors.white54),
                  const SizedBox(width: 5),
                  for (final k in idx)
                    Padding(
                      padding: EdgeInsets.only(right: isAll ? 0 : 2),
                      child: Transform.translate(
                        offset: Offset(isAll && k > 0 ? -cw * 0.18 * k : 0, 0),
                        child: PlayingCard(code: cards[k], width: cards.length > 2 && isAll ? cw * 0.8 : cw),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    return Row(children: [for (final o in options) option(o)]);
  }
}

/// Glavni pot i sporedni potovi, jedan pored drugog (u više redova ako ih je mnogo).
class _SidePots extends StatelessWidget {
  final List<int> pots;
  final Money money;
  final bool wide;
  const _SidePots({required this.pots, required this.money, required this.wide});

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        spacing: wide ? 6 : 4,
        runSpacing: wide ? 4 : 3,
        children: [
          for (var k = 0; k < pots.length; k++)
            Container(
              height: wide ? 24 : 18,
              padding: EdgeInsets.symmetric(horizontal: wide ? 10 : 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: gold.withOpacity(k == 0 ? 0.9 : 0.5)),
              ),
              child: Center(
                widthFactor: 1,
                child: Text(
                '${k == 0 ? 'Main' : pots.length > 2 ? 'Side $k' : 'Side'}: ${money(pots[k])}',
                style: TextStyle(fontSize: wide ? 12.5 : 9.5, fontWeight: FontWeight.w800, color: k == 0 ? goldLight : Colors.white),
              )),
            ),
        ],
      );
}

/// "Waiting for other players" sa tačkicama koje trepere, u sredini praznog stola.
class _WaitingBadge extends StatefulWidget {
  const _WaitingBadge();
  @override
  State<_WaitingBadge> createState() => _WaitingBadgeState();
}

class _WaitingBadgeState extends State<_WaitingBadge> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 900;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: wide ? 26 : 18, vertical: wide ? 14 : 10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: gold.withOpacity(0.6), width: 1.3),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 14)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        GoldText(tr('Waiting for other players', 'Čeka se još igrača'),
            style: TextStyle(fontSize: wide ? 18 : 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        AnimatedBuilder(
          animation: _c,
          builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: wide ? 9 : 7,
                height: wide ? 9 : 7,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: goldLight.withOpacity(0.25 + 0.75 * (0.5 + 0.5 * sin(2 * pi * (_c.value - i / 3)))),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Koliko se moje (uvećane) karte dižu iznad avatara: 20% visine karte.
/// Oznaka bounty-ja na glavi igrača (PKO turnir).
class _BountyPill extends StatelessWidget {
  final int amount;
  final double a;
  const _BountyPill({required this.amount, required this.a});

  static double fontFor(double a) => (a * 0.2).clamp(10.5, 14.0);
  static double heightFor(double a) => fontFor(a) * 1.25 + 6;

  @override
  Widget build(BuildContext context) {
    final fs = fontFor(a);
    return IgnorePointer(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: fs * 0.55, vertical: 2),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFFFF8A3D), Color(0xFFD9480F)]),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFFD8A8), width: 1),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 2))],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.gps_fixed, size: fs, color: Colors.white),
          const SizedBox(width: 3),
          Text(chips(amount), style: TextStyle(fontSize: fs, fontWeight: FontWeight.w900, color: Colors.white, height: 1.25)),
        ]),
      ),
    );
  }
}

double _myCardsLift(double a) => 34.0 * (a / 50) * 0.86 * 0.2 * 1.4;

/// Natpis sa snagom moje ruke ("Two pair 8 & 3").
class _HandPill extends StatelessWidget {
  final String text;
  final bool big;
  const _HandPill(this.text, {this.big = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: big ? 14 : 10, vertical: big ? 6 : 3),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(big ? 10 : 8),
          border: Border.all(color: gold.withOpacity(0.45)),
        ),
        child: GoldText(text, style: TextStyle(fontWeight: FontWeight.w800, fontSize: big ? 15 : 13)),
      );
}

class _PreButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double height;
  const _PreButton({required this.label, required this.selected, required this.onTap, this.height = 40});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: Size.fromHeight(height),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        // Providno preko stola (vidi se sto ispod), izabrano jače.
        backgroundColor: selected ? const Color(0x66C9A227) : Colors.black.withOpacity(0.28),
        foregroundColor: selected ? Colors.white : Colors.white.withOpacity(0.85),
        side: BorderSide(color: selected ? goldLight : Colors.white24, width: selected ? 2 : 1),
      ),
      onPressed: onTap,
      icon: Icon(selected ? Icons.check_box : Icons.check_box_outline_blank,
          size: 18, color: selected ? goldLight : Colors.white54),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
    );
  }
}

/// Izbor iznosa žetona (ulaz za sto ili dopuna).
class ChipsDialog extends StatefulWidget {
  final String title;
  final String confirm;
  final String info;
  final int min;
  final int max;
  final int balance;
  const ChipsDialog({
    super.key,
    required this.title,
    required this.confirm,
    required this.info,
    required this.min,
    required this.max,
    required this.balance,
  });

  @override
  State<ChipsDialog> createState() => _ChipsDialogState();
}

class _ChipsDialogState extends State<ChipsDialog> {
  late int _value;
  late final int _top = min(widget.max, widget.balance);

  @override
  void initState() {
    super.initState();
    _value = _top;
  }

  @override
  Widget build(BuildContext context) {
    final enough = _top >= widget.min;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.info, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 4),
          Text('${tr('Account', 'Nalog')}: ${rsd(widget.balance)}', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          if (!enough)
            Text(tr('Not enough on your account (at least ${chips(widget.min)} needed). Contact your agent for a deposit.', 'Nemate dovoljno na nalogu (potrebno je bar ${chips(widget.min)}). Javite se agentu za uplatu.'),
                style: const TextStyle(color: Color(0xFFFF8A80)))
          else ...[
            Center(child: Text(chips(_value), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
            if (_top > widget.min)
              Slider(
                min: widget.min.toDouble(),
                max: _top.toDouble(),
                value: _value.toDouble(),
                onChanged: (v) => setState(() => _value = v.round()),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(onPressed: () => setState(() => _value = widget.min), child: Text('Min ${chips(widget.min)}')),
                TextButton(onPressed: () => setState(() => _value = _top), child: Text('Max ${chips(_top)}')),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel', 'Otkaži'))),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
          onPressed: enough ? () => Navigator.pop(context, _value) : null,
          child: Text(widget.confirm),
        ),
      ],
    );
  }
}

// ---------- Replay ruke preko celog ekrana ----------

/// Otvara ponovno odigravanje ruke iz istorije: isti sto i iste animacije kao uživo.
void openHandReplay(BuildContext context, Json hand) {
  Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => HandReplayScreen(hand: hand)));
}

class HandReplayScreen extends StatefulWidget {
  final Json hand;
  const HandReplayScreen({super.key, required this.hand});

  @override
  State<HandReplayScreen> createState() => _HandReplayScreenState();
}

class _HandReplayScreenState extends State<HandReplayScreen> {
  late final List<Json> frames;
  late final int bigBlind;
  int step = 0;
  /// Promena ključa: sto se iscrta iznova bez animacije (kad se ide unazad ili skače).
  int _epoch = 0;
  bool _playing = true;
  double _speed = 1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    frames = _buildFrames();
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Koliko dugo se vidi kadar pre sledećeg (otvaranje karata i kraj ruke traju duže).
  int _durationOf(Json f) {
    final base = switch (f['_kind']) { 'deal' => 1400, 'street' => 1500, 'end' => 0, _ => 1100 };
    return (base / _speed).round();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_playing || step >= frames.length - 1) return;
    _timer = Timer(Duration(milliseconds: _durationOf(frames[step])), () {
      if (!mounted) return;
      setState(() => step++);
      _schedule();
    });
  }

  void _go(int to, {bool animate = false}) {
    setState(() {
      step = to.clamp(0, frames.length - 1);
      if (!animate) _epoch++;
    });
    _schedule();
  }

  List<Json> _buildFrames() {
    final h = widget.hand;
    final table = (h['table'] as Map?) ?? const {};
    final players = (h['players'] as List).cast<Json>().toList()..sort((a, b) => (a['seat'] as int).compareTo(b['seat'] as int));
    final actions = ((h['actions'] as List?) ?? const []).cast<Json>();
    final board = (h['board'] as List).cast<String>();
    final shownList = ((h['shown'] as List?) ?? const []).cast<Json>();
    final maxSeats = max((table['maxSeats'] as int?) ?? 9, players.map((p) => p['seat'] as int).fold(0, max) + 1);
    final variant = (table['variant'] as String?) ?? 'HOLDEM';
    final holeCount = variant == 'OMAHA' ? 4 : 2;
    final me = players.firstWhere((p) => p['isMe'] == true, orElse: () => players.first);
    final mySeat = me['isMe'] == true ? me['seat'] as int : -1;
    int amountOf(String type) => ((actions.firstWhere((a) => a['type'] == type, orElse: () => const {})['amount']) as num?)?.toInt() ?? 0;
    final sb = actions.firstWhere((a) => a['type'] == 'sb', orElse: () => const {})['seat'] as int? ?? -1;
    final bbSeat = actions.firstWhere((a) => a['type'] == 'bb', orElse: () => const {})['seat'] as int? ?? -1;
    bigBlind = max(1, amountOf('bb') > 0 ? amountOf('bb') : ((table['bigBlind'] as int?) ?? 2));
    final seatsInHand = players.map((p) => p['seat'] as int).toList();
    var button = -1;
    if (sb >= 0) {
      if (seatsInHand.length == 2) {
        button = sb;
      } else {
        final i = seatsInHand.indexOf(sb);
        button = seatsInHand[(i - 1 + seatsInHand.length) % seatsInHand.length];
      }
    }

    final stack = {for (final p in players) p['seat'] as int: p['startStack'] as int};
    final bet = <int, int>{};
    final folded = <int>{};
    final lastAct = <int, Json?>{};
    var collected = 0;
    var street = 'preflop';
    var boardCount = 0;
    int cardsFor(String s) => switch (s) { 'flop' => 3, 'turn' => 4, 'river' => 5, _ => 0 };
    final out = <Json>[];

    Json frame(String kind, {int toAct = -1, bool end = false, Json? result, int? boardShown}) {
      final b = boardShown ?? boardCount;
      final shownSeats = {for (final s in shownList) s['seat'] as int: (s['cards'] as List).cast<String>()};
      return {
        '_kind': kind,
        'id': 'replay-${h['id']}',
        'name': table['name'] ?? '',
        'variant': variant,
        'smallBlind': bigBlind ~/ 2,
        'bigBlind': bigBlind,
        'minBuyIn': 0,
        'maxBuyIn': 0,
        'maxSeats': maxSeats,
        'actionSeconds': 15,
        'handNo': h['handNo'],
        'inProgress': !end,
        'street': end ? null : street,
        'board': board.take(b).toList(),
        // Na kraju: tačno ono što je podeljeno (vraćen nepokriven ulog se ne računa).
        'pot': end
            ? ((h['pots'] as List?) ?? const []).fold<int>(0, (x, p) => x + ((p as Map)['amount'] as num).toInt())
            : collected + bet.values.fold(0, (x, y) => x + y),
        'collected': end ? 0 : collected,
        'replay': true,
        'sidePots': const [],
        'button': button,
        'sbSeat': sb,
        'bbSeat': bbSeat,
        'toAct': toAct,
        'deadline': null,
        'timeBankAt': null,
        'timeBankSeconds': 0,
        'ante': 0,
        'serverTime': 0,
        'mySeat': mySeat,
        'myHand': null,
        'legal': null,
        'actions': const [],
        'waitlist': const [],
        'ritPending': false,
        'ritAsk': const [],
        'ritYes': const [],
        'ritNo': const [],
        'result': result,
        'tournament': null,
        'seats': [
          for (var i = 0; i < maxSeats; i++)
            if (!stack.containsKey(i))
              null
            else
              () {
                final p = players.firstWhere((x) => x['seat'] == i);
                final cards = p['isMe'] == true
                    ? ((p['cards'] as List?) ?? const []).cast<String>()
                    : (end ? shownSeats[i] : null);
                return <String, dynamic>{
                  'index': i,
                  'userId': 'replay-$i',
                  'name': p['name'],
                  'avatarUrl': null,
                  'stack': end ? p['endStack'] : stack[i],
                  'bet': end ? 0 : (bet[i] ?? 0),
                  'inHand': true,
                  'folded': folded.contains(i),
                  'allIn': !end && (stack[i] ?? 0) == 0 && !folded.contains(i),
                  'sittingOut': false,
                  'leaving': false,
                  'lastAction': null,
                  'lastAct': end ? null : lastAct[i],
                  'cards': cards != null && cards.isNotEmpty ? cards : null,
                  'myShown': const [],
                  'cardCount': folded.contains(i) ? 0 : holeCount,
                };
              }(),
        ],
      };
    }

    out.add(frame('deal', toAct: actions.isNotEmpty ? actions.first['seat'] as int : -1));
    for (var k = 0; k < actions.length; k++) {
      final a = actions[k];
      final s = a['street'] as String? ?? 'preflop';
      if (s != street) {
        // Nova ulica: ulozi idu u pot, otvaraju se karte stola.
        collected += bet.values.fold(0, (x, y) => x + y);
        bet.clear();
        street = s;
        boardCount = max(boardCount, min(board.length, cardsFor(s)));
        for (final i in stack.keys) {
          if (!folded.contains(i)) lastAct[i] = null;
        }
        out.add(frame('street', toAct: a['seat'] as int));
      }
      final seat = a['seat'] as int;
      final amount = (a['amount'] as num?)?.toInt() ?? 0;
      final type = a['type'] as String;
      if (type == 'ante' || type == 'bomb') {
        stack[seat] = (stack[seat] ?? 0) - amount;
        collected += amount;
      } else if (type == 'fold') {
        folded.add(seat);
        lastAct[seat] = {'type': 'fold', 'amount': 0};
      } else if (type == 'check') {
        lastAct[seat] = {'type': 'check', 'amount': 0};
      } else {
        // Iznos je ukupan ulog igrača u ovoj ulici.
        final add = max(0, amount - (bet[seat] ?? 0));
        stack[seat] = (stack[seat] ?? 0) - add;
        bet[seat] = amount;
        lastAct[seat] = {'type': type, 'amount': amount};
      }
      final next = k + 1 < actions.length && actions[k + 1]['street'] == s ? actions[k + 1]['seat'] as int : -1;
      if (type != 'ante' || k + 1 >= actions.length || actions[k + 1]['type'] != 'ante') out.add(frame('act', toAct: next));
    }
    // Kraj ruke: ako su igrači all-in pre kraja stola, ostale karte se otkrivaju jedna po jedna (kao uživo).
    final live = stack.keys.where((i) => !folded.contains(i)).length;
    final runout = live > 1 && boardCount < board.length;
    final result = <String, dynamic>{
      'handNo': h['handNo'],
      'board2': null,
      'runoutFrom': runout ? boardCount : null,
      'equity': null,
      'pots': h['pots'] ?? const [],
      'shown': [
        for (final s in shownList)
          {'seat': s['seat'], 'cards': s['cards'], 'best': s['best'] ?? const [], 'handName': s['handName']},
      ],
    };
    collected += bet.values.fold(0, (x, y) => x + y);
    bet.clear();
    out.add(frame('end', end: true, result: result, boardShown: board.length));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final showBB = context.select<AppState, bool>((a) => a.showBB);
    final st = frames[step];
    final money = Money(bigBlind, showBB);
    final wide = MediaQuery.of(context).size.width >= 900;
    final h = widget.hand;
    final table = (h['table'] as Map?) ?? const {};
    return Scaffold(
      backgroundColor: bg,
      body: LuxBackground(
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(children: [
                _RoundIcon(icon: Icons.close, tip: tr('Close', 'Zatvori'), onTap: () => Navigator.pop(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    GoldText('REPLAY · #${h['handNo']}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                    Text('${table['name'] ?? ''} · ${dateTime(h['createdAt'] as String)}',
                        overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Colors.white60)),
                  ]),
                ),
                _UnitToggle(showBB: money.inBB, onToggle: context.read<AppState>().setShowBB),
              ]),
            ),
            Expanded(
              child: LayoutBuilder(builder: (_, c) {
                final w = min(c.maxWidth, c.maxHeight * (wide ? 1.95 : 1.6));
                final hh = min(c.maxHeight, w * 2.0);
                return Center(
                  child: SizedBox(
                    width: w,
                    height: hh,
                    child: _TableView(
                      key: ValueKey('replay-$_epoch'),
                      st: st,
                      size: Size(w, hh),
                      money: money,
                      chat: const [],
                      wide: wide,
                      onSit: (_) {},
                      onTapMine: () {},
                      onTapPlayer: (_) {},
                    ),
                  ),
                );
              }),
            ),
            // Kontrole: početak, korak nazad, pusti/pauza, korak napred, kraj, brzina
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                border: Border(top: BorderSide(color: gold.withOpacity(0.3))),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: SliderComponentShape.noOverlay),
                  child: Slider(
                    min: 0,
                    max: (frames.length - 1).toDouble(),
                    divisions: max(1, frames.length - 1),
                    value: step.toDouble(),
                    onChanged: (v) => _go(v.round()),
                  ),
                ),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(onPressed: step > 0 ? () => _go(0) : null, icon: const Icon(Icons.skip_previous, size: 28)),
                  IconButton(onPressed: step > 0 ? () => _go(step - 1) : null, icon: const Icon(Icons.chevron_left, size: 34)),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: () {
                      setState(() {
                        if (step >= frames.length - 1) {
                          step = 0;
                          _epoch++;
                        }
                        _playing = !_playing || step == 0;
                      });
                      _schedule();
                    },
                    style: IconButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black, fixedSize: const Size(58, 58)),
                    icon: Icon(_playing && step < frames.length - 1 ? Icons.pause : Icons.play_arrow, size: 34),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                      onPressed: step < frames.length - 1 ? () => _go(step + 1, animate: true) : null,
                      icon: const Icon(Icons.chevron_right, size: 34)),
                  IconButton(
                      onPressed: step < frames.length - 1 ? () => _go(frames.length - 1) : null,
                      icon: const Icon(Icons.skip_next, size: 28)),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      setState(() => _speed = _speed >= 2 ? 0.5 : _speed * 2);
                      _schedule();
                    },
                    child: Text('${_speed == 0.5 ? '0.5' : _speed.toStringAsFixed(0)}×',
                        style: const TextStyle(color: goldLight, fontWeight: FontWeight.w900, fontSize: 16)),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
