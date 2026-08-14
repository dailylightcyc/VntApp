import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/theme/theme_provider.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/data_persistence.dart';
import 'package:vnt_app/pages/dashboard_page.dart';
import 'package:vnt_app/pages/room_page.dart';
import 'package:vnt_app/pages/config_list_page.dart';
import 'package:vnt_app/pages/settings_page.dart';
import 'package:vnt_app/pages/about_page.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';
import 'package:vnt_app/utils/toast_utils.dart';
import 'dart:isolate';
import 'package:vnt_app/src/rust/api/vnt_api.dart';
import 'package:vnt_app/widgets/custom_title_bar.dart';
import 'package:vnt_app/system_tray_manager.dart';
import 'package:vnt_app/ios_vpn_service.dart';

/// 主导航框架 - 响应式布局，支持侧边栏和底部导航
class MainNavigationShell extends StatefulWidget {
  final VoidCallback? onThemeChanged;

  const MainNavigationShell({
    super.key,
    this.onThemeChanged,
  });

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  int _selectedIndex = 0;
  NetworkConfig? _selectedConfig;
  VoidCallback? _refreshConfigList;
  VoidCallback? _refreshSettings;

  // 导航项配置
  static const List<_NavItem> _navItems = [
    _NavItem(icon: Icons.dashboard_outlined, activeIcon: Icons.dashboard, label: '仪表盘'),
    _NavItem(icon: Icons.meeting_room_outlined, activeIcon: Icons.meeting_room, label: '房间'),
    _NavItem(icon: Icons.folder_outlined, activeIcon: Icons.folder, label: '配置'),
    _NavItem(icon: Icons.settings_outlined, activeIcon: Icons.settings, label: '设置'),
    _NavItem(icon: Icons.info_outline, activeIcon: Icons.info, label: '关于'),
  ];

  @override
  void initState() {
    super.initState();
    _autoConnect();
  }

  /// 自动连接逻辑
  Future<void> _autoConnect() async {
    final dataPersistence = DataPersistence();

    // 检查是否从磁贴启动（仅 Android）
    bool isTileStart = false;
    if (Platform.isAndroid) {
      try {
        isTileStart = await VntAppCall.isTileStart();
      } catch (e) {
        debugPrint('检查磁贴启动状态失败: $e');
      }
    }

    // 如果不是从磁贴启动，检查自动连接设置
    if (!isTileStart) {
      final autoConnect = await dataPersistence.loadAutoConnect() ?? false;
      if (!autoConnect) return;
    }

    // 确定要连接的配置key
    String? targetKey;

    // 如果是从磁贴启动，先检查是否有磁贴配置key（长按磁贴选择的配置）
    if (isTileStart && Platform.isAndroid) {
      try {
        targetKey = await VntAppCall.getTileConfigKey();
        if (targetKey != null && targetKey.isNotEmpty) {
          debugPrint('从磁贴获取到选择的配置key: $targetKey');
        }
      } catch (e) {
        debugPrint('获取磁贴配置key失败: $e');
      }
    }

    // 如果没有磁贴配置key，使用默认配置
    if (targetKey == null || targetKey.isEmpty) {
      targetKey = await dataPersistence.loadDefaultKey();
      debugPrint('使用默认配置key: $targetKey');
    }

    if (targetKey == null || targetKey.isEmpty) {
      // 如果是从磁贴启动但没有配置，提示用户
      if (isTileStart && mounted) {
        showTopToast(context, '请先在配置页面设置默认配置', isSuccess: false);
      }
      return;
    }

    final configs = await dataPersistence.loadData();
    final config = configs.where((c) => c.itemKey == targetKey).firstOrNull;
    if (config == null) {
      if (isTileStart && mounted) {
        showTopToast(context, '配置不存在，请重新设置', isSuccess: false);
      }
      return;
    }

    // 直接连接选中的配置
    if (mounted) {
      _connectToConfigDirectly(config);
    }
  }

