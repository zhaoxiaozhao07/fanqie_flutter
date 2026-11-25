import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';

/// 沉浸式播放原生音频桥接助手：负责段间自然呼吸停顿计算与双缓冲预装指令封装
class ImmersiveAudioPlayerBridge {
  /// 根据前后两段的章节与说话人切换关系计算自然呼吸停顿时长（毫秒）
  static int computeSegmentGapMs({
    required PlaybackConfig playbackConfig,
    required AudioSegment current,
    required AudioSegment next,
  }) {
    if (next.chapterIndex != current.chapterIndex) {
      return playbackConfig.chapterSwitchGapMs.clamp(0, 3000);
    }
    final sameSpeaker =
        (current.speakerRef != null &&
            current.speakerRef == next.speakerRef) ||
        (current.speakerRef == null &&
            next.speakerRef == null &&
            current.speakerDisplayName == next.speakerDisplayName);
    if (sameSpeaker) {
      return playbackConfig.sameSpeakerGapMs.clamp(0, 2000);
    }
    return playbackConfig.speakerSwitchGapMs.clamp(0, 2000);
  }

  /// 构造原生播放指令参数
  static Map<String, Object?> buildPlayArgs({
    required String token,
    required String filePath,
    required double rate,
    required bool preservePitch,
    int startPositionMs = 0,
  }) => {
    'id': token,
    'filePath': filePath,
    'rate': rate,
    'preservePitch': preservePitch,
    if (startPositionMs > 0) 'startPositionMs': startPositionMs,
  };

  /// 构造原生下一段预装参数（用于消除段间 IPC 往返与磁盘解码抖动）
  static Map<String, Object?> buildPreloadArgs({
    required String currentToken,
    required String nextToken,
    required String filePath,
    required double rate,
    required bool preservePitch,
    required int gapMs,
  }) => {
    'afterId': currentToken,
    'id': nextToken,
    'filePath': filePath,
    'rate': rate,
    'preservePitch': preservePitch,
    'gapMs': gapMs.clamp(0, 3000),
  };
}
