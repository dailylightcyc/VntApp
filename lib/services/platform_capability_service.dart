import 'dart:convert';
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
      final bootstrapError =
          Platform.environment['VNT_PERMISSION_BOOTSTRAP_ERROR'];
      if (bootstrapError != null && bootstrapError.isNotEmpty) {
        throw PlatformCapabilityException(
          'PolicyKit 授权后无法赋予临时网络能力：$bootstrapError。'
          '详细记录见 linux-bootstrap.log。',
        );
      }
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

  /// 返回 Rust `local_dev` 使用的 Windows 物理网卡索引。
  /// 显式配置优先；留空时只在“已连接、有 IPv4 默认网关”的物理网卡中选择。
  static Future<String?> resolveWindowsPhysicalInterface(
    String configuredLocalDev,
  ) async {
    if (!Platform.isWindows) return null;
    final configured = configuredLocalDev.trim();
    if (configured.isNotEmpty) {
      AppLogger.info(
        'network-route',
        'Windows 使用用户指定的物理网卡；localDev=$configured',
      );
      return configured;
    }

    const script = r'''
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new()
$physical=@(Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | ForEach-Object {
  $adapter=$_
  $config=Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
  $ipif=Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
  if($null -ne $config.IPv4Address -and $null -ne $config.IPv4DefaultGateway -and $null -ne $ipif) {
    [PSCustomObject]@{index=[int]$adapter.ifIndex;name=[string]$adapter.Name;description=[string]$adapter.InterfaceDescription;metric=[int]$ipif.InterfaceMetric;speed=[string]$adapter.LinkSpeed}
  }
} | Sort-Object metric,index)
$virtual=@(Get-NetAdapter | Where-Object {$_.Status -eq 'Up' -and -not $_.HardwareInterface -and (($_.Name + ' ' + $_.InterfaceDescription) -match '(?i)wintun|tap|tunnel|meta|clash|vpn')} | ForEach-Object {
  [PSCustomObject]@{index=[int]$_.ifIndex;name=[string]$_.Name;description=[string]$_.InterfaceDescription}
})
[PSCustomObject]@{physical=$physical;virtual=$virtual} | ConvertTo-Json -Depth 4 -Compress
''';

    try {
      final result = await Process.run('powershell.exe', <String>[
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'powershell.exe',
          const <String>[],
          result.stderr.toString().trim(),
          result.exitCode,
        );
      }
      final output = result.stdout.toString().trim();
      if (output.isEmpty) throw const FormatException('PowerShell 未返回网卡信息');
      final decoded = jsonDecode(output) as Map<String, dynamic>;
      final physical = _asWindowsInterfaceList(decoded['physical']);
      final virtual = _asWindowsInterfaceList(decoded['virtual']);

      AppLogger.info(
        'network-route',
        'Windows 可用物理出口=${_formatWindowsInterfaces(physical)}',
      );
      if (virtual.isNotEmpty) {
        AppLogger.warning(
          'network-route',
          'Windows 检测到活动虚拟网卡=${_formatWindowsInterfaces(virtual)}；'
              'VNT 控制通道不会使用这些接口',
        );
      }
      if (physical.isEmpty) {
        if (virtual.isNotEmpty) {
          throw const PlatformCapabilityException(
            '检测到活动的 Meta/Clash/VPN 虚拟网卡，但没有找到可用物理出口。'
            '请在配置的“本地物理网卡”中填写 WLAN/以太网名称或 ifIndex。',
          );
        }
        AppLogger.warning(
          'network-route',
          '没有找到同时具备 IPv4 地址和默认网关的活动物理网卡，'
              '将由 Windows 系统路由；若出现 10060，请在配置中指定本地物理网卡',
        );
        return null;
      }

      final selected = physical.first;
      final index = selected['index'].toString();
      AppLogger.info(
        'network-route',
        'Windows 自动绑定物理出口；ifIndex=$index，名称=${selected['name']}，'
            '描述=${selected['description']}，metric=${selected['metric']}，'
            '速率=${selected['speed']}',
      );
      return index;
    } on PlatformCapabilityException {
      rethrow;
    } catch (error, stack) {
      AppLogger.warning(
        'network-route',
        'Windows 自动选择物理网卡失败，将由系统路由: $error',
        stack,
      );
      return null;
    }
  }

  static String _formatWindowsInterfaces(List<Map<String, dynamic>> items) {
    if (items.isEmpty) return '[]';
    return items
        .map(
          (item) =>
              '{ifIndex=${item['index']},name=${item['name']},'
              'description=${item['description']},metric=${item['metric'] ?? '-'}}',
        )
        .join(', ');
  }

  static List<Map<String, dynamic>> _asWindowsInterfaceList(Object? value) {
    if (value is Map<String, dynamic>) return <Map<String, dynamic>>[value];
    if (value is List<dynamic>) {
      return value.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }
}
