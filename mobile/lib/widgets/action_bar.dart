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
  final Future<bool> Function(String action, [int? amount]) onAction;

  const ActionBar({
    super.key,
    required this.legal,
    required this.pot,
    required this.myBet,
    required this.myStack,
    required this.bigBlind,
    required this.potLimit,
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
    if (to == _allIn) return 'All-in ${chips(to)}';
    return _currentBet == 0 ? 'Bet ${chips(to)}' : 'Raise na ${chips(to)}';
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
      // Korak klizača: veliki blajnd (ili 1 kad je opseg mali).
      final step = max(1, min(widget.bigBlind, (_max! - _min!) ~/ 20));
      final divisions = _max! > _min! ? max(1, (_max! - _min!) ~/ step) : null;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final e in presets.entries)
                ChoiceChip(
                  label: Text(e.key),
                  selected: _amount == e.value,
                  onSelected: (_) => setState(() => _amount = e.value),
                ),
            ],
          ),
          if (divisions != null)
            Slider(
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
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => setState(() => _raising = false),
                  child: const Text('Nazad'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black),
                  onPressed: _busy ? null : () => _send('raise', _amount),
                  child: Text(_raiseLabel(_amount)),
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
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8E2A2A)),
            onPressed: _busy ? null : () => _send('fold'),
            child: const Text('Fold'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E6B8E)),
            onPressed: _busy ? null : () => _send(canCheck ? 'check' : 'call'),
            child: FittedBox(
              child: Text(canCheck ? 'Check' : (_call >= widget.myStack ? 'All-in ${chips(_call)}' : 'Call ${chips(_call)}')),
            ),
          ),
        ),
        if (canRaise) ...[
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _raising = true;
                        _amount = _min!;
                      }),
              child: Text(_currentBet == 0 ? 'Bet' : 'Raise'),
            ),
          ),
        ],
      ],
    );
  }
}
