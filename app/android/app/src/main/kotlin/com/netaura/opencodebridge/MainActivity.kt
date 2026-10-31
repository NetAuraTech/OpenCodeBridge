package com.netaura.opencodebridge

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL

class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
      setMethodCallHandler { call, result ->
        if (call.method != "postForm") {
          result.notImplemented()
          return@setMethodCallHandler
        }
        val url = call.argument<String>("url")
        val form = call.argument<String>("form")
        if (url == null || form == null) {
          result.error("bad_args", "postForm needs url and form", null)
          return@setMethodCallHandler
        }
        Thread {
          try {
            // The platform's own HTTP stack: its TLS fingerprint is the
            // stock Android one, the one Cloudflare's beta Managed OAuth
            // token endpoint does not 500 (the Dart SDK's is).
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
              requestMethod = "POST"
              doOutput = true
              connectTimeout = 30_000
              readTimeout = 30_000
              setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
              setRequestProperty("Accept", "*/*")
            }
            conn.outputStream.use { it.write(form.toByteArray()) }
            val status = conn.responseCode
            val body =
              (if (status in 200..299) conn.inputStream else conn.errorStream)
                ?.readBytes()?.toString(Charsets.UTF_8)
                ?: ""
            conn.disconnect()
            result.success(mapOf("status" to status, "body" to body))
          } catch (e: Exception) {
            result.error("network", e.message ?: e.toString(), null)
          }
        }.start()
      }
    }
  }

  companion object {
    private const val CHANNEL = "opencodebridge/form_post"
  }
}
