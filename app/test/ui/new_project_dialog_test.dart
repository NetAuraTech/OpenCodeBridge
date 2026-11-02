import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/fs_client.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/ui/new_project_dialog.dart';

const _created = Session(
  id: 'ses_new_dir',
  title: 'new in /proj',
  project: SessionProject(id: 'p_dir', name: 'p_dir'),
  created: 500,
  location: '/proj',
  active: false,
);

/// A scripted [FsClient] for the dialog tests (no real bridge).
class _FakeFsClient extends FsClient {
  _FakeFsClient({
    this.drivesResult = const [],
    this.subdirectoriesResult = const {},
  }) : super(Uri.parse('http://bridge.test/'));

  /// The drives (the picker's top level).
  final List<String> drivesResult;

  /// The subdirectories, keyed by the directory asked for.
  final Map<String, List<String>> subdirectoriesResult;

  Object? drivesError;
  Object? subdirectoriesError;
  Object? createDirectoryError;

  var drivesCalls = 0;
  final List<String> subdirectoriesCalls = [];
  final List<String> createdDirectories = [];

  @override
  Future<List<String>> drives() async {
    drivesCalls++;
    final error = drivesError;
    if (error is Object) throw error;
    return drivesResult;
  }

  @override
  Future<List<String>> subdirectories(String path) async {
    subdirectoriesCalls.add(path);
    final error = subdirectoriesError;
    if (error is Object) throw error;
    final entries = [
      for (final created in createdDirectories)
        if (created.startsWith('$path/')) created,
      ...subdirectoriesResult[path] ?? const <String>[],
    ];
    entries.sort();
    return entries;
  }

  @override
  Future<void> createDirectory(String path) async {
    final error = createDirectoryError;
    if (error is Object) throw error;
    createdDirectories.add(path);
  }
}

/// Pushes the dialog on top of an empty app and settles the first browse.
/// Returns the push's result: it completes with the popped value, the
/// created session, or `null` when the dialog is cancelled.
Future<Future<Session?>> _pumpDialog(
  WidgetTester tester,
  _FakeFsClient fs,
  Future<Session> Function(String directory) onCreate,
) async {
  late BuildContext homeContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            homeContext = context;
            return const SizedBox(key: ValueKey('home'));
          },
        ),
      ),
    ),
  );
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  final result = navigator.push<Session>(
    DialogRoute<Session>(
      context: homeContext,
      builder: (context) => NewProjectDialog(fs: fs, onCreate: onCreate),
    ),
  );
  await tester.pumpAndSettle();
  return result;
}

