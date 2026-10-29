import 'package:flutter/material.dart';

/// Placeholder for the Sessions tab (home list, new session, two views).
/// The real content arrives in a later slice.
class SessionsStub extends StatelessWidget {
  const SessionsStub({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'The session list arrives in a later slice.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
