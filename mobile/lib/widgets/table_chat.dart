import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme.dart';

typedef Json = Map<String, dynamic>;

/// Chat stola: poruke svih koji gledaju sto i polje za novu poruku.
void showTableChat(BuildContext context, String tableId) {
  final app = context.read<AppState>();
  app.openChat = tableId;
  app.unreadOf(tableId).value = 0;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: FractionallySizedBox(heightFactor: 0.6, child: TableChatView(tableId: tableId)),
    ),
  ).whenComplete(() {
    app.openChat = null;
    app.unreadOf(tableId).value = 0;
  });
}

/// Chat stola (u bočnom panelu ili u listi odozdo).
class TableChatView extends StatefulWidget {
  final String tableId;
  final bool compact;
  const TableChatView({super.key, required this.tableId, this.compact = false});

  @override
  State<TableChatView> createState() => _ChatSheetState();
}

class _ChatSheetState extends State<TableChatView> {
  final _text = TextEditingController();
  bool _sending = false;

  Future<void> _send([String? quick]) async {
    final text = (quick ?? _text.text).trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await context.read<AppState>().sendChat(widget.tableId, text);
    if (ok && quick == null) _text.clear();
    if (mounted) setState(() => _sending = false);
  }

  /// Brze reakcije: jedan dodir šalje poruku (pojavi se i iznad igrača za stolom).
  static const _quick = ['👍', '😂', '😮', '😡', '🔥', '👏', 'nh', 'gg', 'gl', 'ty', 'wp', 'lol'];

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final myId = app.user?['id'];
    return Column(children: [
      if (!widget.compact) ...[
        const SizedBox(height: 8),
        Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
        const Padding(
          padding: EdgeInsets.all(10),
          child: Text('Table chat', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ),
      ],
      Expanded(
        child: ValueListenableBuilder<List<Json>>(
          valueListenable: app.chatOf(widget.tableId),
          builder: (_, msgs, __) {
            if (msgs.isEmpty) {
              return const Center(child: Text('No messages yet. Say hi!', style: TextStyle(color: Colors.white54)));
            }
            return ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: msgs.length,
              itemBuilder: (_, i) {
                final m = msgs[msgs.length - 1 - i];
                final mine = m['userId'] == myId;
                final t = DateTime.fromMillisecondsSinceEpoch(m['at'] as int);
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    constraints: const BoxConstraints(maxWidth: 280),
                    decoration: BoxDecoration(
                      color: mine ? accentDark : panelLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (!mine)
                        Text(m['name'] as String, style: const TextStyle(fontSize: 11, color: gold, fontWeight: FontWeight.w700)),
                      Text(m['text'] as String),
                      Text('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(fontSize: 10, color: Colors.white54)),
                    ]),
                  ),
                );
              },
            );
          },
        ),
      ),
      SizedBox(
        height: 36,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          children: [
            for (final q in _quick)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _sending ? null : () => _send(q),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: gold.withOpacity(0.35)),
                    ),
                    child: Text(q, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
          ],
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _text,
                maxLength: 200,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(hintText: 'Message…', counterText: ''),
              ),
            ),
            IconButton(onPressed: _sending ? null : _send, icon: const Icon(Icons.send, color: accent)),
          ]),
        ),
      ),
    ]);
  }
}