void main() {
  group('NewProjectDialog', () {
    testWidgets(
      'starts at the drives level, where nothing can be created yet',
      (tester) async {
        final fs = _FakeFsClient(drivesResult: const ['/', '/proj']);
        await _pumpDialog(tester, fs, (_) async => _created);

        expect(
          find.byKey(const ValueKey('new-project-dialog')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('dir-/')), findsOneWidget);
        expect(find.byKey(const ValueKey('dir-/proj')), findsOneWidget);
        expect(fs.drivesCalls, 1);

        // No single directory on screen: "Create here" is unavailable, and
        // so is "New folder" (there is no single parent yet).
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('new-project-create')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('new-project-new-folder')),
              )
              .onPressed,
          isNull,
        );
      },
    );

    testWidgets('New folder creates the empty directory at the level', (
      tester,
    ) async {
      final fs = _FakeFsClient(
        drivesResult: const ['/proj'],
        subdirectoriesResult: const {'/proj': []},
      );
      await _pumpDialog(tester, fs, (_) async => _created);

      await tester.tap(find.byKey(const ValueKey('dir-/proj')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('new-project-new-folder')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('new-project-folder-name')),
        'fresh',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('new-project-folder-create')));
      await tester.pumpAndSettle();

      expect(fs.createdDirectories, ['/proj/fresh']);
      expect(fs.subdirectoriesCalls, ['/proj', '/proj']);
      // The refresh shows the new directory, the entry row is closed.
      expect(find.byKey(const ValueKey('dir-/proj/fresh')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('new-project-folder-name')),
        findsNothing,
      );
    });

    testWidgets('a failed New folder keeps the entry row open', (tester) async {
      final fs = _FakeFsClient(drivesResult: const ['/proj']);
      fs.createDirectoryError = const FsClientError(409, 'already_exists');
      await _pumpDialog(tester, fs, (_) async => _created);

      await tester.tap(find.byKey(const ValueKey('dir-/proj')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('new-project-new-folder')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('new-project-folder-name')),
        'again',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('new-project-folder-create')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Could not create the folder'),
        findsOneWidget,
      );
      expect(fs.createdDirectories, isEmpty);
      // The entry row stays open for another attempt.
      expect(
        find.byKey(const ValueKey('new-project-folder-name')),
        findsOneWidget,
      );
    });

    testWidgets('a New folder name with a slash is rejected', (tester) async {
      final fs = _FakeFsClient(drivesResult: const ['/proj']);
      await _pumpDialog(tester, fs, (_) async => _created);

      await tester.tap(find.byKey(const ValueKey('dir-/proj')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('new-project-new-folder')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('new-project-folder-name')),
        'a/b',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('new-project-folder-create')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('new-project-folder-name')),
        '',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('new-project-folder-create')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('new-project-folder-cancel')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('new-project-folder-name')),
        findsNothing,
      );
      expect(fs.createdDirectories, isEmpty);
    });

    testWidgets('descends one level at a time, and Back returns up', (
      tester,
    ) async {
      final fs = _FakeFsClient(
        drivesResult: const ['/proj'],
        subdirectoriesResult: const {
          '/proj': ['/proj/one'],
          '/proj/one': ['/proj/one/two'],
        },
      );
      await _pumpDialog(tester, fs, (_) async => _created);

      await tester.tap(find.byKey(const ValueKey('dir-/proj')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dir-/proj/one')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dir-/proj/one')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dir-/proj/one/two')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('new-project-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dir-/proj/one')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('new-project-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dir-/proj')), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('new-project-back')))
            .onPressed,
        isNull,
      );
      expect(fs.drivesCalls, 2);
      expect(fs.subdirectoriesCalls, ['/proj', '/proj/one', '/proj']);
    });

    testWidgets('a browse failure shows the error with a retry', (
      tester,
    ) async {
      final fs = _FakeFsClient(drivesResult: const ['/proj']);
      fs.drivesError = const FsClientError(502, 'down');
      await _pumpDialog(tester, fs, (_) async => _created);

      expect(
        find.textContaining('The bridge could not list directories'),
        findsOneWidget,
      );

      fs.drivesError = null;
      await tester.tap(find.byKey(const ValueKey('new-project-retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('dir-/proj')), findsOneWidget);
      expect(fs.drivesCalls, 2);
    });

    testWidgets('an empty level says there is nothing to enter', (
      tester,
    ) async {
      final fs = _FakeFsClient();
      await _pumpDialog(tester, fs, (_) async => _created);
      expect(find.text('No drives found.'), findsOneWidget);
    });

    testWidgets('an empty directory can still be created in', (tester) async {
      final fs = _FakeFsClient(
        drivesResult: const ['/proj'],
        subdirectoriesResult: const {'/proj': []},
      );
      await _pumpDialog(tester, fs, (_) async => _created);

      await tester.tap(find.byKey(const ValueKey('dir-/proj')));
      await tester.pumpAndSettle();

      expect(find.text('No subdirectories.'), findsOneWidget);
      // The empty directory on screen is a valid target.
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('new-project-create')),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('cancel pops the dialog without creating', (tester) async {
      final fs = _FakeFsClient(drivesResult: const ['/proj']);
      String? createdIn;
      final result = await _pumpDialog(tester, fs, (directory) async {
        createdIn = directory;
        return _created;
      });

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await result, isNull);
      expect(createdIn, isNull);
      expect(find.byKey(const ValueKey('new-project-dialog')), findsNothing);
    });

    testWidgets('a failed create keeps the dialog open with a snackbar', (
      tester,
    ) async {
      final fs = _FakeFsClient(drivesResult: const ['/proj']);
      await _pumpDialog(
        tester,
        fs,
        (_) async => throw const SessionsClientError(404, 'no such directory'),
      );

      await tester.tap(find.byKey(const ValueKey('dir-/proj')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-project-create')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Could not create the project'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('new-project-dialog')), findsOneWidget);
    });

    testWidgets('a successful create pops the dialog with the session', (
      tester,
    ) async {
      final fs = _FakeFsClient(drivesResult: const ['/proj']);
      String? createdIn;
      final result = await _pumpDialog(tester, fs, (directory) async {
        createdIn = directory;
        return _created;
      });

      await tester.tap(find.byKey(const ValueKey('dir-/proj')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-project-create')));
      await tester.pumpAndSettle();

      expect(createdIn, '/proj');
      expect(await result, _created);
      expect(find.byKey(const ValueKey('new-project-dialog')), findsNothing);
    });
  });
}
