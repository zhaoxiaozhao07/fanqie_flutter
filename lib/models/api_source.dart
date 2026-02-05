class ApiSource {
  final String baseUrl;
  bool isEnabled;
  int? latency; // 毫秒，null 表示未检测
  bool isWorking; // 最近一次检测是否成功
  String? error; // 错误信息

  ApiSource({
    required this.baseUrl,
    this.isEnabled = true,
    this.latency,
    this.isWorking = false,
    this.error,
  });

  Map<String, dynamic> toJson() {
    return {'baseUrl': baseUrl, 'isEnabled': isEnabled};
  }

  factory ApiSource.fromJson(Map<String, dynamic> json) {
    return ApiSource(
      baseUrl: json['baseUrl'] as String,
      isEnabled: json['isEnabled'] as bool? ?? true,
    );
  }

  ApiSource copyWith({
    String? baseUrl,
    bool? isEnabled,
    int? latency,
    bool? isWorking,
    String? error,
  }) {
    return ApiSource(
      baseUrl: baseUrl ?? this.baseUrl,
      isEnabled: isEnabled ?? this.isEnabled,
      latency: latency ?? this.latency,
      isWorking: isWorking ?? this.isWorking,
      error: error ?? this.error,
    );
  }
}
