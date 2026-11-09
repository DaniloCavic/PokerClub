import 'dart:math';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _amount = _min ?? 0;
  }

  @override
  void didUpdateWidget(covariant ActionBar old) {
    super.didUpdateWidget(old);
    if (old.legal.toString() != widget.legal.toString()) {
      _busy = false;
      _open = false;
      _amount = _min ?? 0;
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

  void _step(int dir) => setState(() => _amount = (_amount + dir * widget.bigBlind).clamp(_min!, _max!));

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
          Text(_m(_amount), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text(_m.inBB ? rsd(_amount) : '${bbNumber(_amount / widget.bigBlind)} BB',
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
                  setState(() => _amount = to.clamp(_min!, _max!));
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
              onTap: () => setState(() => _amount = e.value),
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
