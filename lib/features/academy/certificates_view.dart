// lib/features/academy/certificates_view.dart
//
// Every certificate earned by the signed-in student, plus UUID lookup.

import 'package:flutter/material.dart';
import '../../services/course_api_service.dart';
import 'certificate_card.dart';
import 'course_models.dart';

const _kBrand = Color(0xFF1E3A8A);

class CertificatesView extends StatefulWidget {
  const CertificatesView({super.key});

  @override
  State<CertificatesView> createState() => _CertificatesViewState();
}

class _CertificatesViewState extends State<CertificatesView> {
  List<Certificate> _certificates = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final certificates = await CourseApiService.fetchMyCertificates();
    if (!mounted) return;
    setState(() {
      _certificates = certificates;
      _loading = false;
    });
  }

  void _show(Certificate certificate) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: CertificateCard(certificate: certificate),
      ),
    );
  }

  Future<void> _verifyByUuid() async {
    final controller = TextEditingController();
    final uuid = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify a certificate'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Paste the certificate ID',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (uuid == null || uuid.isEmpty || !mounted) return;

    final certificate = await CourseApiService.verifyCertificate(uuid);
    if (!mounted) return;

    if (certificate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No certificate found for that ID.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    _show(certificate);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Certificates'),
        backgroundColor: _kBrand,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Verify by ID',
            onPressed: _verifyByUuid,
            icon: const Icon(Icons.verified_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _certificates.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 120),
                        Icon(Icons.workspace_premium_outlined,
                            size: 72, color: Colors.grey.shade300),
                        const SizedBox(height: 14),
                        Center(
                          child: Text(
                            'No certificates yet.\nFinish a course to earn one.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.grey.shade500, height: 1.5),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _certificates.length,
                      itemBuilder: (_, i) {
                        final certificate = _certificates[i];
                        return Card(
                          elevation: 0,
                          margin: const EdgeInsets.only(bottom: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: Colors.grey.shade200),
                          ),
                          child: ListTile(
                            onTap: () => _show(certificate),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                  color: Colors.amber.shade50,
                                  shape: BoxShape.circle),
                              child: const Icon(Icons.workspace_premium,
                                  color: Colors.amber, size: 24),
                            ),
                            title: Text(certificate.courseTitle,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14)),
                            subtitle: certificate.issuedDateLabel.isEmpty
                                ? null
                                : Text('Issued ${certificate.issuedDateLabel}',
                                    style: const TextStyle(fontSize: 11)),
                            trailing: const Icon(Icons.chevron_right),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
