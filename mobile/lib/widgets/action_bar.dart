import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../format.dart';
import '../theme.dart';
import 'brand.dart';

/// Potezi kad je igrač na redu: Fold, Check/Call i Bet/Raise sa izborom iznosa (−/+, klizač, brzi iznosi).
class ActionBar extends StatefulWidget {
  final Map<String, dynamic> legal;
  final int pot;
  final int myBet;
  final int myStack;
  final int bigBlind;
  final bool potLimit;
  final Money money;
  final bool wide;
  final Future<bool> Function(String action, [int? amount]) onAction;

  const ActionBar({
    super.key,
    required this.legal,
    required this.pot,
    required this.myBet,
    required this.myStack,
    required this.bigBlind,
    required this.potLimit,
    required this.money,
    required this.onAction,
    this.wide = false,
  });

  @override
  State<ActionBar> createState() => _ActionBarState();
}

class _ActionBarState extends State<ActionBar> {
  bool _busy = false;
  int _amount = 0;
  /// Telefon: izbor iznosa se otvara tek na dugme Raise/Bet.
  bool _open = false;
  /// Telefon: tastatura za upis iznosa (umesto dugmadi sa delovima pota).
  bool _keypad = false;
  /// Ono što je igrač otkucao na tastaturi.
  String _typed = '';

  int? get _min => widget.legal['minRaiseTo'] as int?;
  int? get _max => widget.legal['maxRaiseTo'] as int?;
  int get _call => widget.legal['call'] as int;
  int get _currentBet => widget.myBet + _call;
  int get _allIn => widget.myBet + widget.myStack;
  bool get _canRaise => _min != null && _max != null;
  Money get _m => widget.money;

  /// Polje u koje igrač sam upisuje iznos (u dinarima ili u BB, kako je izabrano za stolom).
  final _field = TextEditingController();
  final _focus = FocusNode();

  String _fieldText(int a) => _m.inBB ? bbNumber(a / widget.bigBlind) : '$a';

  /// Postavi iznos i (ako igrač trenutno ne kuca) prepiši ga u polje.
  void _set(int v) {
    setState(() => _amount = v);
    if (!_focus.hasFocus) _field.text = _fieldText(v);
  }

  /// Iznos iz upisanog teksta (null ako nije broj), ograničen na dozvoljeno.
  int? _parse(String text) {
    // Dinari: celi broj (tačke i zarezi su razdvajači hiljada); BB: može i decimala (12,5 ili 12.5).
    final clean = text.replaceAll(' ', '');
    final v = _m.inBB ? double.tryParse(clean.replaceAll(',', '.')) : double.tryParse(clean.replaceAll(RegExp('[.,]'), ''));
    if (v == null || !_canRaise) return null;
    final amount = _m.inBB ? (v * widget.bigBlind).round() : v.round();
    return amount.clamp(_min!, _max!);
  }

  /// Kad igrač završi kucanje: iznos se ispravi na dozvoljeni i upiše nazad.
  void _commitField() {
    final v = _parse(_field.text);
    if (v != null) _amount = v;
    _field.text = _fieldText(_amount);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _amount = _min ?? 0;
    _field.text = _fieldText(_amount);
    _focus.addListener(() {
      if (!_focus.hasFocus) _commitField();
    });
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ActionBar old) {
    super.didUpdateWidget(old);
    if (old.legal.toString() != widget.legal.toString()) {
      _busy = false;
      _open = false;
      _keypad = false;
      _typed = '';
      _amount = _min ?? 0;
      _field.text = _fieldText(_amount);
    } else if (old.money.inBB != widget.money.inBB) {
      _field.text = _fieldText(_amount);
    }
  }

