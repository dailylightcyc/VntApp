package top.daylight.vnt.www.vpn;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.system.OsConstants;

import androidx.core.app.NotificationCompat;

import top.daylight.vnt.www.FlutterMethodChannel;
import top.daylight.vnt.www.MainActivity;
import top.daylight.vnt.www.MyTileService;
import top.daylight.vnt.www.NativeLogger;
import top.daylight.vnt.www.R;

public class MyVpnService extends VpnService {
    private static final String TAG = "MyVpnService";
    private static final String CHANNEL_ID = "vnt_vpn_channel";
    private static final int NOTIFICATION_ID = 1002;
    private static final String ACTION_DISCONNECT = "top.daylight.vnt.www.VPN_DISCONNECT";
    private volatile static MyVpnService vpnService;
    private volatile boolean stopping;

    public static DeviceConfig pendingConfig;


    @Override
    public synchronized int onStartCommand(Intent intent, int flags, int startId) {
        vpnService = this;
        NativeLogger.info(TAG, "onStartCommand; startId=" + startId + "; flags=" + flags
                + "; action=" + (intent == null ? "null" : intent.getAction())
                + "; hasPendingConfig=" + (pendingConfig != null));
        if (intent != null && ACTION_DISCONNECT.equals(intent.getAction())) {
            shutdown(true);
            return START_NOT_STICKY;
        }

        final DeviceConfig config = pendingConfig;
        if (config == null) {
            NativeLogger.warning(TAG, "restarted without active core configuration");
            stopForeground(true);
            stopSelf();
            return START_NOT_STICKY;
        }
        pendingConfig = null;

        new Thread(() -> {
            try {
                int fd = startVpn(config);
                NativeLogger.info(TAG, "VPN interface established; fd=" + fd);
                FlutterMethodChannel.callSuccess(fd);
                updateForegroundNotification();
            } catch (SecurityException e) {
                NativeLogger.error(TAG, "VPN conflict or authorization failure", e);
                FlutterMethodChannel.callError("检测到其他 VPN 正在运行，请先断开其他 VPN 后重试", e);
                shutdown(false);
            } catch (Exception e) {
                NativeLogger.error(TAG, "failed to start VPN", e);
                FlutterMethodChannel.callError("启动 VPN 失败: " + e.getMessage(), e);
                shutdown(false);
            }
        }).start();
        return START_STICKY;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        NativeLogger.info(TAG, "onCreate; sdk=" + Build.VERSION.SDK_INT);
        vpnService = this;
        createNotificationChannel();
        // Android 8+ 要求 startForegroundService 后立即进入前台。
        startForeground(NOTIFICATION_ID, buildNotification(false));
    }

    public static void stopVpn() {
        MyVpnService service = vpnService;
        if (service != null) {
            // 这个入口由 Dart 断开流程调用，不能再回调 Dart，否则会形成递归断开。
            service.shutdown(false);
        }
    }

    public static void updateForegroundNotification() {
        MyVpnService service = vpnService;
        if (service != null && !service.stopping) {
            NotificationManager manager =
                    (NotificationManager) service.getSystemService(Context.NOTIFICATION_SERVICE);
            manager.notify(NOTIFICATION_ID, service.buildNotification(true));
        }
    }

    private synchronized void shutdown(boolean notifyFlutter) {
        if (stopping) {
            return;
        }
        stopping = true;
        NativeLogger.info(TAG, "shutdown; notifyFlutter=" + notifyFlutter);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            MyTileService.setState(false);
        }
        if (notifyFlutter) {
            FlutterMethodChannel.stopVnt();
        }
        stopForeground(true);
        stopSelf();
    }

    private int startVpn(DeviceConfig config) throws PackageManager.NameNotFoundException {
        Builder builder = new Builder();
        String ip = IpUtils.intToIpAddress(config.virtualIp);
        int prefixLength = IpUtils.subnetMaskToPrefixLength(config.virtualNetmask);
        String ipRoute = IpUtils.intToIpAddress(config.virtualGateway & config.virtualNetmask);
        builder
                .allowFamily(OsConstants.AF_INET)
                .allowFamily(OsConstants.AF_INET6)
                // VNT consumes this fd through tun-rs SyncDevice. A non-blocking
                // descriptor returns EAGAIN before the first packet and the core
                // correctly interprets that synchronous read error as device loss.
                // Blocking reads remain interruptible through tun-rs' shutdown fd.
                .setBlocking(true)
                .setMtu(config.mtu)
                .addAddress(ip, prefixLength)
                // 自己的流量不走网卡
                .addDisallowedApplication("top.daylight.vnt.www")
                .addRoute(ipRoute, prefixLength);
        if (config.externalRoute != null) {
            for (DeviceConfig.Route routeItem : config.externalRoute) {
                int routePrefixLength = IpUtils.subnetMaskToPrefixLength(routeItem.netmask);
                String routeDest = IpUtils.intToIpAddress(routeItem.destination);
                builder.addRoute(routeDest, routePrefixLength);
            }
        }
        ParcelFileDescriptor vpnInterface;
        try {
            vpnInterface = builder.setSession("VNT").establish();
            if (vpnInterface == null) {
                // establish() 返回 null 说明有其他 VPN 正在运行
                NativeLogger.error(TAG, "Builder.establish returned null", null);
                throw new SecurityException("无法建立 VPN 连接。请先断开其他 VPN 应用，然后重试。");
            }
        } catch (SecurityException e) {
            NativeLogger.error(TAG, "Builder.establish security exception", e);
            throw e;
        } catch (Exception e) {
            NativeLogger.error(TAG, "Builder.establish failed", e);
            throw e;
        }
        // Rust 核心成为 fd 的唯一所有者，避免 ParcelFileDescriptor
        // 和 tun-rs 在断开时重复 close 同一个 fd。
        return vpnInterface.detachFd();
    }

    @Override
    public void onDestroy() {
        NativeLogger.warning(TAG, "onDestroy; explicitStop=" + stopping);
        super.onDestroy();
        vpnService = null;
        // 只有系统意外销毁服务时才通知 Dart 停止核心。
        if (!stopping) {
            FlutterMethodChannel.stopVnt();
        }
    }

    @Override
    public void onRevoke() {
        NativeLogger.warning(TAG, "VPN permission revoked by Android");
        shutdown(true);
        super.onRevoke();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        NativeLogger.info(TAG, "onTaskRemoved; VPN remains active");
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onTrimMemory(int level) {
        NativeLogger.warning(TAG, "onTrimMemory; level=" + level);
        super.onTrimMemory(level);
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager manager =
                    (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "VNT VPN", NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("保持 VNT 虚拟网络连接");
            channel.setShowBadge(false);
            manager.createNotificationChannel(channel);
        }
    }

    private Notification buildNotification(boolean connected) {
        Intent openIntent = new Intent(this, MainActivity.class);
        openIntent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        int pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingFlags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent openPendingIntent = PendingIntent.getActivity(
                this, 0, openIntent, pendingFlags);

        Intent disconnectIntent = new Intent(this, MyVpnService.class);
        disconnectIntent.setAction(ACTION_DISCONNECT);
        PendingIntent disconnectPendingIntent = PendingIntent.getService(
                this, 1, disconnectIntent, pendingFlags);

        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_icon)
                .setContentTitle(connected ? "VNT 已连接" : "VNT 正在建立连接")
                .setContentText(connected ? "VPN 正在后台运行" : "正在创建虚拟网络接口")
                .setContentIntent(openPendingIntent)
                .addAction(android.R.drawable.ic_menu_close_clear_cancel,
                        "断开", disconnectPendingIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .build();
    }
}
