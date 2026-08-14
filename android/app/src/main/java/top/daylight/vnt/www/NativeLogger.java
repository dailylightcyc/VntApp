package top.daylight.vnt.www;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Process;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Android native diagnostics written beside the Dart and Rust logs. */
public final class NativeLogger {
    private static final Object LOCK = new Object();
    private static final long MAX_BYTES = 5L * 1024L * 1024L;
    private static final String STATE_PREFS = "vnt-native-logger";
    private static final String LAST_EXIT_TIMESTAMP = "last-exit-timestamp";
    private static final boolean FULL_DEBUG = BuildConfig.DEBUG;
    private static final Pattern SENSITIVE_VALUE = Pattern.compile(
            "(?i)(token|password|secret|private[_ -]?key|device[_ -]?id)(\\s*[:=]\\s*)([^,;\\s}\\]]+)");
    private static final Pattern JSON_SENSITIVE_VALUE = Pattern.compile(
            "(?i)(\\\"(?:token|password|secret|privateKey|deviceId)\\\"\\s*:\\s*\\\")[^\\\"]*(\\\")");

    private static File logFile;
    private static Thread.UncaughtExceptionHandler previousHandler;

    private NativeLogger() {}

    public static void initialize(Context context) {
        synchronized (LOCK) {
            try {
                File directory = new File(context.getFilesDir(), "logs");
                if (!directory.exists() && !directory.mkdirs()) {
                    Log.e("NativeLogger", "Unable to create " + directory);
                    return;
                }
                logFile = new File(directory, "vnt-android.log");
                rotateIfNeeded();
            } catch (Throwable error) {
                Log.e("NativeLogger", "Initialization failed", error);
            }
        }

        installUncaughtExceptionHandler();
        info("startup", "native logging initialized; mode="
                + (FULL_DEBUG ? "debug-full" : "release-audited")
                + "; sdk=" + Build.VERSION.SDK_INT
                + "; release=" + Build.VERSION.RELEASE
                + "; manufacturer=" + Build.MANUFACTURER
                + "; model=" + Build.MODEL
                + "; pid=" + Process.myPid());
        recordHistoricalExitReasons(context.getApplicationContext());
    }

    public static void debug(String category, String message) {
        if (FULL_DEBUG) write(Log.DEBUG, "DEBUG", category, message, null);
    }

    public static void info(String category, String message) {
        write(Log.INFO, "INFO", category, message, null);
    }

    public static void warning(String category, String message) {
        write(Log.WARN, "WARN", category, message, null);
    }

    public static void error(String category, String message, Throwable error) {
        write(Log.ERROR, "ERROR", category, message, error);
    }

    private static void write(int priority, String level, String category,
                              String message, Throwable error) {
        String raw = message == null ? "null" : message;
        if (error != null) raw += "\n" + stackTrace(error);
        String output = FULL_DEBUG ? raw : audit(raw);
        Log.println(priority, "VNT/" + category, output);

        synchronized (LOCK) {
            if (logFile == null) return;
            try {
                rotateIfNeeded();
                try (BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(
                        new FileOutputStream(logFile, true), StandardCharsets.UTF_8))) {
                    String timestamp = new SimpleDateFormat(
                            "yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US).format(new Date());
                    writer.write(timestamp + " [" + level + "] [" + category + "] "
                            + (FULL_DEBUG ? output : "[AUDITED] " + output));
                    writer.newLine();
                    writer.flush();
                }
            } catch (Throwable fileError) {
                Log.e("NativeLogger", "Unable to write native log", fileError);
            }
        }
    }

