import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:crypto/crypto.dart';
import 'speech_audio.dart';
import 'speech_error_reporter.dart';

/// TTS Cache Manager
/// Handles audio caching across platforms
class TTSCacheManager {
  static final TTSCacheManager instance = TTSCacheManager._internal();

  TTSCacheManager._internal();

  @visibleForTesting
  TTSCacheManager.forTesting(Directory directory) : _testDirectory = directory;

  Directory? _testDirectory;

  // Cache key prefix for shared preferences
  static const String _cacheKeyPrefix = 'tts_cache_';
  static const String _cacheMetadataKey = 'tts_cache_metadata';

  // Maximum cache size (in MB) - default 50MB
  static const int _maxCacheSizeMB = 50;

  // Maximum number of cached items - default 500
  static const int _maxCacheItems = 500;

  /// Generate cache key for text
  String _getCacheKey(String text) {
    // Use SHA-256 hash for better collision resistance
    final bytes = utf8.encode(text);
    final hash = sha256.convert(bytes);
    return '$_cacheKeyPrefix${hash.toString()}';
  }

  /// Get cached audio for text (Web platform)
  /// Returns base64 encoded audio data or null if not cached
  Future<String?> getCachedAudioWeb(String text) async {
    if (!kIsWeb) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = _getCacheKey(text);
      final cachedData = prefs.getString(cacheKey);

      if (cachedData != null) {
        try {
          decodeSpeechAudio(cachedData);
        } on SpeechAudioException {
          await prefs.remove(cacheKey);
          reportSpeechFailure('cache', 'speech-cache-invalid');
          return null;
        }
        // Update access time
        await _updateCacheMetadata(cacheKey);
        return cachedData;
      }
    } catch (e) {
      reportSpeechFailure('cache', 'speech-cache-read-failed');
    }

