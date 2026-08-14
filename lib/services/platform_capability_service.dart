import 'dart:io';

import 'package:vnt_app/services/app_logger.dart';

class PlatformCapabilityException implements Exception {
  const PlatformCapabilityException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 在连接前验证桌面平台创建虚拟网卡所需的系统能力。
class PlatformCapabilityService {
  PlatformCapabilityService._();

  static const int _capNetAdmin = 12;
  static PlatformCapabilityException? _linuxStartupFailure;

  /// Linux 授权由原生 Runner 在 Flutter 引擎启动前完成；
  /// Dart 层只负责记录和给出可诊断的错误。
  static Future<void> prepareAtStartup() async {
    if (!Platform.isLinux) return;
    try {
      await _verifyLinuxCapability();
      _linuxStartupFailure = null;
    } on PlatformCapabilityException catch (error) {
      _linuxStartupFailure = error;
      rethrow;
    }
  }

  static Future<void> prepareForConnection() async {
    if (Platform.isLinux) {
      final startupFailure = _linuxStartupFailure;
      if (startupFailure != null) throw startupFailure;
      await _verifyLinuxCapability();
    } else if (Platform.isWindows) {
      await _verifyWindowsAdministrator();
    } else {
      AppLogger.info('permission', '平台使用系统 VPN 授权或既有 macOS 授权流程');
    }
  }

  static Future<void> _verifyLinuxCapability() async {
    if (!await File('/dev/net/tun').exists()) {
      AppLogger.error('permission', 'Linux 缺少 /dev/net/tun');
      throw const PlatformCapabilityException(
        '系统没有可用的 TUN 设备（/dev/net/tun）。请加载 tun 内核模块后重试。',
      );
    }
    if (await _linuxHasNetAdmin()) {
      AppLogger.info('permission', 'Linux CAP_NET_ADMIN 检查通过');
      return;
    }

    AppLogger.error('permission', 'Linux Runner 未获得 CAP_NET_ADMIN');
    throw const PlatformCapabilityException(
      '未获得创建虚拟网卡的权限。请确认已允许启动时的 PolicyKit 授权，'
      '并检查系统是否安装 polkit 和 util-linux。',
    );
  }

  static Future<bool> _linuxHasNetAdmin() async {
    try {
      final status = await File('/proc/self/status').readAsLines();
      final line = status.firstWhere((item) => item.startsWith('CapEff:'));
      final value = BigInt.parse(line.split(RegExp(r'\s+')).last, radix: 16);
      return (value & (BigInt.one << _capNetAdmin)) != BigInt.zero;
    } catch (error, stack) {
      AppLogger.error('permission', '无法读取 Linux 进程能力: $error', stack);
      return false;
    }
  }

  static Future<void> _verifyWindowsAdministrator() async {
    final result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
    ]);
    final isAdministrator =
        result.exitCode == 0 &&
        result.stdout.toString().trim().toLowerCase() == 'true';
    if (!isAdministrator) {
      AppLogger.error('permission', 'Windows 进程未以管理员权限运行');
      throw const PlatformCapabilityException('应用没有创建虚拟网卡的管理员权限，请以管理员身份重新启动。');
    }
    AppLogger.info('permission', 'Windows 管理员权限检查通过');
  }
}
