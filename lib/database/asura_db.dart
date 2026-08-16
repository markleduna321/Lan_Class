// lib/database/asura_db.dart

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class AsuraDatabase {
  static final AsuraDatabase instance = AsuraDatabase._init();
  static Database? _database;
  AsuraDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('asuratech.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 16,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  Future _createDB(Database db, int version) async {
    // TABLE: Users
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        first_name TEXT NOT NULL,
        last_name TEXT NOT NULL,
        middle_name TEXT,
        email TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        profession TEXT,
        specialties TEXT,
        role TEXT NOT NULL,
        aura_score INTEGER DEFAULT 0,
        nickname TEXT,
        bio TEXT,
        skills TEXT,
        projects TEXT,
        remote_id TEXT,
        is_synced INTEGER DEFAULT 0
      )
    ''');

    // TABLE: Classrooms
    await db.execute('''
      CREATE TABLE classrooms (
        id TEXT PRIMARY KEY,
        name TEXT,
        schedule TEXT,
        student_count INTEGER,
        remote_id TEXT,
        is_published INTEGER DEFAULT 0,
        visibility TEXT DEFAULT 'public'
      )
    ''');

    // TABLE: Courses/Modules (Gamified Progress)
    await db.execute('''
      CREATE TABLE modules (
        id TEXT PRIMARY KEY,
        title TEXT,
        status TEXT,
        badge_name TEXT
      )
    ''');

    // TABLE: Teacher materials per classroom
    await db.execute('''
      CREATE TABLE materials (
        id TEXT PRIMARY KEY,
        classroom_id TEXT NOT NULL,
        original_name TEXT NOT NULL,
        filename TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        file_path TEXT NOT NULL,
        size_bytes INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        remote_id TEXT,
        remote_url TEXT
      )
    ''');

    // TABLE: Materials received/downloaded by student
    await db.execute('''
      CREATE TABLE student_materials (
        id TEXT PRIMARY KEY,
        classroom_ip TEXT NOT NULL,
        original_name TEXT NOT NULL,
        filename TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        local_path TEXT,
        size_bytes INTEGER DEFAULT 0,
        received_at TEXT NOT NULL
      )
    ''');

    // TABLE: Attendance log
    await db.execute('''
      CREATE TABLE attendance (
        id TEXT PRIMARY KEY,
        classroom_id TEXT NOT NULL,
        student_name TEXT NOT NULL,
        student_ip TEXT NOT NULL,
        joined_at TEXT NOT NULL,
        session_date TEXT NOT NULL,
        disconnected_at TEXT
      )
    ''');

    // TABLE: Student's own session log (stored on student device)
    await db.execute('''
      CREATE TABLE student_sessions (
        id TEXT PRIMARY KEY,
        classroom_ip TEXT NOT NULL,
        joined_at TEXT NOT NULL,
        session_date TEXT NOT NULL
      )
    ''');

    // TABLE: Quiz templates (reusable)
    await db.execute('''
      CREATE TABLE quiz_templates (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // TABLE: Questions inside a quiz template
    await db.execute('''
      CREATE TABLE template_questions (
        id TEXT PRIMARY KEY,
        template_id TEXT NOT NULL,
        question_text TEXT NOT NULL,
        question_type TEXT NOT NULL,
        options TEXT,
        correct_answer TEXT,
        hints TEXT,
        order_index INTEGER DEFAULT 0,
        points INTEGER DEFAULT 1
      )
    ''');

    // TABLE: Quizzes assigned to a classroom room
    await db.execute('''
      CREATE TABLE room_quizzes (
        id TEXT PRIMARY KEY,
        classroom_id TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT,
        status TEXT DEFAULT 'draft',
        source_template_id TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // TABLE: Questions inside a room quiz
    await db.execute('''
      CREATE TABLE room_quiz_questions (
        id TEXT PRIMARY KEY,
        quiz_id TEXT NOT NULL,
        question_text TEXT NOT NULL,
        question_type TEXT NOT NULL,
        options TEXT,
        correct_answer TEXT,
        hints TEXT,
        order_index INTEGER DEFAULT 0,
        points INTEGER DEFAULT 1
      )
    ''');

    // TABLE: Student quiz responses (stored on teacher device)
    await db.execute('''
      CREATE TABLE quiz_responses (
        id TEXT PRIMARY KEY,
        quiz_id TEXT NOT NULL,
        question_id TEXT NOT NULL,
        student_name TEXT NOT NULL,
        student_ip TEXT NOT NULL,
        answer TEXT,
        is_correct INTEGER,
        submitted_at TEXT NOT NULL
      )
    ''');
    // TABLE: Student's own quiz attempt results (stored on student device)
    await db.execute('''
      CREATE TABLE student_quiz_results (
        id TEXT PRIMARY KEY,
        host_ip TEXT NOT NULL,
        classroom_id TEXT NOT NULL DEFAULT '',
        quiz_id TEXT NOT NULL,
        quiz_title TEXT NOT NULL,
        score INTEGER NOT NULL DEFAULT 0,
        scorable_total INTEGER NOT NULL DEFAULT 0,
        total_questions INTEGER NOT NULL DEFAULT 0,
        taken_at TEXT NOT NULL,
        answers_json TEXT
      )
    ''');
  }
  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) {
      await db.execute('DROP TABLE IF EXISTS users');
      await db.execute('''
        CREATE TABLE users (
          id TEXT PRIMARY KEY,
          first_name TEXT NOT NULL,
          last_name TEXT NOT NULL,
          middle_name TEXT,
          email TEXT UNIQUE NOT NULL,
          password_hash TEXT NOT NULL,
          profession TEXT,
          specialties TEXT,
          role TEXT NOT NULL,
          aura_score INTEGER DEFAULT 0,
          is_synced INTEGER DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS materials (
          id TEXT PRIMARY KEY,
          classroom_id TEXT NOT NULL,
          original_name TEXT NOT NULL,
          filename TEXT NOT NULL,
          mime_type TEXT NOT NULL,
          file_path TEXT NOT NULL,
          size_bytes INTEGER DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS student_materials (
          id TEXT PRIMARY KEY,
          classroom_ip TEXT NOT NULL,
          original_name TEXT NOT NULL,
          filename TEXT NOT NULL,
          mime_type TEXT NOT NULL,
          local_path TEXT,
          size_bytes INTEGER DEFAULT 0,
          received_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 5) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS attendance (
          id TEXT PRIMARY KEY,
          classroom_id TEXT NOT NULL,
          student_name TEXT NOT NULL,
          student_ip TEXT NOT NULL,
          joined_at TEXT NOT NULL,
          session_date TEXT NOT NULL,
          disconnected_at TEXT
        )
      ''');
    }
    if (oldVersion < 6) {
      // Add disconnect timestamp column to existing attendance tables
      try {
        await db.execute(
            'ALTER TABLE attendance ADD COLUMN disconnected_at TEXT');
      } catch (_) {} // ignore if column already exists
    }
    if (oldVersion < 7) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS student_sessions (
          id TEXT PRIMARY KEY,
          classroom_ip TEXT NOT NULL,
          joined_at TEXT NOT NULL,
          session_date TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS quiz_templates (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          description TEXT,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS template_questions (
          id TEXT PRIMARY KEY,
          template_id TEXT NOT NULL,
          question_text TEXT NOT NULL,
          question_type TEXT NOT NULL,
          options TEXT,
          correct_answer TEXT,
          hints TEXT,
          order_index INTEGER DEFAULT 0,
          points INTEGER DEFAULT 1
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS room_quizzes (
          id TEXT PRIMARY KEY,
          classroom_id TEXT NOT NULL,
          title TEXT NOT NULL,
          description TEXT,
          status TEXT DEFAULT 'draft',
          source_template_id TEXT,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS room_quiz_questions (
          id TEXT PRIMARY KEY,
          quiz_id TEXT NOT NULL,
          question_text TEXT NOT NULL,
          question_type TEXT NOT NULL,
          options TEXT,
          correct_answer TEXT,
          hints TEXT,
          order_index INTEGER DEFAULT 0,
          points INTEGER DEFAULT 1
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS quiz_responses (
          id TEXT PRIMARY KEY,
          quiz_id TEXT NOT NULL,
          question_id TEXT NOT NULL,
          student_name TEXT NOT NULL,
          student_ip TEXT NOT NULL,
          answer TEXT,
          is_correct INTEGER,
          submitted_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 9) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS student_quiz_results (
          id TEXT PRIMARY KEY,
          host_ip TEXT NOT NULL,
          classroom_id TEXT NOT NULL DEFAULT '',
          quiz_id TEXT NOT NULL,
          quiz_title TEXT NOT NULL,
          score INTEGER NOT NULL DEFAULT 0,
          scorable_total INTEGER NOT NULL DEFAULT 0,
          total_questions INTEGER NOT NULL DEFAULT 0,
          taken_at TEXT NOT NULL,
          answers_json TEXT
        )
      ''');
    }
    if (oldVersion < 10) {
      try {
        await db.execute(
            'ALTER TABLE student_quiz_results ADD COLUMN classroom_id TEXT NOT NULL DEFAULT \'\'');
      } catch (_) {} // ignore if column already exists
    }
    if (oldVersion < 11) {
      try {
        await db.execute(
            'ALTER TABLE users ADD COLUMN remote_id TEXT');
      } catch (_) {}
    }
    if (oldVersion < 12) {
      try { await db.execute('ALTER TABLE classrooms ADD COLUMN remote_id TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE classrooms ADD COLUMN is_published INTEGER DEFAULT 0'); } catch (_) {}
      try { await db.execute('ALTER TABLE materials ADD COLUMN remote_id TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE materials ADD COLUMN remote_url TEXT'); } catch (_) {}
    }
    if (oldVersion < 13) {
      // Ensure columns exist on devices that did a fresh install at v12
      // (onCreate at v12 lacked these columns).
      try { await db.execute('ALTER TABLE classrooms ADD COLUMN remote_id TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE classrooms ADD COLUMN is_published INTEGER DEFAULT 0'); } catch (_) {}
      try { await db.execute('ALTER TABLE materials ADD COLUMN remote_id TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE materials ADD COLUMN remote_url TEXT'); } catch (_) {}
    }
    if (oldVersion < 14) {
      // onCreate at v13 still lacked remote_id/remote_url on materials table.
      try { await db.execute('ALTER TABLE classrooms ADD COLUMN remote_id TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE classrooms ADD COLUMN is_published INTEGER DEFAULT 0'); } catch (_) {}
      try { await db.execute('ALTER TABLE materials ADD COLUMN remote_id TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE materials ADD COLUMN remote_url TEXT'); } catch (_) {}
    }
    if (oldVersion < 15) {
      try { await db.execute("ALTER TABLE classrooms ADD COLUMN visibility TEXT DEFAULT 'public'"); } catch (_) {}
    }
    if (oldVersion < 16) {
      // Profile fields: nickname, bio, skills (JSON), projects (JSON).
      // remote_id was added at v11 but include a guard for fresh v<11 installs.
      try { await db.execute('ALTER TABLE users ADD COLUMN nickname TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE users ADD COLUMN bio TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE users ADD COLUMN skills TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE users ADD COLUMN projects TEXT'); } catch (_) {}
    }
  }
}