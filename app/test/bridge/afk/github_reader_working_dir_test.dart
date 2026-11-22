import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/github_reader.dart';

/// The real [GhGitHubReader] (spec #407, T2): it must run every `gh` call from
/// its **working directory** — the #405 incident's root cause was the reader
/// inheriting the app's implicit cwd, so the "which repo" the reader reads and
/// the repo the session lives in diverged.
///
/// The seam: the reader's `gh` binary is injectable ([GhGitHubReader.ghBinary]).
/// The tests point it at a fake `gh` that records the working directory it was
/// actually run in (its own `$PWD`) and that only "carries" the labelled issue
/// in the one checkout that has it — so a reader built from checkout A admits
/// the issue, and the same reader pointed at checkout B does not see it.
void main() {
  late Directory tmp;
  late File fakeGh;
  late File cwdLog;

  Future<Directory> makeCheckout(String name) async {
    final dir = Directory('${tmp.path}/$name');
    await dir.create(recursive: true);
    return dir;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oc-gh-reader');
    cwdLog = File('${tmp.path}/gh-cwd.log');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  /// Write the fake `gh`: it appends its `$PWD` to [cwdLog] and answers the
  /// ready-issue listing with the issue only when run inside [issueIn]'s
  /// directory (a labelled issue is a fact of that checkout, not the other
  /// checkout).
  File writeFakeGh(Directory issueIn) {
    fakeGh = File('${tmp.path}/gh');
    final script =
        '''
#!/bin/sh
echo "\$PWD" >> ${cwdLog.path}
case "\$PWD" in
  ${issueIn.path})
    echo '[{"number":7,"title":"A issue"}]'
    ;;
  *)
    echo '[]'
    ;;
esac
''';
    fakeGh.writeAsStringSync(script);
    Process.runSync('chmod', ['+x', fakeGh.path]);
    return fakeGh;
  }

  test('a reader runs gh from its working directory: it admits the labelled '
      'issue in its own checkout and sees nothing in another checkout', () async {
    final checkoutA = await makeCheckout('checkout-a');
    final checkoutB = await makeCheckout('checkout-b');
    final fake = writeFakeGh(checkoutA);

    // The reader built from checkout A: the issue lives there.
    final readerA = GhGitHubReader(
      workingDirectory: checkoutA,
      ghBinary: fake.path,
    );
    final issuesA = await readerA.listReadyIssues();
    expect(issuesA, [
      const ReadyIssue(number: 7, title: 'A issue'),
    ], reason: 'the labelled issue is admitted from its own checkout');

    // The same reader pointed at checkout B: the issue is not there.
    final readerB = GhGitHubReader(
      workingDirectory: checkoutB,
      ghBinary: fake.path,
    );
    final issuesB = await readerB.listReadyIssues();
    expect(issuesB, isEmpty, reason: 'the other checkout does not see it');

    // The `gh` invocation was actually run from the reader's working directory
    // (the directory-scoped assertion on the `gh` invocation): the log records
    // each checkout, in the order the two readers ran.
    final cwds = cwdLog
        .readAsStringSync()
        .trim()
        .split(RegExp(r'\n'))
        .where((line) => line.isNotEmpty)
        .toList();
    expect(cwds, [checkoutA.path, checkoutB.path]);
  });

  test('every gh command carries the working directory (a write, not just '
      'the listing)', () async {
    final checkoutA = await makeCheckout('checkout-a');
    final fake = writeFakeGh(checkoutA);
    final reader = GhGitHubReader(
      workingDirectory: checkoutA,
      ghBinary: fake.path,
    );
    await reader.addLabel(7, 'needs-triage');
    final cwds = cwdLog
        .readAsStringSync()
        .trim()
        .split(RegExp(r'\n'))
        .where((line) => line.isNotEmpty)
        .toList();
    expect(cwds, [checkoutA.path]);
  });
}
