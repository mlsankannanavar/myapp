// This is a basic test file for the BatchMate app.
// You can add more specific tests for your app here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batchmate_app/main.dart';

void main() {
  testWidgets('BatchMate app smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const BatchMateApp());

    // Verify that the app starts without crashing
    expect(find.text('BatchMate'), findsOneWidget);
  });

  testWidgets('App should have MaterialApp', (WidgetTester tester) async {
    await tester.pumpWidget(const BatchMateApp());
    
    // Verify that MaterialApp is present
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