    return null;
  }

  /// Cache audio for text (Web platform)
  /// audioData should be base64 encoded audio
  Future<void> cacheAudioWeb(String text, String audioData) async {
    if (!kIsWeb) return;

    decodeSpeechAudio(audioData);

    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = _getCacheKey(text);

      // Check cache size limit
      await _enforceCacheLimits(prefs);

      // Store audio data
      await prefs.setString(cacheKey, audioData);

      // Update metadata
      await _updateCacheMetadata(cacheKey);

      debugPrint('Cached speech audio (web)');
    } catch (e) {
      reportSpeechFailure('cache', 'speech-cache-write-failed');
    }
  }

  /// Get cached audio file path (Mobile platforms)
  Future<String?> getCachedAudioPath(
    String text, {
    String namespace = 'tts',
  }) async {
    if (kIsWeb) return null;

    try {
      final cacheDir = await _getCacheDirectory();
      final fileName = _getFileNameForText(text, namespace: namespace);
      final filePath = path.join(cacheDir, fileName);

      final file = File(filePath);
      if (await file.exists()) {
        final length = await file.length();
        if (length <= 900000 && isValidMp3(await file.readAsBytes())) {
          // Update access time
          await _updateFileAccessTime(filePath);
          return filePath;
        } else {
          reportSpeechFailure('cache', 'speech-cache-invalid');
          await file.delete();
        }
      }
    } catch (e) {
      reportSpeechFailure('cache', 'speech-cache-read-failed');
    }

    return null;
  }

  /// Save audio file (Mobile platforms)
  Future<String> saveAudioFile(
    String text,
    List<int> audioBytes, {
    String namespace = 'tts',
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('saveAudioFile not supported on web');
    }
    if (!isValidMp3(audioBytes)) {
      reportSpeechFailure('cache', 'speech-cache-invalid');
      throw const SpeechAudioException('speech-invalid-mp3');
    }

    try {
      final cacheDir = await _getCacheDirectory();

      // Check cache size limit
      await _enforceCacheSizeLimit(cacheDir);

      final fileName = _getFileNameForText(text, namespace: namespace);
      final filePath = path.join(cacheDir, fileName);

      // Atomic rename keeps interrupted writes from becoming reusable files.
      final temporary =
          File('$filePath.${DateTime.now().microsecondsSinceEpoch}.part');
      try {
        await temporary.writeAsBytes(audioBytes, flush: true);
        await temporary.rename(filePath);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }

      // Update access time
      await _updateFileAccessTime(filePath);

      debugPrint('Saved audio file: $fileName');
      return filePath;
    } catch (e) {
      reportSpeechFailure('cache', 'speech-cache-write-failed');
      rethrow;
    }
  }

  /// Check if audio is cached
  Future<bool> isCached(String text) async {
    if (kIsWeb) {
      final cached = await getCachedAudioWeb(text);
      return cached != null;
    } else {
      final cachedPath = await getCachedAudioPath(text);
      return cachedPath != null;
    }
  }

  /// Clear all cached audio
  Future<void> clearCache() async {
    try {
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        final keys = prefs.getKeys();
        final cacheKeys = keys.where((key) => key.startsWith(_cacheKeyPrefix));

        for (final key in cacheKeys) {
          await prefs.remove(key);
        }

        await prefs.remove(_cacheMetadataKey);
        debugPrint('Cleared web cache: ${cacheKeys.length} items');
      } else {
        final cacheDir = await _getCacheDirectory();
        final dir = Directory(cacheDir);

        if (await dir.exists()) {
          await dir.delete(recursive: true);
          await dir.create(recursive: true);
          debugPrint('Cleared mobile cache directory');
        }
      }
    } catch (e) {
      debugPrint('Error clearing cache: $e');
    }
  }

  Future<void> clearNamespace(String namespace) async {
    if (kIsWeb) return;
    final safeNamespace = _safeNamespace(namespace);
    try {
      final cacheDir = await _getCacheDirectory();
      final directory = Directory(cacheDir);
      if (!await directory.exists()) return;
      await for (final entity in directory.list()) {
        if (entity is File &&
            path.basename(entity.path).startsWith('${safeNamespace}_')) {
          await entity.delete();
        }
      }
    } on MissingPluginException {
      // Unit tests do not register path_provider. There is no device cache to
      // clear in that environment.
    } catch (e) {
      debugPrint('Error clearing TTS namespace $safeNamespace: $e');
    }
  }

  /// Get cache size (in bytes)
  Future<int> getCacheSize() async {
    try {
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        final keys = prefs.getKeys();
        final cacheKeys = keys.where((key) => key.startsWith(_cacheKeyPrefix));

        int totalSize = 0;
        for (final key in cacheKeys) {
          final data = prefs.getString(key);
          if (data != null) {
            // Approximate size (base64 is ~33% larger than binary)
            totalSize += (data.length * 3 / 4).round();
          }
        }

        return totalSize;
      } else {
        final cacheDir = await _getCacheDirectory();
        final dir = Directory(cacheDir);

        if (!await dir.exists()) {
          return 0;
        }

        int totalSize = 0;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            totalSize += await entity.length();
          }
        }

        return totalSize;
      }
    } catch (e) {
      debugPrint('Error getting cache size: $e');
      return 0;
    }
  }

  /// Get cache statistics
  Future<Map<String, dynamic>> getCacheStats() async {
    final size = await getCacheSize();
    final sizeMB = (size / (1024 * 1024)).toStringAsFixed(2);

    int itemCount = 0;
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      itemCount = keys.where((key) => key.startsWith(_cacheKeyPrefix)).length;
    } else {
      try {
        final cacheDir = await _getCacheDirectory();
        final dir = Directory(cacheDir);
        if (await dir.exists()) {
          itemCount = await dir.list().length;
        }
      } catch (e) {
        // Ignore
      }
    }

    return {
      'size_bytes': size,
      'size_mb': sizeMB,
      'item_count': itemCount,
      'max_size_mb': _maxCacheSizeMB,
      'max_items': _maxCacheItems,
    };
  }

  /// Update cache metadata (for LRU eviction)
  Future<void> _updateCacheMetadata(String cacheKey) async {
    if (!kIsWeb) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final metadataJson = prefs.getString(_cacheMetadataKey);

      Map<String, int> metadata = {};
      if (metadataJson != null) {
        metadata = Map<String, int>.from(json.decode(metadataJson));
      }

      metadata[cacheKey] = DateTime.now().millisecondsSinceEpoch;
      await prefs.setString(_cacheMetadataKey, json.encode(metadata));
    } catch (e) {
      // Ignore metadata errors
    }
  }

  /// Enforce cache limits (Web platform)
  Future<void> _enforceCacheLimits(SharedPreferences prefs) async {
    try {
      final keys = prefs.getKeys();
      final cacheKeys =
          keys.where((key) => key.startsWith(_cacheKeyPrefix)).toList();

      // Check item count limit
      if (cacheKeys.length >= _maxCacheItems) {
        await _evictOldestItems(prefs, cacheKeys.length - _maxCacheItems + 1);
      }

      // Check size limit
      int totalSize = 0;
      final keySizes = <String, int>{};

      for (final key in cacheKeys) {
        final data = prefs.getString(key);
        if (data != null) {
          final size = (data.length * 3 / 4).round(); // Approximate binary size
          keySizes[key] = size;
          totalSize += size;
        }
      }

      const maxSizeBytes = _maxCacheSizeMB * 1024 * 1024;
      if (totalSize > maxSizeBytes) {
        // Sort by access time and remove oldest
        final metadataJson = prefs.getString(_cacheMetadataKey);
        Map<String, int> metadata = {};
        if (metadataJson != null) {
          metadata = Map<String, int>.from(json.decode(metadataJson));
        }

        // Sort by access time (oldest first)
        cacheKeys.sort((a, b) {
          final timeA = metadata[a] ?? 0;
          final timeB = metadata[b] ?? 0;
          return timeA.compareTo(timeB);
        });

        // Remove oldest items until under limit
        int currentSize = totalSize;
        for (final key in cacheKeys) {
          if (currentSize <= maxSizeBytes) break;

          final size = keySizes[key] ?? 0;
          await prefs.remove(key);
          metadata.remove(key);
          currentSize -= size;
        }

        await prefs.setString(_cacheMetadataKey, json.encode(metadata));
      }
    } catch (e) {
      debugPrint('Error enforcing cache limits: $e');
    }
  }

  /// Evict oldest items from cache
  Future<void> _evictOldestItems(SharedPreferences prefs, int count) async {
    try {
      final metadataJson = prefs.getString(_cacheMetadataKey);
      if (metadataJson == null) return;

      Map<String, int> metadata =
          Map<String, int>.from(json.decode(metadataJson));

      // Sort by access time (oldest first)
      final sortedKeys = metadata.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));

      // Remove oldest items
      for (int i = 0; i < count && i < sortedKeys.length; i++) {
        final key = sortedKeys[i].key;
        await prefs.remove(key);
        metadata.remove(key);
      }

      await prefs.setString(_cacheMetadataKey, json.encode(metadata));
    } catch (e) {
      debugPrint('Error evicting oldest items: $e');
    }
  }

  /// Enforce cache size limit (Mobile platforms)
  Future<void> _enforceCacheSizeLimit(String cacheDir) async {
    try {
      final dir = Directory(cacheDir);
      if (!await dir.exists()) return;

      // Get all files with their sizes and modification times
      final files = <File, int>{};
      int totalSize = 0;

      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.mp3')) {
          final size = await entity.length();
          files[entity] = size;
          totalSize += size;
        }
      }

      const maxSizeBytes = _maxCacheSizeMB * 1024 * 1024;

      if (totalSize > maxSizeBytes || files.length >= _maxCacheItems) {
        // Sort by modification time (oldest first)
        final sortedFiles = files.keys.toList()
          ..sort((a, b) {
            final statA = a.statSync();
            final statB = b.statSync();
            return statA.modified.compareTo(statB.modified);
          });

        // Remove oldest files until under limit
        int currentSize = totalSize;
        int currentCount = files.length;

        for (final file in sortedFiles) {
          if (currentSize <= maxSizeBytes && currentCount < _maxCacheItems) {
            break;
          }

          final size = files[file] ?? 0;
          await file.delete();
          currentSize -= size;
          currentCount--;
        }
      }
    } catch (e) {
      debugPrint('Error enforcing cache size limit: $e');
    }
  }

  /// Update file access time (Mobile platforms)
  Future<void> _updateFileAccessTime(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        // Touch the file to update modification time
        await file.setLastModified(DateTime.now());
      }
    } catch (e) {
      // Ignore errors
    }
  }

  /// Get cache directory (Mobile platforms)
  Future<String> _getCacheDirectory() async {
    if (kIsWeb) {
      throw UnsupportedError('Cache directory not available on web');
    }

    if (_testDirectory != null) {
      await _testDirectory!.create(recursive: true);
      return _testDirectory!.path;
    }
    final directory = await getTemporaryDirectory();
    final ttsDir = path.join(directory.path, 'tts_cache');
    final dir = Directory(ttsDir);

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return ttsDir;
  }

  /// Generate filename for text (hash-based)
  String _getFileNameForText(
    String text, {
    required String namespace,
  }) {
    // Use SHA-256 hash for better collision resistance
    final bytes = utf8.encode(text);
    final hash = sha256.convert(bytes);
    return '${_safeNamespace(namespace)}_${hash.toString()}.mp3';
  }

  String _safeNamespace(String value) {
    final normalized = value.toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9_-]'),
          '_',
        );
    return normalized.isEmpty ? 'tts' : normalized;
  }

  /// Remove only one runtime file rejected by the decoder, not offline packs.
  Future<void> evictPlaybackSource(String source) async {
    if (kIsWeb) return;
    final root = await _getCacheDirectory();
    if (path.dirname(source) != root || !source.endsWith('.mp3')) return;
    final file = File(source);
    if (await file.exists()) await file.delete();
  }
}
