/// The app shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation/screens/capture_sessions_screen.dart';
import 'presentation/screens/developer_screen.dart';
import 'presentation/screens/nearby_devices_screen.dart';
import 'presentation/screens/packet_monitor_screen.dart';

class OraimoLabApp extends StatelessWidget {
  const OraimoLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oraimo Lab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00696D)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00696D),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const List<Widget> _screens = [
    NearbyDevicesScreen(),
    PacketMonitorScreen(),
    CaptureSessionsScreen(),
    DeveloperScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching),
            label: 'Devices',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_vert),
            label: 'Monitor',
          ),
          NavigationDestination(
            icon: Icon(Icons.science_outlined),
            label: 'Sessions',
          ),
          NavigationDestination(
            icon: Icon(Icons.build_outlined),
            label: 'Developer',
          ),
        ],
      ),
    );
  }
}
