// lib/features/academy/certificate_card.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/course_api_service.dart';
import 'course_models.dart';

const _kBrand = Color(0xFF1E3A8A);

class CertificateCard extends StatelessWidget {
  final Certificate certificate;

  const CertificateCard({super.key, required this.certificate});

  @override
  Widget build(BuildContext context) {
    final verifyUrl = CourseApiService.verificationUrl(certificate.uuid);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: Colors.amber.shade50, shape: BoxShape.circle),
            child: const Icon(Icons.workspace_premium,
                color: Colors.amber, size: 64),
          ),
          const SizedBox(height: 16),
          Text('CERTIFICATE OF COMPLETION',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                  letterSpacing: 1.5)),
          const SizedBox(height: 10),
          Text(certificate.courseTitle,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (certificate.recipientName.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Awarded to ${certificate.recipientName}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
          ],
          const Divider(height: 28),
          if (certificate.issuedDateLabel.isNotEmpty)
            _row(Icons.event_available, 'Issued', certificate.issuedDateLabel),
          const SizedBox(height: 10),
          _row(Icons.qr_code_2, 'Certificate ID', certificate.uuid),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _kBrand,
              minimumSize: const Size.fromHeight(42),
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: verifyUrl));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Verification link copied.'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy verification link'),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: Colors.grey.shade600),
        const SizedBox(width: 8),
        Text('$label: ',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
