import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 読み書きの失敗を再現できるFlutterSecureStorage
/// データ自体は FlutterSecureStorage.setMockInitialValues のモックに保存される
class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage()
      : super(aOptions: const AndroidOptions(encryptedSharedPreferences: true));

  /// キーごとに、読み込みで例外を投げる残り回数（-1なら常に投げる）
  final Map<String, int> readFailures = {};

  /// 書き込んだキーの記録
  final List<String> writtenKeys = [];

  /// [key]の読み込みを[times]回失敗させる（省略時は常に失敗）
  void failRead(String key, {int times = -1}) => readFailures[key] = times;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final remaining = readFailures[key];
    if (remaining != null && remaining != 0) {
      if (remaining > 0) readFailures[key] = remaining - 1;
      throw Exception('読み込み失敗: $key');
    }
    return super.read(key: key);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    writtenKeys.add(key);
    return super.write(key: key, value: value);
  }
}
