/// Oraimo Watch 6R companion app — a BLE research laboratory.
///
/// The app's purpose is to observe, record and export evidence about a
/// protocol nobody here has documentation for. It contains no protocol
/// decoder, because none is justified yet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Verbose plugin logging by default: this is a research tool, and a BLE
  // failure nobody can see is a failure nobody can explain (rule 9).
  FlutterBluePlus.setLogLevel(LogLevel.verbose, color: false);

  runApp(const ProviderScope(child: OraimoLabApp()));
}
