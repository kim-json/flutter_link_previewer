import 'package:flutter_chat_types/flutter_chat_types.dart'
    show PreviewData, PreviewDataImage;

class CachedPreviewData {
  CachedPreviewData({
    required this.timeOut,
    required this.previewData,
  });

  final DateTime timeOut;
  final PreviewData previewData;

  bool get isValidPreviewData =>
      previewData.title != null ||
      previewData.description != null ||
      previewData.image != null ||
      previewData.link != null;
}
