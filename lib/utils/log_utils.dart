import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 日志路径工具类
/// 统一管理日志目录路径，确保核心写入和页面读取使用相同的路径
class LogUtils {
  static const String _legacyLinuxApplicationId = 'top.wherewego.vnt_app';

  /// 包名升级后保留 Linux 上的旧配置和日志。
  static Future<void> migrateLegacyLinuxData() async {
    if (!Platform.isLinux) return;
    final supportDir = await getApplicationSupportDirectory();
    final separator = Platform.pathSeparator;
    final parentPath = supportDir.parent.path;
    final legacyDir = Directory(
      '$parentPath$separator$_legacyLinuxApplicationId',
    );
    if (!await legacyDir.exists() || legacyDir.path == supportDir.path) return;

    await supportDir.create(recursive: true);
    await for (final entity in legacyDir.list(recursive: true)) {
      final relativePath = entity.path.substring(legacyDir.path.length + 1);
      final destinationPath = '${supportDir.path}$separator$relativePath';
      if (entity is Directory) {
        await Directory(destinationPath).create(recursive: true);
      } else if (entity is File) {
        final destination = File(destinationPath);
        if (!await destination.exists()) {
          await destination.parent.create(recursive: true);
          await entity.copy(destination.path);
        }
      }
    }
  }

  /// 获取日���目录路径
  ///
  /// 使用系统分配的应用支持目录，避免安装目录只读、工作目录变化或
  /// 临时目录重启后被清理导致日志丢失。
  static Future<String> getLogDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    return '${supportDir.path}${Platform.pathSeparator}logs';
  }

  /// 日志可能被异常终止的旧进程留下不完整 UTF-8 字节，
  /// 诊断页应尽量显示内容，而不是整个读取失败。
  static Future<String> readTextFile(File file) async {
    return utf8.decode(await file.readAsBytes(), allowMalformed: true);
  }

  /// 在展示、复制或导出日志前再次脱敏，也能保护旧版已生成的日志。
  static String redactSensitiveData(String value) {
    var output = value;
    final keyValuePattern = RegExp(
      r'(token|password|secret|private[_ -]?key)\s*[:=]\s*([^,;\s}\]]+)',
      caseSensitive: false,
    );
    final jsonPattern = RegExp(
      r'("(?:token|password|secret|privateKey)"\s*:\s*")[^"]*"',
      caseSensitive: false,
    );
    output = output.replaceAllMapped(
      keyValuePattern,
      (match) => '${match.group(1)}=<redacted>',
    );
    return output.replaceAllMapped(
      jsonPattern,
      (match) => '${match.group(1)}<redacted>"',
    );
  }
}
