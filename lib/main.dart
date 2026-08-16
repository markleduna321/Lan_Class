import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:asuratech_lan_classroom/features/auth/signup_view.dart';
import 'package:asuratech_lan_classroom/features/auth/login_view.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:asuratech_lan_classroom/features/auth/user_model.dart';
import 'package:asuratech_lan_classroom/features/classroom/main_app_shell.dart';
import 'package:asuratech_lan_classroom/database/asura_repository.dart';
import 'package:asuratech_lan_classroom/features/auth/role_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  runApp(const AsuraTechClassroomApp());
}

const kBrandColor = Color(0xFF1E3A8A);

class AsuraTechClassroomApp extends StatelessWidget {
  const AsuraTechClassroomApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ColorScheme.fromSeed(
      seedColor: kBrandColor,
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'AsuraTECH LAN Classroom',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: base,
        useMaterial3: true,
        appBarTheme: AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          backgroundColor: kBrandColor,
          foregroundColor: Colors.white,
          iconTheme: const IconThemeData(color: Colors.white),
          actionsIconTheme: const IconThemeData(color: Colors.white),
          titleTextStyle: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
          systemOverlayStyle: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          height: 68,
          backgroundColor: Colors.white,
          indicatorColor: kBrandColor.withValues(alpha: 0.12),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const IconThemeData(color: kBrandColor, size: 24);
            }
            return IconThemeData(color: Colors.grey.shade500, size: 22);
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const TextStyle(
                  color: kBrandColor, fontSize: 12, fontWeight: FontWeight.w600);
            }
            return TextStyle(color: Colors.grey.shade500, fontSize: 11);
          }),
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF5F7FF),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFDDE2F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFDDE2F0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kBrandColor, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.red),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.red, width: 2),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            backgroundColor: kBrandColor,
            foregroundColor: Colors.white,
            padding:
                const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding:
                const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding:
                const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            side: const BorderSide(color: kBrandColor),
            foregroundColor: kBrandColor,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6FB),
        dividerTheme:
            const DividerThemeData(space: 1, thickness: 1, color: Color(0xFFEEF0F6)),
      ),
      home: const SessionInterceptorGate(),
    );
  }
}

class SessionInterceptorGate extends StatefulWidget {
  const SessionInterceptorGate({super.key});

  @override
  State<SessionInterceptorGate> createState() => _SessionInterceptorGateState();
}

class _SessionInterceptorGateState extends State<SessionInterceptorGate> {
  bool _isLoading = true;
  String? _cachedRole;

  @override
  void initState() {
    super.initState();
    _checkActiveSession();
  }

  Future<void> _checkActiveSession() async {
    const secureStorage = FlutterSecureStorage();
    try {
      final storedUuid = await secureStorage.read(key: 'ACTIVE_USER_UUID');
      final storedRole = await secureStorage.read(key: 'ACTIVE_USER_ROLE');

      if (storedUuid != null && storedUuid.isNotEmpty) {
        final resolvedRole = normalizePersistedRole(storedRole);
        if (resolvedRole == 'presenter') {
          if (mounted) setState(() => _cachedRole = 'presenter');
        } else if (resolvedRole == 'audience') {
          final user = await AsuraRepository.getUserById(storedUuid);
          final dbRole = normalizePersistedRole(user?['role'] as String?);
          if (dbRole == 'presenter') {
            if (mounted) setState(() => _cachedRole = 'presenter');
          } else {
            if (mounted) setState(() => _cachedRole = 'audience');
          }
        }
      }
    } catch (_) {
      // Handle storage read failures gracefully
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: kBrandColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cast_for_education, size: 64, color: Colors.white),
              SizedBox(height: 24),
              CircularProgressIndicator(color: Colors.white),
            ],
          ),
        ),
      );
    }

    // THE FIX: Wrap the user in the MainAppShell instead of the raw isolated views
    if (_cachedRole == 'presenter') {
      return const MainAppShell(userRole: UserRole.presenter);
    } else if (_cachedRole == 'audience') {
      return const MainAppShell(userRole: UserRole.audience);
    }

    // Otherwise, show the role selection landing pad view
    return const RoleSelectionView();
  }
}

/// The entry screen where the user selects their workspace role
class RoleSelectionView extends StatelessWidget {
  const RoleSelectionView({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Background gradient
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1E3A8A), Color(0xFF2563EB), Color(0xFF0EA5E9)],
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
            ),
            // Content
            SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 40),
                    // Logo + title
                    const Icon(Icons.cast_for_education,
                        size: 72, color: Colors.white),
                    const SizedBox(height: 20),
                    const Text(
                      'AsuraTECH',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: -1,
                      ),
                    ),
                    const Text(
                      'LAN Classroom',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w300,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Real-time classroom collaboration\nover local and online networks.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.white60,
                          height: 1.5),
                    ),
                    const SizedBox(height: 56),

                    // Role cards
                    _RoleCard(
                      icon: Icons.co_present,
                      title: 'Instructor',
                      subtitle: 'Create rooms, present materials,\nrun quizzes, and manage students.',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              const SignupView(chosenRole: UserRole.presenter),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _RoleCard(
                      icon: Icons.school,
                      title: 'Student',
                      subtitle: 'Join classrooms, view materials,\nand participate in live sessions.',
                      outlined: true,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              const SignupView(chosenRole: UserRole.audience),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Divider
                    Row(children: [
                      Expanded(
                          child: Divider(color: Colors.white.withValues(alpha: 0.3))),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Text('Already registered?',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 12)),
                      ),
                      Expanded(
                          child: Divider(color: Colors.white.withValues(alpha: 0.3))),
                    ]),
                    const SizedBox(height: 16),

                    // Sign in button
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.6)),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.login),
                      label: const Text('Sign In to Existing Account'),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const LoginView()),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool outlined;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    if (outlined) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.7)),
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onPressed: onTap,
        child: Row(children: [
          Icon(icon, size: 28),
          const SizedBox(width: 16),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ]),
        ]),
      );
    }
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
        backgroundColor: Colors.white,
        foregroundColor: kBrandColor,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: onTap,
      child: Row(children: [
        Icon(icon, size: 28),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(subtitle,
              style: TextStyle(
                  fontSize: 12, color: kBrandColor.withValues(alpha: 0.7))),
        ]),
      ]),
    );
  }
}