  /// 直接连接到指定配置（不跳转页面）
  Future<void> _connectToConfigDirectly(NetworkConfig config) async {
    if (vntManager.hasConnectionItem(config.itemKey)) {
      if (mounted) {
        showTopToast(context, '[${config.configName}] 已连接', isSuccess: true);
      }
      return;
    }

    if (vntManager.isConnecting()) {
      if (mounted) {
        showTopToast(context, '正在连接中，请稍后再试', isSuccess: false);
      }
      return;
    }

    // iOS使用VPN连接
    if (Platform.isIOS) {
      await _connectViaIOSVPN(config);
      return;
    }

    // 其他平台使用Rust直接连接
    // 显示连接中对话框
    BuildContext? dialogContext;
    bool dialogOpen = false;

    void closeDialog() {
      if (!dialogOpen) return;
      dialogOpen = false;
      if (dialogContext != null && Navigator.of(dialogContext!).canPop()) {
        Navigator.of(dialogContext!).pop();
      } else {
        // dialog 还未 build 完，延迟一帧再关
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (dialogContext != null && Navigator.of(dialogContext!).canPop()) {
            Navigator.of(dialogContext!).pop();
          }
        });
      }
    }

    if (mounted) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final primaryColor = Theme.of(context).primaryColor;
      dialogOpen = true;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext ctx) {
          dialogContext = ctx;
          return Dialog(
            backgroundColor: isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: primaryColor),
                  const SizedBox(height: 20),
                  Text(
                    '正在连接 ${config.configName} ...',
                    style: TextStyle(
                      color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () {
                      vntManager.remove(config.itemKey);
                      closeDialog();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.errorColor,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    final receivePort = ReceivePort();
    bool onece = true;

    receivePort.listen((msg) async {
      if (!mounted) return;

      if (msg is String) {
        if (msg == 'success') {
          if (onece) {
            onece = false;
            closeDialog(); // 关闭连接中对话框
            setState(() {
              _selectedConfig = config;
            });
            showTopToast(context, '[${config.configName}] 连接成功', isSuccess: true);
            // 连接成功，更新磁贴和小组件状态
            if (Platform.isAndroid) {
              VntAppCall.updateWidgetAndTile(true);
            }
            // 更新系统托盘
            await SystemTrayManager().updateMenu();
            await SystemTrayManager().updateTooltip();
          } else {
            // 重连成功（onece 已经是 false，说明之前已经连接过）
            showTopToast(context, '[${config.configName}] 已重新连接到服务器', isSuccess: true);
          }
        } else if (msg == 'stop') {
          vntManager.remove(config.itemKey);
          if (onece) {
            onece = false;
            closeDialog(); // 关闭连接中对话框
          }
          // 统一显示"服务已停止"提示
          showTopToast(context, '[${config.configName}] 服务已停止', isSuccess: false);
          // 服务停止，更新磁贴和小组件状态
          if (Platform.isAndroid) {
            VntAppCall.updateWidgetAndTile(vntManager.hasConnection());
          }
          // 更新系统托盘
          await SystemTrayManager().updateMenu();
          await SystemTrayManager().updateTooltip();
        }
      } else if (msg is RustErrorInfo) {
        // Disconnect 和 Warn 类型不销毁连接，Rust 层会自动重连
        if (msg.code == RustErrorType.disconnect || msg.code == RustErrorType.warn) {
          if (onece) {
            onece = false;
            closeDialog(); // 关闭连接中对话框
          }
          _handleConnectionError(msg, config.configName);
          return;
        }
        
        // 其他致命错误才销毁连接
        if (onece) {
          onece = false;
          closeDialog(); // 关闭连接中对话框
          vntManager.remove(config.itemKey);
        }
        _handleConnectionError(msg, config.configName);
        // 连接错误，更新磁贴和小组件状态
        if (Platform.isAndroid) {
          VntAppCall.updateWidgetAndTile(vntManager.hasConnection());
        }
        // 更新系统托盘
        await SystemTrayManager().updateMenu();
        await SystemTrayManager().updateTooltip();
      } else if (msg is RustConnectInfo) {
        // 移除 60 次限制，持续重连直到成功或手动停止
        // if (onece && msg.count > BigInt.from(60)) {
        //   onece = false;
        //   Navigator.of(context).pop(); // 关闭连接中对话框
        //   vntManager.remove(config.itemKey);
        //   showTopToast(context, '[${config.configName}] 连接超时 ${msg.address}', isSuccess: false);
        //   // 连接超时，更新磁贴和小组件状态
        //   if (Platform.isAndroid) {
        //     VntAppCall.updateWidgetAndTile(vntManager.hasConnection());
        //   }
        //   // 更新系统托盘
        //   await SystemTrayManager().updateMenu();
        //   await SystemTrayManager().updateTooltip();
        // }
      }
    });

    try {
      await vntManager.create(config, receivePort.sendPort);
    } catch (e) {
      debugPrint('dart catch e: $e');
      if (!mounted) return;

      closeDialog(); // 关闭连接中对话框
      var msg = e.toString();
      showTopToast(context, '连接失败 $msg', isSuccess: false);
    }
  }

  /// 处理连接错误
  void _handleConnectionError(RustErrorInfo errorInfo, String configName) {
    String errorMessage;
    switch (errorInfo.code) {
      case RustErrorType.tokenError:
        errorMessage = '[$configName] Token错误';
        break;
      case RustErrorType.disconnect:
        errorMessage = '[$configName] 与服务器发生断连，正在尝试重连...';
        break;
      case RustErrorType.addressExhausted:
        errorMessage = '[$configName] 地址已用尽';
        break;
      case RustErrorType.ipAlreadyExists:
        errorMessage = '[$configName] IP已存在';
        break;
      case RustErrorType.invalidIp:
        errorMessage = '[$configName] 无效的IP';
        break;
      case RustErrorType.localIpExists:
        errorMessage = '[$configName] 本地IP已存在';
        break;
      case RustErrorType.failedToCreateDevice:
        errorMessage = '[$configName] 虚拟网卡创建失败';
        break;
      case RustErrorType.warn:
        errorMessage = '[$configName] 警告';
        break;
      default:
        errorMessage = '[$configName] 未知错误';
    }

    if (errorInfo.msg != null && errorInfo.msg!.isNotEmpty) {
      errorMessage += ': ${errorInfo.msg}';
    }

    if (mounted) {
      showTopToast(context, errorMessage, isSuccess: false);
    }
  }

  /// iOS VPN连接
  Future<void> _connectViaIOSVPN(NetworkConfig config) async {
    try {
      debugPrint('[iOS VPN] Starting VPN connection for: ${config.configName}');
      
      // 保存配置到App Group
      await IOSVPNService.saveConfig(
        serverAddress: config.serverAddress,
        token: config.token,
      );
      
      // 启动VPN
      final success = await IOSVPNService.startVPN(
        serverAddress: config.serverAddress,
        token: config.token,
        deviceName: config.deviceName,
      );
      
      if (success) {
        // iOS VPN连接成功，更新UI状态
        setState(() {
          _selectedConfig = config;
        });
        
        if (mounted) {
          showTopToast(context, '[${config.configName}] VPN连接成功', isSuccess: true);
        }
        
        debugPrint('[iOS VPN] Connection successful');
      } else {
        if (mounted) {
          showTopToast(context, '[${config.configName}] VPN连接失败，请确认已添加VPN权限', isSuccess: false);
        }
        debugPrint('[iOS VPN] Connection failed');
      }
    } catch (e) {
      debugPrint('[iOS VPN] Connection error: $e');
      if (mounted) {
        showTopToast(context, '[${config.configName}] VPN连接异常: $e', isSuccess: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final showNavigationRail = screenWidth >= 600;
    final extendNavigationRail = screenWidth >= 1100;

    // 设置状态栏颜色以适配当前主题（仅移动端）
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Column(
        children: [
          // 自定义标题栏（桌面平台）
          if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
            const CustomTitleBar(),

          // 主内容区域
          Expanded(
            child: Row(
              children: [
                // 侧边导航栏（宽屏显示）
                if (showNavigationRail)
                  _buildSideNavigation(isDark, extendNavigationRail),

                // 主内容区域
                Expanded(
                  child: _buildPageContent(),
                ),
              ],
            ),
          ),
        ],
      ),
      // 底部导航栏（窄屏显示）
      bottomNavigationBar: !showNavigationRail
          ? _buildBottomNavigation()
          : null,
    );
  }

  Widget _buildSideNavigation(bool isDark, bool isExpanded) {
    final scheme = Theme.of(context).colorScheme;
    return NavigationRail(
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) => setState(() => _selectedIndex = index),
      extended: isExpanded,
      minWidth: 80,
      minExtendedWidth: 220,
      labelType: isExpanded ? NavigationRailLabelType.none : NavigationRailLabelType.all,
      groupAlignment: -0.72,
      leading: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/ic_launcher.png', width: 44, height: 44),
            ),
            if (isExpanded) ...[
              const SizedBox(width: 12),
              Text('VNT', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
      trailing: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: isExpanded
            ? TextButton.icon(
                onPressed: () => ThemeProvider.of(context)?.setThemeMode(
                  isDark ? ThemeMode.light : ThemeMode.dark,
                ),
                icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                label: Text(isDark ? '浅色模式' : '深色模式'),
              )
            : IconButton.filledTonal(
                onPressed: () => ThemeProvider.of(context)?.setThemeMode(
                  isDark ? ThemeMode.light : ThemeMode.dark,
                ),
                icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                tooltip: isDark ? '浅色模式' : '深色模式',
              ),
      ),
      destinations: _navItems
          .map((item) => NavigationRailDestination(
                icon: Icon(item.icon, color: scheme.onSurfaceVariant),
                selectedIcon: Icon(item.activeIcon),
                label: Text(item.label),
              ))
          .toList(),
    );
  }

  Widget _buildBottomNavigation() {
    return NavigationBar(
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) => setState(() => _selectedIndex = index),
      destinations: _navItems
          .map((item) => NavigationDestination(
                icon: Icon(item.icon),
                selectedIcon: Icon(item.activeIcon),
                label: item.label,
              ))
          .toList(),
    );
  }

  Widget _buildPageContent() {
    final themeProvider = ThemeProvider.of(context);

    // 使用 IndexedStack 保持页面状态，避免切换时重建页面
    return IndexedStack(
      index: _selectedIndex,
      children: [
        // 0: 仪表盘
        DashboardPage(
          onNavigateToConfig: () => setState(() => _selectedIndex = 2),
          onNavigateToSettings: () => setState(() => _selectedIndex = 3),
          onDisconnect: () async {
            // 获取所有连接的key
            final keys = vntManager.map.keys.toList();

            // 断开所有连接
            for (var key in keys) {
              await vntManager.remove(key);
            }

            if (mounted) {
              setState(() => _selectedConfig = null);
            }

            // 更新 Android 磁贴和小组件
            if (Platform.isAndroid) {
              VntAppCall.updateWidgetAndTile(false);
            }

            // 更新系统托盘
            await SystemTrayManager().updateMenu();
            await SystemTrayManager().updateTooltip();
          },
          onConnect: () async {
            // 尝试连接默认配置
            debugPrint('Dashboard onConnect called');
            final dataPersistence = DataPersistence();
            final defaultKey = await dataPersistence.loadDefaultKey();
            debugPrint('Default key: $defaultKey');
            if (defaultKey != null && defaultKey.isNotEmpty) {
              final configs = await dataPersistence.loadData();
              final config = configs.where((c) => c.itemKey == defaultKey).firstOrNull;
              debugPrint('Found config: ${config?.configName}');
              if (config != null) {
                // 直接连接，不跳转页面
                debugPrint('Connecting to default config: ${config.configName}');
                _connectToConfigDirectly(config);
                return;
              }
            }
            // 没有默认配置，跳转到配置页面
            debugPrint('No default config found, navigating to config page');
            setState(() => _selectedIndex = 2);
          },
        ),
        // 1: 房间
        RoomPage(
          selectedConfig: _selectedConfig,
          onDisconnect: _selectedConfig != null
              ? () {
                  setState(() => _selectedConfig = null);
                }
              : null,
        ),
        // 2: 配置
        ConfigListPage(
          onConfigSelected: (config) {
            setState(() {
              _selectedConfig = config;
              _selectedIndex = 1; // 跳转到房间页面
            });
          },
          onRefreshCallback: (callback) {
            _refreshConfigList = callback;
          },
          onDataChanged: () {
            // 当配置数据改变时，刷新设置页面
            _refreshSettings?.call();
          },
        ),
        // 3: 设置
        SettingsPage(
          themeMode: themeProvider?.themeMode ?? ThemeMode.system,
          onThemeModeChanged: (mode) {
            themeProvider?.setThemeMode(mode);
          },
          onDataChanged: () {
            // 当设置页面的数据改变时，刷新配置列表
            _refreshConfigList?.call();
          },
          onRefreshCallback: (callback) {
            _refreshSettings = callback;
          },
        ),
        // 4: 关于
        const AboutPage(),
      ],
    );
  }
}

/// 导航项数据类
class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}
