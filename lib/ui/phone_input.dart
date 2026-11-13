import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/phone_input.dart';
import '../core/providers.dart';
import 'theme.dart';
import 'widgets.dart';

/// Starts a phone-typing session; swapped in widget tests, which can't open
/// a socket on the fake clock.
Future<PhoneInput> Function({
  required String label,
  bool obscure,
  bool multiline,
  String initial,
})
startPhoneInput =
    ({required label, obscure = false, multiline = false, initial = ''}) =>
        PhoneInputSession.start(
          label: label,
          obscure: obscure,
          multiline: multiline,
          initial: initial,
        );

/// A stand-in session for tests.
class FakePhoneInput implements PhoneInput {
  FakePhoneInput(this.url, this.value, this._onClose);
  @override
  final String url;
  @override
  final Future<String> value;
  final void Function() _onClose;
  @override
  Future<void> close() async => _onClose();
}

/// On a TV, a 📱 button for a text field's `suffixIcon`: type it on a phone
/// instead of with the remote. Null elsewhere (phones have keyboards).
Widget? phoneTypeButton(
  BuildContext context,
  TextEditingController controller, {
  required String label,
  bool obscure = false,
  bool multiline = false,
  ValueChanged<String>? onText,
}) {
  final tv = ProviderScope.containerOf(context, listen: false).read(tvProvider);
  if (!tv) return null;
  return IconButton(
    tooltip: 'Type on your phone',
    icon: const Icon(Icons.phone_android_rounded),
    onPressed: () async {
      final text = await showDialog<String>(
        context: context,
        builder: (_) => _PhoneInputDialog(
          label: label,
          obscure: obscure,
          multiline: multiline,
          initial: controller.text,
        ),
      );
      // An empty answer (Send on a blank page) changes nothing.
      if (text == null || text.isEmpty) return;
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      onText?.call(text);
    },
  );
}

class _PhoneInputDialog extends StatefulWidget {
  const _PhoneInputDialog({
    required this.label,
    required this.obscure,
    required this.multiline,
    required this.initial,
  });
  final String label;
  final bool obscure;
  final bool multiline;
  final String initial;

  @override
  State<_PhoneInputDialog> createState() => _PhoneInputDialogState();
}

class _PhoneInputDialogState extends State<_PhoneInputDialog> {
  PhoneInput? _session;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final s = await startPhoneInput(
        label: widget.label,
        obscure: widget.obscure,
        multiline: widget.multiline,
        initial: widget.initial,
      );
      if (!mounted) {
        unawaited(s.close());
        return;
      }
      setState(() => _session = s);
      final text = await s.value;
      if (mounted) Navigator.pop(context, text);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    // Stop listening however the dialog closes.
    unawaited(_session?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return AlertDialog(
      icon: const Icon(Icons.phone_android_rounded),
      title: Text('Type "${widget.label}" on your phone'),
      content: SizedBox(
        width: 460,
        child: _error != null
            ? Text(
                friendlyError(_error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            : session == null
            ? const Padding(padding: EdgeInsets.all(24), child: Loading())
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'On a phone on the same Wi-Fi, open this '
                    'address in the browser:',
                  ),
                  const SizedBox(height: 14),
                  // Plain text: a selectable one takes the remote's focus and keeps it.
                    Text(
                    session.url,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Waiting for your phone. The TV only listens '
                          'while this is open.',
                          style: TextStyle(color: Palette.muted),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
