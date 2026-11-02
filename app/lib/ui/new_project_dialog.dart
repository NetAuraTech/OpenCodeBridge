import 'dart:async';

import 'package:flutter/material.dart';

import '../client/fs_client.dart';
import '../client/sessions_client.dart';
import '../model/session.dart';

/// The "New project" file-picker dialog (issue #54): the host's drives at the
/// top level, then one level of subdirectories per tap — a file-picker flow
/// that ends in "Create here", which creates the session at the directory on
/// screen and pops it (the Sessions tab then opens its structured view).
///
/// A plain [Dialog] rather than an [AlertDialog] (issue #41): an
/// [AlertDialog] sizes itself to its content's intrinsic width, and the
/// directory list is a viewport, which cannot report intrinsic dimensions.
/// Here the list takes the width the dialog is given, capped on desktop, so
/// the picker fits both a phone and a desktop window.
class NewProjectDialog extends StatefulWidget {
  const NewProjectDialog({super.key, required this.fs, required this.onCreate});

  /// The bridge filesystem API the picker browses.
  final FsClient fs;

  /// Creates the session at the directory the picker is on; the dialog pops
  /// with the created [session]. When it throws (a [SessionsClientError] or
  /// anything else), the dialog stays open with a failure message.
  final Future<Session> Function(String directory) onCreate;

  @override
  State<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<NewProjectDialog> {
  /// The picker's stack: empty at the drives level, each entry a directory
  /// descended into. The level on screen is the subdirectories of
  /// [_dirs.last] (or the drives when the stack is empty).
  final List<String> _dirs = [];

  /// The entries of the level on screen, `null` while a browse is in flight.
  List<String>? _entries;

  /// The last browse failure, if any.
  String? _error;

  /// True while the create (the "Create here" action) is in flight.
  bool _creating = false;

  /// Whether the "New folder" name-entry row is open.
  bool _creatingFolder = false;

  /// True while the "New folder" create action is in flight.
  bool _folderCreating = false;

  /// The "New folder" name entry's controller.
  final TextEditingController _folderName = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The create button's availability follows the name, so the dialog
    // rebuilds on every change.
    _folderName.addListener(_folderNameChanged);
    unawaited(_load());
  }

  void _folderNameChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _folderName.removeListener(_folderNameChanged);
    _folderName.dispose();
    super.dispose();
  }

  /// The directory "Create here" would create in; `null` at the drives level
  /// (there is no single directory there yet).
  String? get _here => _dirs.isEmpty ? null : _dirs.last;

  /// (Re)loads the level on screen: the drives at the top, otherwise the
  /// subdirectories of the picked directory.
  Future<void> _load() async {
    setState(() {
      _entries = null;
      _error = null;
    });
    final fs = widget.fs;
    final path = _here;
    try {
      final entries = path == null
          ? await fs.drives()
          : await fs.subdirectories(path);
      if (!mounted) return;
      setState(() => _entries = entries);
    } on FsClientError catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e.statusCode == 0
            ? 'Cannot reach the bridge.'
            : 'The bridge could not list directories '
                  '(status ${e.statusCode}).',
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not list the directories.');
    }
  }

  /// Descends into the directory [path] (one level at a time).
  Future<void> _enter(String path) async {
    _dirs.add(path);
    await _load();
  }

  /// Backs out one level (to the parent of the level on screen).
  Future<void> _back() async {
    if (_dirs.isEmpty) return;
    _dirs.removeLast();
    await _load();
  }

  /// Whether the entered "New folder" name is valid (a name with no slash).
  bool get _folderNameValid =>
      _folderName.text.trim().isNotEmpty && !_folderName.text.contains('/');

  /// Opens the "New folder" name-entry row.
  void _openFolderEntry() {
    setState(() => _creatingFolder = true);
  }

  /// Closes the "New folder" name-entry row.
  void _closeFolderEntry() {
    _folderName.clear();
    setState(() => _creatingFolder = false);
  }

  /// "New folder": creates the empty directory at the current level, closes
  /// the entry row, and refreshes the level.
  Future<void> _createFolder() async {
    final here = _here;
    if (here == null || !_folderNameValid) return;
    setState(() => _folderCreating = true);
    try {
      await widget.fs.createDirectory(_join(here, _folderName.text.trim()));
      if (!mounted) return;
      _closeFolderEntry();
      await _load();
    } on FsClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        e.statusCode == 409
            ? 'A folder named '
                  '"${_folderName.text.trim()}" already exists there.'
            : 'Could not create the folder '
                  '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
      );
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not create the folder.');
    } finally {
      if (mounted) setState(() => _folderCreating = false);
    }
  }

  /// Joins the folder [name] to the directory [dir] (the root keeps its
  /// single leading slash).
  static String _join(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  /// "Create here": creates the session at the directory on screen, then
  /// pops the dialog with the created session.
  Future<void> _create() async {
    final path = _here;
    if (path == null) return;
    setState(() => _creating = true);
    try {
      final session = await widget.onCreate(path);
      if (!mounted) return;
      Navigator.of(context).pop(session);
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        'Could not create the project '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
      );
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not create the project.');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _snackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final error = _error;
    final here = _here;
    return Dialog(
      key: const ValueKey('new-project-dialog'),
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 24, 0),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('new-project-back'),
                  onPressed: _dirs.isEmpty ? null : _back,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                ),
                Expanded(
                  child: Text(
                    'New project',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  key: const ValueKey('new-project-new-folder'),
                  onPressed: here == null
                      ? null
                      : (_creatingFolder ? null : _openFolderEntry),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: 'New folder',
                ),
              ],
            ),
          ),
          if (_creatingFolder)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('new-project-folder-name'),
                      controller: _folderName,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Folder name',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _createFolder(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('new-project-folder-create'),
                    onPressed: _folderCreating || !_folderNameValid
                        ? null
                        : _createFolder,
                    icon: _folderCreating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add),
                    label: const Text('Create'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const ValueKey('new-project-folder-cancel'),
                    onPressed: _folderCreating ? null : _closeFolderEntry,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          if (entries == null && error == null)
            const SizedBox(
              height: 320,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            SizedBox(
              height: 320,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(error, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const ValueKey('new-project-retry'),
                      onPressed: () => unawaited(_load()),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          else if (entries!.isEmpty)
            SizedBox(
              height: 320,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _dirs.isEmpty ? 'No drives found.' : 'No subdirectories.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            SizedBox(
              height: 320,
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final path = entries[index];
                  return ListTile(
                    key: ValueKey('dir-$path'),
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(path),
                    onTap: () => _enter(path),
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              children: [
                Expanded(child: const SizedBox()),
                FilledButton.icon(
                  key: const ValueKey('new-project-create'),
                  onPressed: _creating || here == null ? null : () => _create(),
                  icon: _creating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                  label: _creating
                      ? const Text('Creating…')
                      : const Text('Create here'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
