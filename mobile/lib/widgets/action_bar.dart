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
          height: widget.wide ? 64 : 52,
          onTap: _busy ? null : () => _send('fold'),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: LuxButton(
          title: canCheck ? 'Check' : (_call >= widget.myStack ? 'All-in' : 'Call'),
          subtitle: canCheck ? null : _m(_call),
          icon: canCheck ? Icons.check : Icons.replay,
          height: widget.wide ? 64 : 52,
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
            height: widget.wide ? 64 : 52,
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

  /// Izbor iznosa: −, iznos, + ; klizač; brzi iznosi.
  Widget _amountBox() {
    final presets = <String, int>{
      'Min': _min!,
      '½ pot': _potFraction(0.5),
      'Pot': _potFraction(1),
      if (!widget.potLimit) 'All-in': _max!,
    };
    final step = max(1, min(widget.bigBlind, (_max! - _min!) ~/ 20));
    final divisions = _max! > _min! ? max(1, (_max! - _min!) ~/ step) : null;
    final valueRow = Row(children: [
      _round(Icons.remove, _amount > _min! ? () => _step(-1) : null),
      Expanded(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Iznos se može i upisati: dodir na broj otvara tastaturu.
          SizedBox(
            height: 30,
            child: TextField(
              controller: _field,
              focusNode: _focus,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.numberWithOptions(decimal: _m.inBB),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              cursorColor: gold,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Colors.black38,
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                suffixText: _m.inBB ? 'BB' : null,
                suffixStyle: const TextStyle(fontSize: 12, color: Colors.white60, fontWeight: FontWeight.w700),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: gold.withOpacity(0.35))),
                enabledBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: gold.withOpacity(0.35))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: gold)),
              ),
              onTap: () => _field.selection = TextSelection(baseOffset: 0, extentOffset: _field.text.length),
              onChanged: (t) {
                final v = _parse(t);
                if (v != null) setState(() => _amount = v);
              },
              onSubmitted: (_) => _focus.unfocus(),
            ),
          ),
          const SizedBox(height: 2),
          Text(_m.inBB ? chips(_amount) : '${bbNumber(_amount / widget.bigBlind)} BB',
              style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
        ]),
      ),
      _round(Icons.add, _amount < _max! ? () => _step(1) : null),
    ]);
    final slider = SizedBox(
      height: 28,
      child: divisions == null
          ? null
          : SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 4, overlayShape: SliderComponentShape.noOverlay),
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
    );
    final presetRow = Row(children: [
      for (final e in presets.entries)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              onTap: () {
                _focus.unfocus();
                _set(e.value);
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: _amount == e.value ? goldGradient : null,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: gold.withOpacity(0.45)),
                ),
                child: Text(e.key,
                    style: TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w700, color: _amount == e.value ? Colors.black : Colors.white)),
              ),
            ),
          ),
        ),
    ]);
    return LuxPanel(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      radius: 14,
      child: Column(mainAxisSize: MainAxisSize.min, children: [valueRow, slider, presetRow]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.wide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: _buttons()),
        if (_canRaise) ...[const SizedBox(width: 14), SizedBox(width: 320, child: _amountBox())],
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (_canRaise && _open) ...[_amountBox(), const SizedBox(height: 8)],
      _buttons(),
    ]);
  }
}
