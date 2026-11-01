import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/auth_exceptions.dart';
import '../core/runtime/colab_api.dart';
import '../models/runtime_status.dart';
import 'auth_provider.dart';

final colabApiProvider = Provider<ColabApi>(
  (ref) => ColabApi(auth: ref.watch(authManagerProvider)),
);

/// What the Colab screen shows.
@immutable
class ColabOverview {
  const ColabOverview({
    this.needsGrant = false,
    this.tier = SubscriptionTier.unknown,
    this.specs = const [],
    this.runtimes = const [],
  });

  /// Colab access hasn't been granted yet — show the "Allow" button.
  final bool needsGrant;
  final SubscriptionTier tier;
  final List<RuntimeSpecOption> specs;
  final List<RuntimeInfo> runtimes;
}

final colabOverviewProvider =
    AsyncNotifierProvider<ColabOverviewController, ColabOverview>(
      ColabOverviewController.new,
      retry: (_, _) => null,
    );

class ColabOverviewController extends AsyncNotifier<ColabOverview> {
  ColabApi get _api => ref.read(colabApiProvider);

  @override
  Future<ColabOverview> build() async {
    try {
      final results = await Future.wait([
        _api.getSubscription(),
        _api.listRuntimeSpecs(),
        _api.listRuntimes(),
      ]);
      return ColabOverview(
        tier: results[0] as SubscriptionTier,
        specs: results[1] as List<RuntimeSpecOption>,
        runtimes: results[2] as List<RuntimeInfo>,
      );
    } on ScopeNotGrantedException {
      return const ColabOverview(needsGrant: true);
    }
  }

  /// Shows Google's consent screen for Colab access, then reloads.
  Future<void> grantAndLoad() async {
    state = const AsyncLoading();
    try {
      await _api.grantAccess();
    } catch (e, st) {
      state = AsyncError(e, st);
      return;
    }
    ref.invalidateSelf();
    await future.catchError((_) => const ColabOverview());
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future.catchError((_) => const ColabOverview());
  }
}
