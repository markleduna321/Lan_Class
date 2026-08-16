// lib/features/auth/user_model.dart

enum UserRole { presenter, audience }

abstract class BaseUser {
  final String firstName;
  final String lastName;
  final String? middleName;
  final String email;
  final UserRole role;

  BaseUser({
    required this.firstName,
    required this.lastName,
    this.middleName,
    required this.email,
    required this.role,
  });
}

class PresenterUser extends BaseUser {
  final String profession;
  final String specialties;

  PresenterUser({
    required super.firstName,
    required super.lastName,
    super.middleName,
    required super.email,
    required this.profession,
    required this.specialties,
  }) : super(role: UserRole.presenter);
}

class AudienceUser extends BaseUser {
  AudienceUser({
    required super.firstName,
    required super.lastName,
    super.middleName,
    required super.email,
  }) : super(role: UserRole.audience);
}