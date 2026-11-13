import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/trusted_certificates.dart';

/// Lets the user trust a server's private certificate authority: downloads
/// the CA certificate, shows its name and fingerprint to compare with the
/// server, and trusts it on confirmation. Returns true when trusted.
Future<bool> showTrustCertificateDialog(BuildContext context, {required Uri server}) async {
  final trusted = await showDialog<bool>(
    context: context,
    builder: (_) => _TrustCertificateDialog(server: server),
  );
  return trusted ?? false;
}

class _TrustCertificateDialog extends ConsumerStatefulWidget {
  const _TrustCertificateDialog({required this.server});

  final Uri server;

  @override
  ConsumerState<_TrustCertificateDialog> createState() => _TrustCertificateDialogState();
}

class _TrustCertificateDialogState extends ConsumerState<_TrustCertificateDialog> {
  late final _url = TextEditingController(
    // Where the Caddy snippet in the README publishes its root certificate.
    text: widget.server.replace(scheme: 'https', path: '/caddy-root.crt', query: null).toString(),
  );
  TrustedCertificate? _certificate;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _error = null;
      _certificate = null;
    });
    try {
      final url = Uri.parse(_url.text.trim());
      final pem = await ref.read(certificateFetcherProvider)(url);
      final certificate = TrustedCertificate.fromPem(pem);
      if (mounted) setState(() => _certificate = certificate);
    } on FormatException {
      if (mounted) setState(() => _error = "That address didn't return a certificate.");
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not download it: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _trust() async {
    await ref.read(trustedCertificatesProvider.notifier).add(_certificate!);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final certificate = _certificate;
    return AlertDialog(
      title: const Text("Trust your server's certificate authority"),
      // Scrolls on short screens (phones in landscape).
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Your server uses a private certificate authority (such as '
              "Caddy's local CA), which this device doesn't know. Load its root "
              'certificate, check the fingerprint matches, and trust it.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              enabled: !_busy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              onSubmitted: (_) => _fetch(),
              decoration: const InputDecoration(
                labelText: 'Root certificate address',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                autofocus: true,
                onPressed: _busy ? null : _fetch,
                icon: const Icon(Icons.download),
                label: const Text('Load certificate'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (certificate != null) ...[
              const SizedBox(height: 16),
              Text(certificate.name, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('SHA-256 fingerprint', style: theme.textTheme.labelMedium),
              SelectableText(
                certificate.fingerprint,
                style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 8),
              Text(
                'Only trust it if this matches the fingerprint on your server '
                "or PC (see the app's README).",
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: certificate == null ? null : _trust,
          child: const Text('Trust'),
        ),
      ],
    );
  }
}
