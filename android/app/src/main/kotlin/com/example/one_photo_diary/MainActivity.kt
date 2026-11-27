package com.example.one_photo_diary

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 最近のアプリ一覧のサムネイルに日記の内容を出さない
        // （ユーザーのスクリーンショットまで禁止されるためFLAG_SECUREは使わない）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            setRecentsScreenshotEnabled(false)
        }
    }
}
