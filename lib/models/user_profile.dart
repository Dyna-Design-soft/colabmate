import 'package:flutter/foundation.dart';

/// The signed-in Google user, as shown in the UI.
@immutable
class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    this.name,
    this.photoUrl,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'] as String,
    email: json['email'] as String,
    name: json['name'] as String?,
    photoUrl: json['photoUrl'] as String?,
  );

  final String id;
  final String email;
  final String? name;
  final String? photoUrl;

  /// Name to show in the UI; falls back to the email address.
  String get displayName =>
      (name == null || name!.trim().isEmpty) ? email : name!;

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'name': name,
    'photoUrl': photoUrl,
  };

  @override
  bool operator ==(Object other) =>
      other is UserProfile &&
      other.id == id &&
      other.email == email &&
      other.name == name &&
      other.photoUrl == photoUrl;

  @override
  int get hashCode => Object.hash(id, email, name, photoUrl);

  @override
  String toString() => 'UserProfile($email)';
}
