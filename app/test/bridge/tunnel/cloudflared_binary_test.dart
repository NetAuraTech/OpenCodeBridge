import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_binary.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('opencodebridge-cloudflared');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<CloudflaredBinary> binaryWith({
    List<Uri>? downloads,
    bool failDownload = false,
    List<String>? chmods,
  }) async {
    final downloadLog = downloads ?? <Uri>[];
    final chmodLog = chmods ?? <String>[];
    return CloudflaredBinary(
      dir: dir,
      resolveArch: () async => 'amd64',
      downloader: (Uri url, File target) async {
        downloadLog.add(url);
        if (failDownload) throw const SocketException('no network');
        await target.writeAsString('the cloudflared binary');
      },
      makeExecutable: (String path) async => chmodLog.add(path),
    );
  }

  group('CloudflaredBinary.ensure', () {
    test('returns the pinned binary without downloading', () async {
      final binary = File('${dir.path}/cloudflared');
      await File('${dir.path}/version')
          .writeAsString(CloudflaredBinary.pinnedVersion);
      await binary.writeAsString('pinned');

      final ensured = await (await binaryWith()).ensure();

      expect(ensured.path, binary.path);
      expect(await binary.readAsString(), 'pinned');
    });

    test('downloads the pinned asset when the binary is missing', () async {
      final downloads = <Uri>[];
      final chmods = <String>[];
      final ensured = await (await binaryWith(
        downloads: downloads,
        chmods: chmods,
      )).ensure();

      expect(downloads, [
        Uri.parse(
          'https://github.com/cloudflare/cloudflared/releases/download/'
          'v${CloudflaredBinary.pinnedVersion}/cloudflared-linux-amd64',
        ),
      ]);
      expect(chmods, ['${dir.path}/cloudflared.download']);
      expect(await ensured.readAsString(), 'the cloudflared binary');
      expect(
        await File('${dir.path}/version').readAsString(),
        CloudflaredBinary.pinnedVersion,
      );
    });

    test('re-downloads an outdated binary', () async {
      await File('${dir.path}/cloudflared').writeAsString('old');
      await File('${dir.path}/version').writeAsString('2020.1.1');
      final downloads = <Uri>[];

      final ensured = await (await binaryWith(downloads: downloads)).ensure();

      expect(downloads.length, 1);
      expect(await ensured.readAsString(), 'the cloudflared binary');
    });

    test('a failed download leaves no binary behind', () async {
      final binary = await binaryWith(failDownload: true);

      await expectLater(
        binary.ensure(),
        throwsA(isA<CloudflaredBinaryError>()),
      );
      expect(File('${dir.path}/cloudflared').existsSync(), isFalse);
      expect(File('${dir.path}/cloudflared.download').existsSync(), isFalse);
    });
  });

  group('CloudflaredBinary.pinnedVersion', () {
    test('is pinned in the source', () {
      expect(CloudflaredBinary.pinnedVersion, '2026.10.7');
    });
  });
}
