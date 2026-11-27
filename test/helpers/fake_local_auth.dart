import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// テスト用のLocalAuthentication
class FakeLocalAuthentication implements LocalAuthentication {
  /// isDeviceSupportedの戻り値（呼び出しごとに先頭から消費、最後の値は維持）
  List<bool> deviceSupported;
  bool authResult;
  PlatformException? authError;
  int authenticateCalls = 0;
  AuthenticationOptions? lastOptions;

  FakeLocalAuthentication({
    this.deviceSupported = const [true],
    this.authResult = true,
    this.authError,
  });

  @override
  Future<bool> isDeviceSupported() async {
    final value = deviceSupported.first;
    if (deviceSupported.length > 1) {
      deviceSupported = deviceSupported.sublist(1);
    }
    return value;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object> authMessages = const <Object>[],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authenticateCalls++;
    lastOptions = options;
    if (authError != null) throw authError!;
    return authResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
