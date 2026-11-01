import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../models/user_profile.dart';

/// Credentials persisted between app launches.
@immutable
class StoredCredentials {
  const StoredCredentials({
    required this.accessToken,
    required this.expiresAt,
    required this.profile,
    this.refreshToken,
  });

  factory StoredCredentials.fromJson(Map<String, dynamic> json) =>
      StoredCredentials(
        accessToken: json['accessToken'] as String,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        refreshToken: json['refreshToken'] as String?,
        profile: UserProfile.fromJson(
          (json['profile'] as Map).cast<String, dynamic>(),
        ),
      );

  final String accessToken;
  final DateTime expiresAt;

  /// Only present for the Windows loopback flow. On Android the Google Play
  /// Services SDK keeps the long-lived grant itself.
  final String? refreshToken;
  final UserProfile profile;

  bool isExpired(DateTime now, {Duration margin = Duration.zero}) =>
      !now.add(margin).isBefore(expiresAt);

  StoredCredentials copyWith({
    String? accessToken,
    DateTime? expiresAt,
    String? refreshToken,
    UserProfile? profile,
  }) => StoredCredentials(
    accessToken: accessToken ?? this.accessToken,
    expiresAt: expiresAt ?? this.expiresAt,
    refreshToken: refreshToken ?? this.refreshToken,
    profile: profile ?? this.profile,
  );

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'refreshToken': refreshToken,
    'profile': profile.toJson(),
  };
}

/// Minimal key/value interface so tests can swap out the platform plugin.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Backed by `flutter_secure_storage`: Android Keystore on Android, Windows
/// Credential Manager on Windows (NFR-02). Nothing is stored in plain text.
class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Reads and writes [StoredCredentials] in secure storage.
class TokenStorage {
  TokenStorage([SecureKeyValueStore? store])
    : _store = store ?? FlutterSecureKeyValueStore();

  static const String _key = 'colabmate.credentials.v1';

  final SecureKeyValueStore _store;

  Future<StoredCredentials?> read() async {
    final String? raw;
    try {
      raw = await _store.read(_key);
    } catch (e) {
      // E.g. Android Keystore was reset and the entry can't be decrypted.
      debugPrint('TokenStorage: secure storage read failed ($e)');
      try {
        await clear();
      } catch (_) {}
      return null;
    }
    if (raw == null) return null;
    try {
      return StoredCredentials.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (e) {
      // Corrupt or from an incompatible version: drop it and force sign-in.
      debugPrint('TokenStorage: discarding unreadable credentials ($e)');
      await clear();
      return null;
    }
  }

  Future<void> write(StoredCredentials credentials) =>
      _store.write(_key, jsonEncode(credentials.toJson()));

  Future<void> clear() => _store.delete(_key);
}
