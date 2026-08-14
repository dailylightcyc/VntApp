import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:vnt_app/utils/log_utils.dart';

/// 应用层统一日志。核心网络日志由 Rust 写入 vnt-core.log。
class AppLogger {
  AppLogger._();

  static IOSink? _sink;
  static Future<void> _writeQueue = Future<void>.value();
  static const int _maxBytes = 5 * 1024 * 1024;

  static Future<void> initialize() async {
    final logDirectory = Directory(await LogUtils.getLogDirectory());
    await logDirectory.create(recursive: true);
    final logFile = File(
      '${logDirectory.path}${Platform.pathSeparator}vnt-app.log',
    );
    await _rotateIfNeeded(logFile);
    _sink = logFile.openWrite(mode: FileMode.append, encoding: utf8);
    info(
      'startup',
      '应用日志初始化完成；构建=${kDebugMode ? 'debug-full' : 'release-audited'}；'
          '平台=${Platform.operatingSystem}，版本=${Platform.operatingSystemVersion}',
    );
  }

  static void installGlobalHandlers() {
    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      error('flutter', details.exceptionAsString(), details.stack);
      previousFlutterHandler?.call(details);
    };
    PlatformDispatcher.instance.onError = (exception, stack) {
      error('platform', exception, stack);
      return true;
    };
  }

  static void info(String category, Object message) =>
      _write('INFO', category, message);
  static void warning(String category, Object message, [StackTrace? stack]) =>
      _write('WARN', category, message, stack);
  static void error(String category, Object message, [StackTrace? stack]) =>
      _write('ERROR', category, message, stack);

  static void _write(
    String level,
    String category,
    Object message, [
    StackTrace? stack,
  ]) {
    final rawMessage = message.toString();
    final rawStack = stack?.toString();
    // Debug 用于本地定位，保留原始消息和完整堆栈。Release/Profile
    // 日志用于发布和审核，保留结构但移除 token/密码/私钥等字段。
    final safeMessage = kDebugMode
        ? rawMessage
        : LogUtils.redactSensitiveData(rawMessage.replaceAll('\n', r'\n'));
    final safeStack = rawStack == null
        ? ''
        : '\n${kDebugMode ? rawStack : LogUtils.redactSensitiveData(rawStack)}';
    final line =
        '${DateTime.now().toIso8601String()} [$level] [$category] $safeMessage$safeStack';
    debugPrint(line);
    _writeQueue = _writeQueue
        .then((_) async {
          _sink?.writeln(line);
          await _sink?.flush();
        })
        .catchError((Object _) {});
  }

  static Future<void> _rotateIfNeeded(File file) async {
    if (!await file.exists() || await file.length() < _maxBytes) return;
    for (var index = 3; index >= 1; index--) {
      final source = File('${file.path}.$index');
      if (!await source.exists()) continue;
      if (index == 3) {
        await source.delete();
      } else {
        await source.rename('${file.path}.${index + 1}');
      }
    }
    await file.rename('${file.path}.1');
  }
}