    private static void installUncaughtExceptionHandler() {
        if (previousHandler != null) return;
        previousHandler = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, throwable) -> {
            error("uncaught", "fatal exception; thread=" + thread.getName(), throwable);
            Thread.UncaughtExceptionHandler previous = previousHandler;
            if (previous != null) previous.uncaughtException(thread, throwable);
        });
    }

    private static void recordHistoricalExitReasons(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return;
        try {
            SharedPreferences state = context.getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE);
            long lastTimestamp = state.getLong(LAST_EXIT_TIMESTAMP, 0L);
            ActivityManager manager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
            List<ApplicationExitInfo> exits = manager.getHistoricalProcessExitReasons(
                    context.getPackageName(), 0, 8);
            long newestTimestamp = lastTimestamp;
            for (ApplicationExitInfo exit : exits) {
                if (exit.getTimestamp() <= lastTimestamp) continue;
                newestTimestamp = Math.max(newestTimestamp, exit.getTimestamp());
                warning("previous-exit", "timestamp=" + exit.getTimestamp()
                        + "; reason=" + exitReasonName(exit.getReason())
                        + "(" + exit.getReason() + ")"
                        + "; status=" + exit.getStatus()
                        + "; importance=" + exit.getImportance()
                        + "; pss=" + exit.getPss()
                        + "; rss=" + exit.getRss()
                        + "; description=" + exit.getDescription());
                try (InputStream trace = exit.getTraceInputStream()) {
                    if (trace != null) {
                        String traceText = readLimited(trace, FULL_DEBUG ? 512 * 1024 : 64 * 1024);
                        if (!traceText.trim().isEmpty()) {
                            write(Log.ERROR, "ERROR", "previous-exit-trace", traceText, null);
                        }
                    }
                }
            }
            if (newestTimestamp > lastTimestamp) {
                state.edit().putLong(LAST_EXIT_TIMESTAMP, newestTimestamp).apply();
            }
        } catch (Throwable error) {
            error("previous-exit", "Unable to read Android exit history", error);
        }
    }

    private static String exitReasonName(int reason) {
        switch (reason) {
            case ApplicationExitInfo.REASON_ANR: return "ANR";
            case ApplicationExitInfo.REASON_CRASH: return "CRASH";
            case ApplicationExitInfo.REASON_CRASH_NATIVE: return "CRASH_NATIVE";
            case ApplicationExitInfo.REASON_DEPENDENCY_DIED: return "DEPENDENCY_DIED";
            case ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE: return "EXCESSIVE_RESOURCE";
            case ApplicationExitInfo.REASON_EXIT_SELF: return "EXIT_SELF";
            case ApplicationExitInfo.REASON_INITIALIZATION_FAILURE: return "INIT_FAILURE";
            case ApplicationExitInfo.REASON_LOW_MEMORY: return "LOW_MEMORY";
            case ApplicationExitInfo.REASON_OTHER: return "OTHER";
            case ApplicationExitInfo.REASON_PERMISSION_CHANGE: return "PERMISSION_CHANGE";
            case ApplicationExitInfo.REASON_SIGNALED: return "SIGNALED";
            case ApplicationExitInfo.REASON_USER_REQUESTED: return "USER_REQUESTED";
            case ApplicationExitInfo.REASON_USER_STOPPED: return "USER_STOPPED";
            default: return "UNKNOWN";
        }
    }

    private static String readLimited(InputStream input, int limit) throws Exception {
        BufferedInputStream stream = new BufferedInputStream(input);
        byte[] buffer = new byte[8192];
        StringBuilder result = new StringBuilder();
        int total = 0;
        int read;
        while (total < limit && (read = stream.read(buffer, 0, Math.min(buffer.length, limit - total))) > 0) {
            result.append(new String(buffer, 0, read, StandardCharsets.UTF_8));
            total += read;
        }
        if (total >= limit) result.append("\n<truncated>");
        return result.toString();
    }

    private static String stackTrace(Throwable throwable) {
        StringWriter output = new StringWriter();
        throwable.printStackTrace(new PrintWriter(output));
        return output.toString();
    }

    private static String audit(String value) {
        Matcher matcher = SENSITIVE_VALUE.matcher(value);
        String audited = matcher.replaceAll("$1$2<redacted>");
        return JSON_SENSITIVE_VALUE.matcher(audited).replaceAll("$1<redacted>$2");
    }

    private static void rotateIfNeeded() throws Exception {
        if (logFile == null || !logFile.exists() || logFile.length() < MAX_BYTES) return;
        File old = new File(logFile.getParentFile(), "vnt-android.log.1");
        if (old.exists() && !old.delete()) {
            throw new IllegalStateException("Unable to remove old native log");
        }
        if (!logFile.renameTo(old)) {
            throw new IllegalStateException("Unable to rotate native log");
        }
    }
}
