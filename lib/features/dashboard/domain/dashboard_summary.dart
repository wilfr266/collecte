class DashboardSummary {
  const DashboardSummary({
    required this.displayName,
    required this.missionsToday,
    required this.collectionsToday,
    required this.amountCollectedCfa,
    required this.appointmentsToday,
    required this.unreadNotifications,
    required this.missions,
    this.mainZone,
    this.nextAppointment,
  });

  final String displayName;
  final int missionsToday;
  final int collectionsToday;
  final int amountCollectedCfa;
  final int appointmentsToday;
  final int unreadNotifications;
  final String? mainZone;
  final String? nextAppointment;
  final List<DashboardMission> missions;
}

class DashboardMission {
  const DashboardMission({
    required this.title,
    required this.zone,
    required this.status,
    required this.scheduledFor,
  });

  final String title;
  final String zone;
  final String status;
  final DateTime scheduledFor;
}
