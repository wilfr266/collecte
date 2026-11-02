import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../auth/presentation/auth_providers.dart';

class AgendaPage extends ConsumerStatefulWidget {
  const AgendaPage({super.key});

  @override
  ConsumerState<AgendaPage> createState() => _AgendaPageState();
}

class _AgendaPageState extends ConsumerState<AgendaPage> {
  bool _weekView = false;
  bool _loading = true;
  List<Map<String, dynamic>> _appointments = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  DateTimeRange _range() {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final start = _weekView
        ? day.subtract(Duration(days: day.weekday - 1))
        : day;
    return DateTimeRange(
      start: start,
      end: start.add(Duration(days: _weekView ? 7 : 1)),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = ref.read(supabaseClientProvider);
    final profile = await ref.read(currentProfileProvider.future);
    if (client == null || profile?.organizationId == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Session de collecteur indisponible.';
        });
      }
      return;
    }
    final range = _range();
    try {
      final rows = await client
          .from('appointments')
          .select(
            'id, starts_at, status, notes, establishments(name, address, latitude, longitude)',
          )
          .eq('organization_id', profile!.organizationId!)
          .eq('assigned_to', profile.id)
          .gte('starts_at', range.start.toUtc().toIso8601String())
          .lt('starts_at', range.end.toUtc().toIso8601String())
          .order('starts_at')
          .limit(100);
      if (mounted) {
        setState(() {
          _appointments = rows;
          _loading = false;
        });
      }
    } on PostgrestException {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Agenda inaccessible avec les droits actuels.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Réseau indisponible. Réessayez.';
        });
      }
    }
  }

  Future<void> _callAction(String function, Map<String, dynamic> params) async {
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    try {
      await client.rpc(function, params: params);
      await _load();
    } on PostgrestException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.code == '42501'
                  ? 'Action non autorisée pour ce compte.'
                  : 'La modification n’a pas pu être enregistrée. Réessayez.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Réseau indisponible. Réessayez.')),
        );
      }
    }
  }

  Future<void> _start(String id) =>
      _callAction('start_appointment', {'p_appointment_id': id});

  Future<void> _finish(Map<String, dynamic> item) async {
    final result = await showDialog<_VisitResult>(
      context: context,
      builder: (context) => const _FinishVisitDialog(),
    );
    if (result == null) return;
    await _callAction('finish_appointment', {
      'p_appointment_id': item['id'],
      'p_result': result.status,
      'p_notes': result.notes,
    });
  }

  Future<void> _reschedule(Map<String, dynamic> item) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      initialDate: now.add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null || !mounted) return;
    final reason = await _askReason(context, 'Motif du report');
    if (reason == null || reason.trim().length < 5) return;
    final startsAt = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    await _callAction('reschedule_appointment', {
      'p_appointment_id': item['id'],
      'p_new_starts_at': startsAt.toUtc().toIso8601String(),
      'p_reason': reason.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Agenda'),
      actions: [
        IconButton(
          tooltip: 'Actualiser l’agenda',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Jour')),
              ButtonSegment(value: true, label: Text('Semaine')),
            ],
            selected: {_weekView},
            onSelectionChanged: (value) {
              setState(() => _weekView = value.first);
              _load();
            },
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : !_loading && _appointments.isEmpty
              ? const Center(
                  child: Text('Aucun rendez-vous sur cette période.'),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _appointments.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) => _AppointmentCard(
                    item: _appointments[index],
                    onStart: () => _start(_appointments[index]['id'] as String),
                    onFinish: () => _finish(_appointments[index]),
                    onReschedule: () => _reschedule(_appointments[index]),
                  ),
                ),
        ),
      ],
    ),
  );
}

class _AppointmentCard extends StatelessWidget {
  const _AppointmentCard({
    required this.item,
    required this.onStart,
    required this.onFinish,
    required this.onReschedule,
  });

  final Map<String, dynamic> item;
  final VoidCallback onStart;
  final VoidCallback onFinish;
  final VoidCallback onReschedule;

  @override
  Widget build(BuildContext context) {
    final establishment = item['establishments'] as Map<String, dynamic>?;
    final time = DateTime.parse(item['starts_at'] as String).toLocal();
    final status = item['status'] as String;
    final latitude = establishment?['latitude'];
    final longitude = establishment?['longitude'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${time.hour.toString().padLeft(2, '0')} h ${time.minute.toString().padLeft(2, '0')}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(establishment?['name'] as String? ?? 'Établissement'),
            if (establishment?['address'] != null)
              Text(establishment!['address'] as String),
            if (latitude != null && longitude != null)
              Text('Coordonnées · $latitude, $longitude'),
            const SizedBox(height: 8),
            Text(_appointmentStatus(status)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (status == 'scheduled')
                  FilledButton.tonal(
                    onPressed: onStart,
                    child: const Text('Démarrer'),
                  ),
                if (status == 'scheduled' || status == 'in_progress')
                  OutlinedButton(
                    onPressed: onFinish,
                    child: const Text('Terminer / absence'),
                  ),
                if (status == 'scheduled')
                  IconButton(
                    tooltip: 'Reporter',
                    onPressed: onReschedule,
                    icon: const Icon(Icons.event_repeat),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FinishVisitDialog extends StatefulWidget {
  const _FinishVisitDialog();

  @override
  State<_FinishVisitDialog> createState() => _FinishVisitDialogState();
}

class _FinishVisitDialogState extends State<_FinishVisitDialog> {
  String _status = 'completed';
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Résultat de visite'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _status,
          items: const [
            DropdownMenuItem(
              value: 'completed',
              child: Text('Visite terminée'),
            ),
            DropdownMenuItem(
              value: 'missed',
              child: Text('Contribuable absent'),
            ),
            DropdownMenuItem(value: 'cancelled', child: Text('Visite annulée')),
          ],
          onChanged: (value) => setState(() => _status = value ?? 'completed'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notes,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: _status == 'completed'
                ? 'Compte rendu (facultatif)'
                : 'Motif obligatoire',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annuler'),
      ),
      FilledButton(
        onPressed: () {
          if (_status != 'completed' && _notes.text.trim().length < 5) return;
          Navigator.pop(context, _VisitResult(_status, _notes.text.trim()));
        },
        child: const Text('Enregistrer'),
      ),
    ],
  );
}

class _VisitResult {
  const _VisitResult(this.status, this.notes);

  final String status;
  final String notes;
}

Future<String?> _askReason(BuildContext context, String title) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, minLines: 2, maxLines: 4),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Confirmer'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

String _appointmentStatus(String value) => switch (value) {
  'in_progress' => 'En cours',
  'completed' => 'Terminée',
  'missed' => 'Absence',
  'cancelled' => 'Annulée',
  _ => 'Planifiée',
};
