import 'package:flutter/foundation.dart';

/// Colab runtime variant (Colab API `Key.variant`).
enum RuntimeVariant {
  cpu('CPU'),
  gpu('GPU'),
  tpu('TPU'),
  unknown('Unknown');

  const RuntimeVariant(this.label);
  final String label;

  static RuntimeVariant parse(Object? v) => switch (v) {
    'VARIANT_CPU' => cpu,
    'VARIANT_GPU' => gpu,
    'VARIANT_TPU' => tpu,
    _ => unknown,
  };

  String get apiValue => switch (this) {
    cpu => 'VARIANT_CPU',
    gpu => 'VARIANT_GPU',
    tpu => 'VARIANT_TPU',
    unknown => 'VARIANT_UNSPECIFIED',
  };
}

/// Machine shape (Colab API `Key.shape`).
enum RuntimeShape {
  standard('Standard RAM'),
  highMem('High RAM'),
  unknown('');

  const RuntimeShape(this.label);
  final String label;

  static RuntimeShape parse(Object? v) => switch (v) {
    'SHAPE_STANDARD' => standard,
    'SHAPE_HIGHMEM' => highMem,
    _ => unknown,
  };

  String get apiValue => switch (this) {
    standard => 'SHAPE_STANDARD',
    highMem => 'SHAPE_HIGHMEM',
    unknown => 'SHAPE_UNSPECIFIED',
  };
}

/// Identifies a runtime type: variant + accelerator + shape.
@immutable
class RuntimeSpecKey {
  const RuntimeSpecKey({
    required this.variant,
    required this.shape,
    this.accelerator = '',
  });

  factory RuntimeSpecKey.fromJson(Map<String, dynamic> j) => RuntimeSpecKey(
    variant: RuntimeVariant.parse(j['variant']),
    shape: RuntimeShape.parse(j['shape']),
    accelerator: (j['accelerator'] as String?) ?? '',
  );

  final RuntimeVariant variant;
  final RuntimeShape shape;

  /// e.g. "T4", "L4", "A100", "V5E1"; empty or "NONE" for CPU.
  final String accelerator;

  /// "T4 GPU", "CPU", "V5E1 TPU".
  String get label {
    final acc = accelerator.toUpperCase();
    if (variant == RuntimeVariant.cpu || acc.isEmpty || acc == 'NONE') {
      return variant.label;
    }
    return '$accelerator ${variant.label}';
  }

  Map<String, dynamic> toJson() => {
    'variant': variant.apiValue,
    'shape': shape.apiValue,
    'accelerator': accelerator,
  };

  @override
  bool operator ==(Object other) =>
      other is RuntimeSpecKey &&
      other.variant == variant &&
      other.shape == shape &&
      other.accelerator == accelerator;

  @override
  int get hashCode => Object.hash(variant, shape, accelerator);

  @override
  String toString() => '$label (${shape.label})';
}

/// A runtime type the user may request (CPU / T4 GPU / …).
@immutable
class RuntimeSpecOption {
  const RuntimeSpecOption({required this.key, required this.eligible});

  factory RuntimeSpecOption.fromJson(Map<String, dynamic> j) =>
      RuntimeSpecOption(
        key: RuntimeSpecKey.fromJson(
          (j['key'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        eligible: j['eligible'] as bool? ?? false,
      );

  final RuntimeSpecKey key;

  /// Whether the user's plan currently allows this runtime type.
  final bool eligible;
}

/// Short-lived credentials for the runtime's Jupyter server.
@immutable
class RuntimeConnection {
  const RuntimeConnection({
    required this.url,
    required this.token,
    this.expireTime,
  });

  factory RuntimeConnection.fromJson(Map<String, dynamic> j) =>
      RuntimeConnection(
        url: j['url'] as String? ?? '',
        token: j['token'] as String? ?? '',
        expireTime: DateTime.tryParse(j['expireTime'] as String? ?? ''),
      );

  final String url;
  final String token;
  final DateTime? expireTime;
}

/// A Colab runtime assigned to the user (spec §4.3 `RuntimeInfo`).
@immutable
class RuntimeInfo {
  const RuntimeInfo({
    required this.name,
    required this.spec,
    this.version,
    this.connection,
  });

  factory RuntimeInfo.fromJson(Map<String, dynamic> j) => RuntimeInfo(
    name: j['name'] as String? ?? '',
    spec: RuntimeSpecKey.fromJson(
      (j['runtimeSpec'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    version: j['version'] as String?,
    connection: j['connectionInfo'] is Map
        ? RuntimeConnection.fromJson(
            (j['connectionInfo'] as Map).cast<String, dynamic>(),
          )
        : null,
  );

  /// `runtimes/{id}`.
  final String name;
  final RuntimeSpecKey spec;
  final String? version;
  final RuntimeConnection? connection;

  String get id => name.split('/').last;
}

/// The user's Colab plan.
enum SubscriptionTier {
  free('Colab Free'),
  pro('Colab Pro'),
  proPlus('Colab Pro+'),
  unknown('Unknown plan');

  const SubscriptionTier(this.label);
  final String label;

  static SubscriptionTier parse(Object? v) => switch (v) {
    'SUBSCRIPTION_TIER_FREE' => free,
    'SUBSCRIPTION_TIER_PRO' => pro,
    'SUBSCRIPTION_TIER_PRO_PLUS' => proPlus,
    _ => unknown,
  };
}

/// Kernel state (spec §4.3 `KernelStatus`).
enum KernelStatus { starting, idle, busy, disconnected }
