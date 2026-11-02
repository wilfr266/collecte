import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Cause d'un échec de connexion, distinguée pour afficher le bon message.
///
/// Une erreur réseau ne doit jamais être présentée comme un mauvais mot de
/// passe, ni l'inverse. Les problèmes de profil, de rôle ou de RLS ne passent
/// pas par ici : ils surviennent après l'authentification et sont traités par
/// `AccessDecision`.
enum LoginFailure {
  invalidCredentials,
  emailNotConfirmed,
  rateLimited,
  accountBlocked,
  network,
  server,
  notConfigured,
  unknown;

  String get message => switch (this) {
    invalidCredentials => 'Adresse e-mail ou mot de passe incorrect.',
    emailNotConfirmed =>
      'Votre adresse e-mail n’est pas encore confirmée. Contactez votre administrateur.',
    rateLimited =>
      'Trop de tentatives de connexion. Patientez quelques minutes puis réessayez.',
    accountBlocked =>
      'Ce compte ne peut pas se connecter. Contactez votre administrateur.',
    network => 'Vérifiez votre connexion Internet puis réessayez.',
    server =>
      'Le service de connexion rencontre un problème. Réessayez dans quelques minutes.',
    notConfigured =>
      'L’application n’est pas encore configurée. Contactez votre administrateur.',
    unknown => 'Connexion impossible pour le moment. Réessayez plus tard.',
  };
}

/// Classe l'erreur levée par `signInWithPassword`.
///
/// gotrue enveloppe les erreurs de transport (absence de réseau, permission
/// Android INTERNET manquante, DNS, TLS) et les réponses 5xx dans
/// [AuthRetryableFetchException], qui hérite d'[AuthException] : le statut
/// HTTP doit donc être examiné, pas seulement le type.
LoginFailure classifyLoginError(Object error) {
  if (error is TimeoutException ||
      error is SocketException ||
      error is HandshakeException) {
    return LoginFailure.network;
  }
  if (error is AuthRetryableFetchException) {
    final status = int.tryParse(error.statusCode ?? '');
    return status != null && status >= 500
        ? LoginFailure.server
        : LoginFailure.network;
  }
  if (error is AuthException) {
    switch (error.code) {
      case 'invalid_credentials':
        return LoginFailure.invalidCredentials;
      case 'email_not_confirmed':
        return LoginFailure.emailNotConfirmed;
      case 'over_request_rate_limit':
      case 'over_email_send_rate_limit':
        return LoginFailure.rateLimited;
      case 'user_banned':
        return LoginFailure.accountBlocked;
      // Ne révèle pas l'existence d'un compte.
      case 'user_not_found':
        return LoginFailure.invalidCredentials;
    }
    final status = int.tryParse(error.statusCode ?? '');
    return switch (status) {
      400 || 401 => LoginFailure.invalidCredentials,
      403 => LoginFailure.accountBlocked,
      429 => LoginFailure.rateLimited,
      final s? when s >= 500 => LoginFailure.server,
      _ => LoginFailure.unknown,
    };
  }
  if (error is StateError) return LoginFailure.notConfigured;
  // http.ClientException et équivalents : erreur de transport.
  if (error.runtimeType.toString().contains('ClientException')) {
    return LoginFailure.network;
  }
  return LoginFailure.unknown;
}
