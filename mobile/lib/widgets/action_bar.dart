import 'dart:math';
import 'package:flutter/material.dart';
import '../format.dart';
import '../theme.dart';

/// Potezi kad je igrač na redu: fold, check/call i bet/raise sa izborom iznosa.
class ActionBar extends StatefulWidget {
  final Map<String, dynamic> legal;
  final int pot;
  final int myBet;
  final int myStack;
  final int bigBlind;
  final bool potLimit;
  final Money money;
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
  });

  @override
  State<ActionBar> createState() => _ActionBarState();
}

class _ActionBarState extends State<ActionBar> {
  bool _raising = false;
  bool _busy = false;
  int _amount = 0;

  int? get _min => widget.legal['minRaiseTo'] as int?;
  int? get _max => widget.legal['maxRaiseTo'] as int?;
  int get _call => widget.legal['call'] as int;
  int get _currentBet => widget.myBet + _call;
  int get _allIn => widget.myBet + widget.myStack;
  Money get _m => widget.money;

  @override
  void didUpdateWidget(covariant ActionBar old) {
    super.didUpdateWidget(old);
    if (old.legal.toString() != widget.legal.toString()) {
      _raising = false;
      _busy = false;
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
    final potAfterCall = widget.pot + _call;
    final to = _currentBet + (potAfterCall * f).round();
    return to.clamp(_min!, _max!);
  }

  String _raiseLabel(int to) {
    if (to == _allIn) return 'ALL-IN ${_m(to)}';
    return _currentBet == 0 ? 'BET ${_m(to)}' : 'RAISE NA ${_m(to)}';
  }

  void _step(int dir) {
    setState(() => _amount = (_amount + dir * widget.bigBlind).clamp(_min!, _max!));
  }

  @override
  Widget build(BuildContext context) {
    final canCheck = widget.legal['check'] == true;
    final canRaise = _min != null && _max != null;

    if (_raising && canRaise) {
      final presets = <String, int>{
        'Min': _min!,
        '½ pota': _potFraction(0.5),
        '¾ pota': _potFraction(0.75),
        'Pot': _potFraction(1),
        if (!widget.potLimit) 'All-in': _max!,
      };
      final step = max(1, min(widget.bigBlind, (_max! - _min!) ~/ 20));
      final divisions = _max! > _min! ? max(1, (_max! - _min!) ~/ step) : null;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              for (final e in presets.entries)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size.fromHeight(36),
                        backgroundColor: _amount == e.value ? accent : Colors.transparent,
                        side: BorderSide(color: _amount == e.value ? accent : Colors.white24),
                      ),
                      onPressed: () => setState(() => _amount = e.value),
                      child: Text(e.key, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
            ],
          ),
          // Klizač sa dugmadima − / + (korak: veliki blajnd)
          Row(
            children: [
              _RoundButton(icon: Icons.remove, onTap: _amount > _min! ? () => _step(-1) : null),
              Expanded(
                child: divisions == null
                    ? const SizedBox(height: 44)
                    : Slider(
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
              _RoundButton(icon: Icons.add, onTap: _amount < _max! ? () => _step(1) : null),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => setState(() => _raising = false),
                  child: const Text('Nazad'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: accent, minimumSize: const Size.fromHeight(52)),
                  onPressed: _busy ? null : () => _send('raise', _amount),
                  child: FittedBox(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_raiseLabel(_amount), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                      Text(
                        _m.inBB ? rsd(_amount) : '${bbNumber(_amount / widget.bigBlind)} BB',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ]),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            title: 'FOLD',
            color: const Color(0xFF3A3F4B),
            onTap: _busy ? null : () => _send('fold'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionButton(
            title: canCheck ? 'CHECK' : (_call >= widget.myStack ? 'ALL-IN' : 'CALL'),
            subtitle: canCheck ? null : _m(_call),
            color: canCheck ? const Color(0xFF2E7D5B) : const Color(0xFF1B6FD8),
            onTap: _busy ? null : () => _send(canCheck ? 'check' : 'call'),
          ),
        ),
        if (canRaise) ...[
          const SizedBox(width: 8),
          Expanded(
            child: _ActionButton(
              title: _currentBet == 0 ? 'BET' : 'RAISE',
              subtitle: _min == _allIn ? 'all-in' : 'od ${_m(_min)}',
              color: accent,
              onTap: _busy
                  ? null
                  : () => setState(() {
                        _raising = true;
                        _amount = _min!;
                      }),
            ),
          ),
        ],
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Color color;
  final VoidCallback? onTap;
  const _ActionButton({required this.title, required this.color, this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        minimumSize: const Size.fromHeight(56),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
          if (subtitle != null)
            FittedBox(child: Text(subtitle!, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _RoundButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      style: IconButton.styleFrom(backgroundColor: panelLight, disabledBackgroundColor: panel, minimumSize: const Size(44, 44)),
      onPressed: onTap,
      icon: Icon(icon),
    );
  }
}
