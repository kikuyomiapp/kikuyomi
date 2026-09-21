import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Asks in a dialog for a bookmark's name or its note, starting from [initial], and returns what was
/// entered, or null when the dialog was cancelled. An empty answer takes the name or note away.
///
/// It works from the keyboard as well as by touch. The field has focus as the dialog opens, with
/// anything already in it selected so that typing replaces it; Tab moves on to the buttons, and
/// Escape cancels. A name is a single line, which Enter saves. A note may run to several lines, so
/// there Enter starts a new line, and Ctrl+Enter saves.
Future<String?> showBookmarkTextDialog(
  BuildContext context, {
  required String heading,
  required String label,
  String? initial,
  String? hint,
  bool multiline = false,
}) => showDialog<String>(
  context: context,
  builder: (context) => _BookmarkTextDialog(
    heading: heading,
    label: label,
    initial: initial ?? '',
    hint: hint,
    multiline: multiline,
  ),
);

class _BookmarkTextDialog extends StatefulWidget {
  const _BookmarkTextDialog({
    required this.heading,
    required this.label,
    required this.initial,
    required this.hint,
    required this.multiline,
  });

  final String heading;
  final String label;
  final String initial;
  final String? hint;
  final bool multiline;

  @override
  State<_BookmarkTextDialog> createState() => _BookmarkTextDialogState();
}

class _BookmarkTextDialogState extends State<_BookmarkTextDialog> {
  late final _text = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, _text.text);

  @override
  Widget build(BuildContext context) {
    final multiline = widget.multiline;
    return AlertDialog(
      title: Text(widget.heading),
      content: CallbackShortcuts(
        // Both, rather than asking which platform this is: Command is where Control is on a Mac
        // keyboard, and no other keyboard has it.
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
        },
        child: SizedBox(
          width: 400,
          child: TextField(
            controller: _text,
            autofocus: true,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
            ),
            textCapitalization: TextCapitalization.sentences,
            keyboardType: multiline
                ? TextInputType.multiline
                : TextInputType.text,
            textInputAction: multiline
                ? TextInputAction.newline
                : TextInputAction.done,
            minLines: multiline ? 3 : 1,
            maxLines: multiline ? 8 : 1,
            onSubmitted: multiline ? null : (_) => _save(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
