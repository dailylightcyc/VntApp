package top.daylight.vnt.www;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;

import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodChannel;
import top.daylight.vnt.www.vpn.DeviceConfig;
import top.daylight.vnt.www.vpn.MyVpnService;

public class MainActivity extends FlutterActivity {
    private static final String TAG = "MainActivity";
    private static final int VPN_REQUEST_CODE = 1;
    private static final int CREATE_FILE_REQUEST_CODE = 2;
    private static final int NOTIFICATION_PERMISSION_REQUEST_CODE = 3;

    private static final String FILE_CHANNEL = "top.daylight.vnt.www/file";
    private MethodChannel fileChannel;
    private String pendingFilePath;
    private MethodChannel.Result pendingFileResult;
    private static volatile FlutterEngine persistentFlutterEngine;

    @Override
    public FlutterEngine provideFlutterEngine(@NonNull Context context) {
        if (persistentFlutterEngine == null) {
            synchronized (MainActivity.class) {
                if (persistentFlutterEngine == null) {
                    FlutterEngine engine = new FlutterEngine(context.getApplicationContext());
                    engine.getDartExecutor().executeDartEntrypoint(
                            DartExecutor.DartEntrypoint.createDefault());
                    persistentFlutterEngine = engine;
                    NativeLogger.info(TAG, "created process-level FlutterEngine");
                }
            }
        }
        return persistentFlutterEngine;
    }

    @Override
    public boolean shouldDestroyEngineWithHost() {
        return false;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        NativeLogger.info(TAG, "onCreate; restored=" + (savedInstanceState != null));
        // 设置应用上下文，用于更新磁贴和小组件
        FlutterMethodChannel.setAppContext(this);

        // Android 13+ 请求通知权限，VPN 连接后由 VpnService 自身显示前台通知。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestNotificationPermission();
        }
    }

    /**
     * 请求通知权限（Android 13+）
     */
    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                // 请求通知权限
                ActivityCompat.requestPermissions(this,
                        new String[]{Manifest.permission.POST_NOTIFICATIONS},
                        NOTIFICATION_PERMISSION_REQUEST_CODE);
            }
        }
    }

    /**
     * 处理权限请求结果
     */
    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                NativeLogger.info(TAG, "notification permission granted");
            } else {
                NativeLogger.warning(TAG, "notification permission denied");
                // 即使没有通知权限，应用也应该能正常运行
            }
        }
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        NativeLogger.info(TAG, "configureFlutterEngine; executingDart="
                + flutterEngine.getDartExecutor().isExecutingDart());

        // VPN Channel
        FlutterMethodChannel.init(flutterEngine, new FlutterMethodChannel.Callback() {
            @Override
            public int startVpn(DeviceConfig config) {
                startVpnService(config);
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    MyTileService.setState(true);
                }
                return 0;
            }

            @Override
            public void stopVpn() {
                MyVpnService.stopVpn();
            }

            @Override
            public void moveToBack() {
                moveTaskToBack(true);
            }
        });

        // File Channel - 用于文件保存
        fileChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), FILE_CHANNEL);
        fileChannel.setMethodCallHandler((call, result) -> {
            if (call.method.equals("saveFile")) {
                String filePath = call.argument("filePath");
                String fileName = call.argument("fileName");
                String mimeType = call.argument("mimeType");

                if (filePath == null || fileName == null) {
                    result.error("INVALID_ARGUMENT", "filePath and fileName are required", null);
                    return;
                }

                pendingFilePath = filePath;
                pendingFileResult = result;

                // 使用 SAF 创建文件
                createFile(fileName, mimeType != null ? mimeType : "*/*");
            } else {
                result.notImplemented();
            }
        });
    }

    private void createFile(String fileName, String mimeType) {
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType(mimeType);
        intent.putExtra(Intent.EXTRA_TITLE, fileName);

        startActivityForResult(intent, CREATE_FILE_REQUEST_CODE);
    }

    private void startVpnService(DeviceConfig config) {
        NativeLogger.info(TAG, "startVpnService requested; sdk=" + Build.VERSION.SDK_INT);
        NativeLogger.debug(TAG, "VPN config=" + config);
        MyVpnService.pendingConfig = config;
        // 每次启动都重新检查权限，这样如果有其他 VPN 运行，系统会弹窗让用户选择
        Intent intent = VpnService.prepare(this);
        if (intent != null) {
            // 需要用户授权，系统会提示断开其他 VPN
            startActivityForResult(intent, VPN_REQUEST_CODE);
        } else {
            // 已有权限，直接启动
            startPreparedVpnService();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        NativeLogger.info(TAG, "onActivityResult; request=" + requestCode
                + "; result=" + resultCode + "; hasData=" + (data != null));
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                startPreparedVpnService();
            } else {
                FlutterMethodChannel.callError("User denied VPN authorization", null);
            }
        } else if (requestCode == CREATE_FILE_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data != null) {
                Uri uri = data.getData();
                if (uri != null && pendingFilePath != null) {
                    // 复制文件到用户选择的位置
                    copyFileToUri(pendingFilePath, uri);
                } else {
                    if (pendingFileResult != null) {
                        pendingFileResult.error("SAVE_FAILED", "Failed to get URI", null);
                        pendingFileResult = null;
                    }
                }
            } else {
                // 用户取消
                if (pendingFileResult != null) {
                    pendingFileResult.success(null);
                    pendingFileResult = null;
                }
            }
            pendingFilePath = null;
        }
        super.onActivityResult(requestCode, resultCode, data);
    }

    private void startPreparedVpnService() {
        NativeLogger.info(TAG, "starting prepared foreground VPN service");
        Intent serviceIntent = new Intent(this, MyVpnService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(this, serviceIntent);
        } else {
            startService(serviceIntent);
        }
    }

    private void copyFileToUri(String sourcePath, Uri destUri) {
        try {
            File sourceFile = new File(sourcePath);
            FileInputStream inputStream = new FileInputStream(sourceFile);
            OutputStream outputStream = getContentResolver().openOutputStream(destUri);

            if (outputStream == null) {
                throw new Exception("Cannot open output stream");
            }

            byte[] buffer = new byte[4096];
            int length;
            while ((length = inputStream.read(buffer)) > 0) {
                outputStream.write(buffer, 0, length);
            }

            outputStream.flush();
            outputStream.close();
            inputStream.close();

            if (pendingFileResult != null) {
                pendingFileResult.success(destUri.toString());
                pendingFileResult = null;
            }

            NativeLogger.info(TAG, "file saved to=" + destUri);
        } catch (Exception e) {
            NativeLogger.error(TAG, "file save failed", e);
            if (pendingFileResult != null) {
                pendingFileResult.error("SAVE_FAILED", e.getMessage(), null);
                pendingFileResult = null;
            }
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        NativeLogger.debug(TAG, "onStart");
    }

    @Override
    protected void onResume() {
        super.onResume();
        NativeLogger.debug(TAG, "onResume");
    }

    @Override
    protected void onPause() {
        NativeLogger.debug(TAG, "onPause");
        super.onPause();
    }

    @Override
    protected void onStop() {
        NativeLogger.debug(TAG, "onStop");
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        NativeLogger.info(TAG, "onDestroy; finishing=" + isFinishing()
                + "; changingConfigurations=" + isChangingConfigurations()
                + "; engineKeptAlive=" + (persistentFlutterEngine != null));
        super.onDestroy();
    }
}
