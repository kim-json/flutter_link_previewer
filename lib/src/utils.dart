import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Element;
import 'package:flutter_chat_types/flutter_chat_types.dart'
    show PreviewData, PreviewDataImage;
import 'package:flutter_link_previewer/src/cached_preview_data.dart';
import 'package:html/dom.dart' show Document, Element;
import 'package:html/parser.dart' as parser show parse;
import 'package:http/http.dart' as http show get;

import 'types.dart';

class LinkPreviewUtils {
  static final Map<String?, CachedPreviewData> _map = {};

  static Future<PreviewData?> getPreviewData(
    String text, {
    String? proxy,
    Duration? requestTimeout,
    String? userAgent,
    Duration? cacheDuration,
  }) async {
    final cachedPreview = getCachedPreviewData(text);

    if (cachedPreview != null && cachedPreview.isValidPreviewData) {
      return cachedPreview.previewData;
    }

    try {
      final preview = await _getPreviewData(
        text,
        proxy: proxy,
        requestTimeout: requestTimeout,
        userAgent: userAgent,
      );
      _map[text] = CachedPreviewData(
        timeOut: DateTime.now().add(cacheDuration ?? const Duration(hours: 24)),
        previewData: preview,
      );

      return preview;
    } catch (e) {
      return null;
    }
  }

  static CachedPreviewData? getCachedPreviewData(String text) {
    try {
      final preview = _map[text];
      if (preview != null && !preview.timeOut.isAfter(DateTime.now())) {
        _map.remove(text);
        return null;
      }
      return preview;
    } catch (e) {
      return null;
    }
  }

  /// Parses provided text and returns [PreviewData] for the first found link.
  static Future<PreviewData> _getPreviewData(
    String text, {
    String? proxy,
    Duration? requestTimeout,
    String? userAgent,
  }) async {
    const previewData = PreviewData();

    String? previewDataDescription;
    PreviewDataImage? previewDataImage;
    String? previewDataTitle;
    String? previewDataUrl;

    try {
      final emailRegexp = RegExp(regexEmail, caseSensitive: false);
      final textWithoutEmails = text
          .replaceAllMapped(
            emailRegexp,
            (match) => '',
          )
          .trim();
      if (textWithoutEmails.isEmpty) return previewData;

      final urlRegexp = RegExp(regexLink, caseSensitive: false);
      final matches = urlRegexp.allMatches(textWithoutEmails);
      if (matches.isEmpty) return previewData;

      var url = textWithoutEmails.substring(
        matches.first.start,
        matches.first.end,
      );

      if (!url.toLowerCase().startsWith('http')) {
        url = 'https://$url';
      }
      previewDataUrl = _calculateUrl(url, proxy);
      final uri = Uri.parse(previewDataUrl);
      final response = await http.get(uri, headers: {
        'User-Agent': userAgent ?? 'WhatsApp/2',
      }).timeout(requestTimeout ?? const Duration(seconds: 5));
      final document = parser.parse(utf8.decode(response.bodyBytes));

      final imageRegexp = RegExp(regexImageContentType);

      if (imageRegexp.hasMatch(response.headers['content-type'] ?? '')) {
        final imageSize = await _getImageSize(previewDataUrl);
        previewDataImage = PreviewDataImage(
          height: imageSize.height,
          url: previewDataUrl,
          width: imageSize.width,
        );
        return PreviewData(
          image: previewDataImage,
          link: _getDomain(document, previewDataUrl),
        );
      }

      if (!_hasUTF8Charset(document)) {
        return previewData;
      }

      final title = _getTitle(document);
      if (title != null) {
        previewDataTitle = title.trim();
      }

      final description = _getDescription(document);
      if (description != null) {
        previewDataDescription = description.trim();
      }

      final imageUrls = _getImageUrls(document, url);

      Size imageSize;
      String imageUrl;

      if (imageUrls.isNotEmpty) {
        imageUrl = imageUrls.length == 1
            ? _calculateUrl(imageUrls[0], proxy)
            : await _getBiggestImageUrl(imageUrls, proxy);

        imageSize = await _getImageSize(imageUrl);
        previewDataImage = PreviewDataImage(
          height: imageSize.height,
          url: imageUrl,
          width: imageSize.width,
        );
      }
      return PreviewData(
        description: previewDataDescription,
        image: previewDataImage,
        link: _getDomain(document, previewDataUrl),
        title: previewDataTitle,
      );
    } catch (e) {
      return PreviewData(
        description: previewDataDescription,
        image: previewDataImage,
        link: previewDataUrl,
        title: previewDataTitle,
      );
    }
  }

  static String _calculateUrl(String baseUrl, String? proxy) {
    if (proxy != null) {
      return '$proxy$baseUrl';
    }

    return baseUrl;
  }

  static String? _getMetaContent(Document document, String propertyValue) {
    final meta = document.getElementsByTagName('meta');
    final element = meta.firstWhere(
      (e) => e.attributes['property'] == propertyValue,
      orElse: () => meta.firstWhere(
        (e) => e.attributes['name'] == propertyValue,
        orElse: () => Element.tag(null),
      ),
    );

    return element.attributes['content']?.trim();
  }

