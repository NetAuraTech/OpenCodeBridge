import 'package:flutter/material.dart';

/// Placeholder for the Docker tab (container list, detail, logs).
/// The real content arrives in a later slice.
class DockerStub extends StatelessWidget {
  const DockerStub({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'Container monitoring arrives in a later slice.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
