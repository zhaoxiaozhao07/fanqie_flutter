package com.fanqie.fanqie_flutter

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/** Android 桌面“最近在读”小组件：展示最近阅读书籍与进度，支持一键继续阅读或直达听书 */
class ReaderAppWidgetProvider : AppWidgetProvider() {
    companion object {
        private const val PREFS = "reader_widget_state"
        private const val KEY_BOOK_ID = "book_id"
        private const val KEY_BOOK_NAME = "book_name"
        private const val KEY_CHAPTER_TITLE = "chapter_title"
        private const val KEY_PROGRESS = "progress_text"

        fun saveAndRefresh(
            context: Context,
            bookId: String,
            bookName: String,
            chapterTitle: String,
            progressText: String
        ) {
            val app = context.applicationContext
            app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_BOOK_ID, bookId)
                .putString(KEY_BOOK_NAME, bookName)
                .putString(KEY_CHAPTER_TITLE, chapterTitle)
                .putString(KEY_PROGRESS, progressText)
                .apply()
            updateAllWidgets(app)
        }

        fun updateAllWidgets(context: Context) {
            try {
                val manager = AppWidgetManager.getInstance(context)
                val component = ComponentName(context, ReaderAppWidgetProvider::class.java)
                val ids = manager.getAppWidgetIds(component)
                if (ids.isEmpty()) return
                for (widgetId in ids) {
                    updateSingleWidget(context, manager, widgetId)
                }
            } catch (_: Exception) {
                // 桌面服务不可用时安全忽略
            }
        }

        private fun updateSingleWidget(
            context: Context,
            manager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val bookId = prefs.getString(KEY_BOOK_ID, "") ?: ""
            val bookName = prefs.getString(KEY_BOOK_NAME, "") ?: ""
            val chapterTitle = prefs.getString(KEY_CHAPTER_TITLE, "") ?: ""
            val progressText = prefs.getString(KEY_PROGRESS, "") ?: ""

            val views = RemoteViews(context.packageName, R.layout.widget_reader_recent)
            if (bookName.isBlank()) {
                views.setTextViewText(R.id.widget_book_title, "尚未开始阅读")
                views.setTextViewText(R.id.widget_chapter_title, "点击打开书架探索精彩小说")
                views.setTextViewText(R.id.widget_progress_badge, "番茄Reader")
            } else {
                views.setTextViewText(R.id.widget_book_title, bookName)
                views.setTextViewText(
                    R.id.widget_chapter_title,
                    chapterTitle.ifBlank { "点击继续上次进度" }
                )
                views.setTextViewText(
                    R.id.widget_progress_badge,
                    progressText.ifBlank { "最近在读" }
                )
            }

            val readPending = buildShortcutPendingIntent(
                context = context,
                requestCode = appWidgetId * 10 + 1,
                action = "continue_reading",
                bookId = bookId
            )
            val listenPending = buildShortcutPendingIntent(
                context = context,
                requestCode = appWidgetId * 10 + 2,
                action = "continue_listening",
                bookId = bookId
            )

            views.setOnClickPendingIntent(R.id.widget_root, readPending)
            views.setOnClickPendingIntent(R.id.widget_btn_read, readPending)
            views.setOnClickPendingIntent(R.id.widget_btn_listen, listenPending)

            manager.updateAppWidget(appWidgetId, views)
        }

        private fun buildShortcutPendingIntent(
            context: Context,
            requestCode: Int,
            action: String,
            bookId: String
        ): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                this.action = ReaderRuntime.ACTION_READER_SHORTCUT
                putExtra(ReaderRuntime.EXTRA_SHORTCUT_ACTION, action)
                if (bookId.isNotBlank()) {
                    putExtra(ReaderRuntime.EXTRA_BOOK_ID, bookId)
                }
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            return PendingIntent.getActivity(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateSingleWidget(context, appWidgetManager, appWidgetId)
        }
    }
}