  static bool _hasUTF8Charset(Document document) {
    final emptyElement = Element.tag(null);
    final meta = document.getElementsByTagName('meta');
    final element = meta.firstWhere(
      (e) => e.attributes.containsKey('charset'),
      orElse: () => emptyElement,
    );
    if (element == emptyElement) return true;
    return element.attributes['charset']!.toLowerCase() == 'utf-8';
  }

  static String? _getTitle(Document document) =>
      _getMetaContent(document, 'og:title') ??
      _getMetaContent(document, 'twitter:title') ??
      _getMetaContent(document, 'og:site_name') ??
      document.getElementsByTagName('title').firstOrNull?.text;

  static String? _getDescription(Document document) =>
      _getMetaContent(document, 'og:description') ??
      _getMetaContent(document, 'description') ??
      _getMetaContent(document, 'twitter:description');

  static String? _getDomain(Document document, String url) {
    try {
      final domainName = () {
        final canonicalLink = document.querySelector('link[rel=canonical]');
        if (canonicalLink != null && canonicalLink.attributes['href'] != null) {
          return canonicalLink.attributes['href'];
        }
        final ogUrlMeta = document.querySelector('meta[property="og:url"]');
        if (ogUrlMeta != null && ogUrlMeta.text.isNotEmpty) {
          return ogUrlMeta.text;
        }
        return null;
      }();

      return domainName != null
          ? Uri.parse(domainName).host.replaceFirst('www.', '')
          : Uri.parse(url).host.replaceFirst('www.', '');
    } catch (e) {
      print('Domain resolution failure Error:$e');
      return null;
    }
  }

  static List<String> _getImageUrls(Document document, String baseUrl) {
    final meta = document.getElementsByTagName('meta');
    var attribute = 'content';
    var elements = meta
        .where(
          (e) =>
              e.attributes['property'] == 'og:image' ||
              e.attributes['property'] == 'twitter:image',
        )
        .toList();

    if (elements.isEmpty) {
      elements = document.getElementsByTagName('img');
      attribute = 'src';
    }

    return elements.fold<List<String>>([], (previousValue, element) {
      final actualImageUrl = _getActualImageUrl(
        baseUrl,
        element.attributes[attribute]?.trim(),
      );

      return actualImageUrl != null
          ? [...previousValue, actualImageUrl]
          : previousValue;
    });
  }

  static String? _getActualImageUrl(String baseUrl, String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty || imageUrl.startsWith('data')) {
      return null;
    }

    if (imageUrl.contains('.svg') || imageUrl.contains('.gif')) return null;

    if (imageUrl.startsWith('//')) imageUrl = 'https:$imageUrl';

    if (!imageUrl.startsWith('http')) {
      if (baseUrl.endsWith('/') && imageUrl.startsWith('/')) {
        imageUrl = '${baseUrl.substring(0, baseUrl.length - 1)}$imageUrl';
      } else if (!baseUrl.endsWith('/') && !imageUrl.startsWith('/')) {
        imageUrl = '$baseUrl/$imageUrl';
      } else {
        imageUrl = '$baseUrl$imageUrl';
      }
    }

    return imageUrl;
  }

  static Future<Size> _getImageSize(String url) {
    final completer = Completer<Size>();
    final stream = Image.network(url).image.resolve(ImageConfiguration.empty);
    late ImageStreamListener streamListener;

    void onError(Object error, StackTrace? stackTrace) {
      completer.completeError(error, stackTrace);
    }

    void listener(ImageInfo info, bool _) {
      if (!completer.isCompleted) {
        completer.complete(
          Size(
            height: info.image.height.toDouble(),
            width: info.image.width.toDouble(),
          ),
        );
      }
      stream.removeListener(streamListener);
    }

    streamListener = ImageStreamListener(listener, onError: onError);

    stream.addListener(streamListener);
    return completer.future;
  }

  static Future<String> _getBiggestImageUrl(
    List<String> imageUrls,
    String? proxy,
  ) async {
    if (imageUrls.length > 5) {
      imageUrls.removeRange(5, imageUrls.length);
    }

    var currentUrl = imageUrls[0];
    var currentArea = 0.0;

    await Future.forEach(imageUrls, (String url) async {
      final size = await _getImageSize(_calculateUrl(url, proxy));
      final area = size.width * size.height;
      if (area > currentArea) {
        currentArea = area;
        currentUrl = _calculateUrl(url, proxy);
      }
    });

    return currentUrl;
  }
}

/// Regex to check if text is email.
const regexEmail = r'([a-zA-Z0-9+._-]+@[a-zA-Z0-9._-]+\.[a-zA-Z0-9_-]+)';

/// Regex to check if content type is an image.
const regexImageContentType = r'image\/*';

/// Regex to find all links in the text.
const regexLink =
    r'((http|ftp|https):\/\/)?([\w_-]+(?:(?:\.[\w_-]+)+))([\w.,@?^=%&:/~+#-]*[\w@?^=%&/~+#-])?';
