import 'package:geolocator/geolocator.dart';

enum VisitLocationStatus {
  captured,
  permissionDenied,
  serviceDisabled,
  unavailable,
  insufficientAccuracy,
}

class VisitLocationResult {
  const VisitLocationResult({
    required this.status,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.capturedAt,
  });

  final VisitLocationStatus status;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final DateTime? capturedAt;

  bool get hasUsableLocation => status == VisitLocationStatus.captured;
}

class VisitLocationService {
  const VisitLocationService();

  static const _maximumAccuracyMeters = 100.0;

  Future<VisitLocationResult> captureForVisit() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const VisitLocationResult(
          status: VisitLocationStatus.serviceDisabled,
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever ||
          permission == LocationPermission.unableToDetermine) {
        return const VisitLocationResult(
          status: VisitLocationStatus.permissionDenied,
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final capturedAt = position.timestamp;
      if (position.accuracy <= 0 ||
          position.accuracy > _maximumAccuracyMeters) {
        return VisitLocationResult(
          status: VisitLocationStatus.insufficientAccuracy,
          accuracyMeters: position.accuracy,
          capturedAt: capturedAt,
        );
      }

      return VisitLocationResult(
        status: VisitLocationStatus.captured,
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        capturedAt: capturedAt,
      );
    } catch (_) {
      return const VisitLocationResult(status: VisitLocationStatus.unavailable);
    }
  }
}
