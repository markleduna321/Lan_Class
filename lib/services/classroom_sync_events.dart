// lib/services/classroom_sync_events.dart
//
// Lets the Classroom Hub refresh when the background login sync finishes.

import 'package:flutter/foundation.dart';

final ValueNotifier<int> classroomSyncCompleted = ValueNotifier<int>(0);

void notifyClassroomSyncCompleted() => classroomSyncCompleted.value++;
