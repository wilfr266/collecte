import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_sync_manager.dart';
import 'supabase_client_provider.dart';

/// Table surveillée par Supabase Realtime. RLS s'applique côté serveur : un
/// abonné ne reçoit que les lignes qu'il a le droit de lire.
class LiveSource {
  const LiveSource(this.table, {this.filter});

  final String table;

  /// Filtre Realtime `colonne=eq.valeur`, appliqué en plus de RLS.
  final PostgresChangeFilter? filter;
}

/// Garde un écran à jour, comme `useLiveRefresh` de Terenza Admin :
/// - changement signalé par Realtime (tables publiées dans
///   `supabase_realtime` uniquement), regroupé sur 1,5 s ;
/// - retour de l'application au premier plan ;
/// - fin d'une synchronisation réussie (retour du réseau) ;
/// - reprise du canal Realtime après une coupure ;
/// - en secours, application visible seulement : toutes les [interval] tant
///   que Realtime n'est pas abonné, toutes les 5 minutes sinon.
class LiveRefresh extends ConsumerStatefulWidget {
  const LiveRefresh({
    required this.channel,
    required this.sources,
    required this.onRefresh,
    required this.child,
    this.interval = const Duration(seconds: 30),
    super.key,
  });

  final String channel;
  final List<LiveSource> sources;
  final VoidCallback onRefresh;
  final Duration interval;
  final Widget child;

  @override
  ConsumerState<LiveRefresh> createState() => _LiveRefreshState();
}

class _LiveRefreshState extends ConsumerState<LiveRefresh>
    with WidgetsBindingObserver {
  static const _debounce = Duration(milliseconds: 1500);
  static const _connectedInterval = Duration(minutes: 5);

  RealtimeChannel? _channel;
  Timer? _periodic;
  Timer? _pending;
  bool _foreground = true;
  bool _subscribed = false;
  bool _lost = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPeriodic();
    _subscribe();
  }

  @override
  void didUpdateWidget(LiveRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      _unsubscribe();
      _subscribe();
    }
    if (oldWidget.interval != widget.interval) _startPeriodic();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed && !_foreground) widget.onRefresh();
    _foreground = resumed;
  }

  void _startPeriodic() {
    _periodic?.cancel();
    final interval =
        _subscribed && widget.interval < _connectedInterval
        ? _connectedInterval
        : widget.interval;
    _periodic = Timer.periodic(interval, (_) {
      if (_foreground) widget.onRefresh();
    });
  }

  void _schedule() {
    _pending?.cancel();
    _pending = Timer(_debounce, () {
      if (mounted) widget.onRefresh();
    });
  }

  void _subscribe() {
    final client = ref.read(supabaseClientProvider);
    if (client == null || widget.sources.isEmpty) return;
    var channel = client.channel(widget.channel);
    for (final source in widget.sources) {
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: source.table,
        filter: source.filter,
        callback: (_) => _schedule(),
      );
    }
    final subscription = channel;
    _channel = channel
      ..subscribe((status, _) {
        if (!mounted || _channel != subscription) return;
        final subscribed = status == RealtimeSubscribeStatus.subscribed;
        // Reprise après coupure : Realtime ne rejoue pas les changements manqués.
        if (subscribed && _lost) _schedule();
        if (!subscribed) _lost = true;
        if (subscribed != _subscribed) {
          _subscribed = subscribed;
          _startPeriodic();
        }
      });
  }

  void _unsubscribe() {
    final channel = _channel;
    _channel = null;
    _lost = false;
    if (_subscribed) {
      _subscribed = false;
      _startPeriodic();
    }
    if (channel != null) {
      unawaited(ref.read(supabaseClientProvider)?.removeChannel(channel));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unsubscribe();
    _periodic?.cancel();
    _pending?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Retour du réseau : une synchronisation réussie relance le chargement.
    ref.listen(offlineSyncSnapshotProvider, (previous, next) {
      final was = previous?.valueOrNull?.status;
      final now = next.valueOrNull?.status;
      if (now == SyncStatus.completed && was != SyncStatus.completed) {
        widget.onRefresh();
      }
    });
    return widget.child;
  }
}
