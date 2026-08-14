package top.daylight.vnt.www;

import android.app.Application;

public class VntApplication extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        NativeLogger.initialize(this);
        NativeLogger.info("Application", "process created");
    }
}