  Future<void> _send(String action, [int? amount]) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.onAction(action, amount);
    if (mounted && !ok) setState(() => _busy = false);
  }

  /// Iznos "povisi na" za deo pota (pot posle dorovnjavanja).
  int _potFraction(double f) {
    final to = _currentBet + ((widget.pot + _call) * f).round();
    return to.clamp(_min!, _max!);
  }

  void _step(int dir) {
    _focus.unfocus();
    _set((_amount + dir * widget.bigBlind).clamp(_min!, _max!));
  }

  Widget _buttons() {
    final canCheck = widget.legal['check'] == true;
    final allInRaise = _canRaise && _amount == _allIn;
    return Row(children: [
      Expanded(
        child: LuxButton(
          title: 'Fold',
          icon: Icons.close,
          gradient: redGradient,
          textColor: Colors.white,
          height: 52,
          onTap: _busy ? null : () => _send('fold'),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: LuxButton(
          title: canCheck ? 'Check' : (_call >= widget.myStack ? 'All-in' : 'Call'),
          subtitle: canCheck ? null : _m(_call),
          icon: canCheck ? Icons.check : Icons.replay,
          height: 52,
          onTap: _busy ? null : () => _send(canCheck ? 'check' : 'call'),
        ),
      ),
      if (_canRaise) ...[
        const SizedBox(width: 8),
        Expanded(
          child: LuxButton(
            title: allInRaise ? 'All-in' : (_currentBet == 0 ? 'Bet' : 'Raise'),
            subtitle: _m(_amount),
            icon: Icons.keyboard_arrow_up,
            height: 52,
            onTap: _busy
                ? null
                : () {
                    // Na telefonu prvi dodir otvara izbor iznosa, drugi potvrđuje.
                    if (!widget.wide && !_open) {
                      setState(() => _open = true);
                    } else {
                      if (_focus.hasFocus) _commitField();
                      _send('raise', _amount);
                    }
                  },
          ),
        ),
      ],
    ]);
  }

  Widget _round(IconData icon, VoidCallback? onTap) => InkResponse(
        onTap: onTap,
        radius: 22,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: gold.withOpacity(onTap == null ? 0.2 : 0.6)),
          ),
          child: Icon(icon, color: onTap == null ? Colors.white24 : goldLight, size: 22),
        ),
      );

  /// Polje za upis iznosa (dodir na broj otvara tastaturu).
  Widget _amountField({bool big = false}) => TextField(
              controller: _field,
              focusNode: _focus,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.numberWithOptions(decimal: _m.inBB),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              style: TextStyle(fontSize: big ? 17 : 18, fontWeight: FontWeight.w800),
              cursorColor: gold,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Colors.black38,
                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: big ? 8 : 4),
                suffixText: _m.inBB ? 'BB' : null,
                suffixStyle: const TextStyle(fontSize: 12, color: Colors.white60, fontWeight: FontWeight.w700),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(big ? 10 : 8), borderSide: BorderSide(color: gold.withOpacity(big ? 0.6 : 0.35))),
                enabledBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(big ? 10 : 8), borderSide: BorderSide(color: gold.withOpacity(big ? 0.6 : 0.35))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(big ? 10 : 8), borderSide: const BorderSide(color: gold)),
              ),
              onTap: () => _field.selection = TextSelection(baseOffset: 0, extentOffset: _field.text.length),
              onChanged: (t) {
                final v = _parse(t);
                if (v != null) setState(() => _amount = v);
              },
              onSubmitted: (_) => _focus.unfocus(),
            );

  /// Računar: brzi iznosi (Min, ½, ¾, Pot, All-in) kao velika dugmad sa iznosom,
  /// pored njih −, klizač, + i polje za upis.
  Widget _wideAmountRow() {
    final presets = <String, int>{
      'Min': _min!,
      '½ pot': _potFraction(0.5),
      '¾ pot': _potFraction(0.75),
      'Pot': _potFraction(1),
      widget.potLimit ? 'Max' : 'All-in': _max!,
    };
    final step = max(1, min(widget.bigBlind, (_max! - _min!) ~/ 20));
    final divisions = _max! > _min! ? max(1, (_max! - _min!) ~/ step) : null;
    Widget preset(String label, int v) {
      final sel = _amount == v;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Material(
            color: const Color(0xFF1D1513),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _busy
                  ? null
                  : () {
                      _focus.unfocus();
                      _set(v);
                    },
              child: Container(
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: sel ? goldLight : gold.withOpacity(0.4), width: sel ? 2 : 1.2),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(label,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: sel ? goldLight : Colors.white)),
                  Text(_m(v), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white60)),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 52,
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Padding(
            padding: EdgeInsets.zero,
            child: Row(children: [for (final e in presets.entries) preset(e.key, e.value)]),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 2,
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1D1513),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: gold.withOpacity(0.4), width: 1.2),
            ),
            child: Row(children: [
              _round(Icons.remove, _amount > _min! ? () => _step(-1) : null),
              Expanded(
                child: divisions == null
                    ? const SizedBox()
                    : SliderTheme(
                        data: SliderTheme.of(context).copyWith(trackHeight: 5, overlayShape: SliderComponentShape.noOverlay),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Slider(
                            min: _min!.toDouble(),
                            max: _max!.toDouble(),
                            divisions: divisions,
                            value: _amount.clamp(_min!, _max!).toDouble(),
                            onChanged: (v) {
                              var to = v.round();
                              if (to != _max) to = (to ~/ step) * step;
                              _focus.unfocus();
                              _set(to.clamp(_min!, _max!));
                            },
                          ),
                        ),
                      ),
              ),
              _round(Icons.add, _amount < _max! ? () => _step(1) : null),
              const SizedBox(width: 8),
              SizedBox(width: 92, height: 38, child: _amountField(big: true)),
            ]),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.wide) {
      // Računar: gore red velikih brzih iznosa i klizač, dole tri ista dugmeta.
      return Column(mainAxisSize: MainAxisSize.min, children: [
        if (_canRaise) ...[_wideAmountRow(), const SizedBox(height: 8)],
        _buttons(),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      if (_canRaise && _open) ...[_keypad ? _keypadBox() : _phonePresets(), const SizedBox(height: 8)],
      _buttons(),
    ]);
  }

  /// Telefon: delovi pota jedan iznad drugog (dodir odmah igra taj iznos), pored njih tastatura.
  Widget _phonePresets() {
    final seen = <int>{};
    final items = <(String, String, int)>[];
    void add(String pct, String label, int v) {
      if (v < _min! || v > _max! || !seen.add(v)) return;
      items.add((pct, label, v));
    }
    add('', widget.potLimit ? 'Max' : 'All-in', _max!);
    add('100%', _currentBet == 0 ? 'Bet' : 'Raise', _potFraction(1));
    add('75%', _currentBet == 0 ? 'Bet' : 'Raise', _potFraction(0.75));
    add('50%', _currentBet == 0 ? 'Bet' : 'Raise', _potFraction(0.5));
    add('33%', _currentBet == 0 ? 'Bet' : 'Raise', _potFraction(0.33));
    add('Min', _currentBet == 0 ? 'Bet' : 'Raise', _min!);
    Widget btn((String, String, int) it) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: const Color(0xE6120D0B),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _busy ? null : () => _send('raise', it.$3),
              child: Container(
                width: 140,
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: gold.withOpacity(0.55), width: 1.2)),
                child: Row(children: [
                  if (it.$1.isNotEmpty)
                    Text(it.$1, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white70)),
                  const Spacer(),
                  Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(it.$2, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
                    Text(_m(it.$3), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: goldLight)),
                  ]),
                ]),
              ),
            ),
          ),
        );
    // Tastatura za tačan iznos: iznad kolone (ne prekriva moje karte).
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: _roundBig(Icons.dialpad, () => setState(() {
              _keypad = true;
              _typed = '';
            })),
      ),
      for (final it in items) btn(it),
    ]);
  }

  Widget _roundBig(IconData icon, VoidCallback onTap) => Material(
        color: const Color(0xE6120D0B),
        shape: CircleBorder(side: BorderSide(color: gold.withOpacity(0.55), width: 1.2)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 52, height: 52, child: Icon(icon, color: goldLight, size: 26)),
        ),
      );

  /// Telefon: tastatura za upis iznosa (u dinarima ili BB, kako je izabrano za stolom).
  Widget _keypadBox() {
    void press(String k) {
      setState(() {
        if (k == '<') {
          if (_typed.isNotEmpty) _typed = _typed.substring(0, _typed.length - 1);
        } else if (k == '.') {
          if (_m.inBB && !_typed.contains('.')) _typed = _typed.isEmpty ? '0.' : '$_typed.';
        } else if (_typed.length < 9) {
          _typed = _typed == '0' ? k : '$_typed$k';
        }
        final v = _parse(_typed);
        if (v != null) _amount = v;
      });
    }

    Widget key(String k) => Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: const Color(0xF0181210),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: (k == '.' && !_m.inBB) ? null : () => press(k),
              child: SizedBox(
                width: 64,
                height: 46,
                child: Center(
                  child: k == '<'
                      ? const Icon(Icons.backspace_outlined, color: Colors.white70, size: 22)
                      : Text(k, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: (k == '.' && !_m.inBB) ? Colors.white24 : Colors.white)),
                ),
              ),
            ),
          ),
        );
    final typedValue = _typed.isEmpty ? null : _parse(_typed);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: _roundBig(Icons.close, () => setState(() => _keypad = false)),
      ),
      Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xE60E0A09),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: gold.withOpacity(0.45)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Otkucani iznos (ispravlja se na najmanji/najveći dozvoljeni)
          Container(
            width: 3 * 70,
            height: 46,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10), border: Border.all(color: gold.withOpacity(0.6))),
            child: Row(children: [
              Text(_m.inBB ? 'BB' : 'RSD', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white60)),
              const Spacer(),
              Text(_typed.isEmpty ? '0' : _typed, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: goldLight)),
            ]),
          ),
          if (_typed.isNotEmpty && typedValue != null && _fieldText(typedValue) != _typed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('→ ${_m(typedValue)}', style: const TextStyle(fontSize: 12, color: Colors.white60)),
            ),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
            ['.', '0', '<'],
          ])
            Row(mainAxisSize: MainAxisSize.min, children: [for (final k in row) key(k)]),
        ]),
      ),
    ]);
  }
}
