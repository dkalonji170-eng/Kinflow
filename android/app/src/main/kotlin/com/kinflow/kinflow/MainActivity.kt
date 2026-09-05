package com.kinflow.kinflow

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kinflow.kinflow/crash_log"
        ).setMethodCallHandler { call, result ->
            if (call.method == "writeDownloadLog") {
                val fileName = call.argument<String>("fileName") ?: "kinflow_crash.log"
                val content = call.argument<String>("content") ?: ""
                (application as KinflowApplication)
                    .appendTextToDownloads(fileName, content)
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }
}
