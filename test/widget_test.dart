// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asuratech_lan_classroom/features/ai/ai_assistant_view.dart';
import 'package:asuratech_lan_classroom/features/settings/ai_settings_view.dart';

void main() {
  testWidgets('Students see the teacher-only guidance and no edit controls', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiSettingsView(isTeacher: false)));

    expect(find.text('Teachers can configure shared AI settings. Students can use their own API key for personal AI access.'), findsOneWidget);
    expect(find.text('Shared AI Helper key (teacher-only)'), findsNothing);
    expect(find.text('Save Settings'), findsNothing);
  });

  testWidgets('Teachers can see the teacher-only controls', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiSettingsView(isTeacher: true)));

    expect(find.text('Shared AI Helper key (teacher-only)'), findsOneWidget);
    expect(find.text('Save Settings'), findsOneWidget);
  });

  testWidgets('AI Helper shows its chat composer and welcome message', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiAssistantView()));

    expect(find.text('AI Helper'), findsOneWidget);
    expect(find.text('Ask about the topic or materials in your joined rooms'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });
}
