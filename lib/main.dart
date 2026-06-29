import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const VeloSpeederApp());
}

/// App-specific constants derived from your ESP32 sketch.
class VeloProtocol {
  static const String defaultTargetName = 'kTwin';

  static const String defaultPin = '0913';
  static const int defaultLowSpeed = 17;
  static const int defaultHighSpeed = 25;

  static const int minSpeed = 10;
  static const int maxRoadSpeed = 25;

  static List<int> customerModeCommand(String pin) {
    return utf8.encode('pin=$pin\n');
  }

  static List<int> setSpeedCommand(int kmh) {
    return utf8.encode('setsp=$kmh\n');
  }
}

class VeloSpeederApp extends StatelessWidget {
  const VeloSpeederApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Velo Speeder Switch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0A0A0B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF06B6D4),
          surface: Color(0xFF161618),
          onSurface: Color(0xFFE4E4E7),
          outline: Color(0xFF27272A),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF161618),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF27272A)),
          ),
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: Color(0xFF06B6D4)),
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF06B6D4),
            foregroundColor: const Color(0xFF0A0A0B),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF06B6D4),
            side: const BorderSide(color: Color(0xFF27272A)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: Color(0xFF06B6D4),
          inactiveTrackColor: Color(0xFF27272A),
          thumbColor: Color(0xFF06B6D4),
          overlayColor: Color(0x3306B6D4),
        ),
        useMaterial3: true,
      ),
      home: const VeloHomePage(),
    );
  }
}

enum VeloConnectionPhase {
  idle,
  checkingPermissions,
  scanning,
  connecting,
  discovering,
  ready,
  failed,
}

class BleTargets {
  BleTargets({
    required this.service,
    required this.writeChar,
    this.readChar,
    this.notifyChar,
  });

  final BluetoothService service;
  final BluetoothCharacteristic writeChar;
  final BluetoothCharacteristic? readChar;
  final BluetoothCharacteristic? notifyChar;
}

class VeloHomePage extends StatefulWidget {
  const VeloHomePage({super.key});

  @override
  State<VeloHomePage> createState() => _VeloHomePageState();
}

class _VeloHomePageState extends State<VeloHomePage> {
  final TextEditingController _targetNameController =
      TextEditingController(text: VeloProtocol.defaultTargetName);
  final TextEditingController _pinController =
      TextEditingController(text: VeloProtocol.defaultPin);

  final FocusNode _remoteFocusNode = FocusNode(debugLabel: 'remote-control');

  int _lowSpeed = VeloProtocol.defaultLowSpeed;
  int _highSpeed = VeloProtocol.defaultHighSpeed;
  bool _remoteControlEnabled = true;
  bool _remoteCurrentlyHigh = false;
  DateTime _lastRemoteCommandAt = DateTime.fromMillisecondsSinceEpoch(0);

  VeloConnectionPhase _phase = VeloConnectionPhase.idle;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  BluetoothDevice? _device;
  BleTargets? _targets;

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<List<int>>? _notifySub;

  final List<String> _log = <String>[];

  bool get _busy =>
      _phase == VeloConnectionPhase.checkingPermissions ||
      _phase == VeloConnectionPhase.scanning ||
      _phase == VeloConnectionPhase.connecting ||
      _phase == VeloConnectionPhase.discovering;

  bool get _ready => _phase == VeloConnectionPhase.ready && _targets != null;

  @override
  void initState() {
    super.initState();

    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      setState(() => _adapterState = state);
      _appendLog('Bluetooth adapter: ${state.name}');
    });

    // Request focus after the first frame so paired Bluetooth HID remotes
    // can control the app while it is open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _remoteFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _targetNameController.dispose();
    _pinController.dispose();
    _remoteFocusNode.dispose();

    _adapterSub?.cancel();
    _scanSub?.cancel();
    _connectionSub?.cancel();
    _notifySub?.cancel();

    _device?.disconnect();

    super.dispose();
  }

  KeyEventResult _handleRemoteKeyEvent(FocusNode node, KeyEvent event) {
    if (!_remoteControlEnabled) {
      return KeyEventResult.ignored;
    }

    // Only act on key-down events. This avoids duplicate actions on key-up.
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    // Prevent repeated BLE writes when a remote button is held down or when
    // the OS emits repeat key events.
    final now = DateTime.now();
    if (now.difference(_lastRemoteCommandAt).inMilliseconds < 350) {
      return KeyEventResult.handled;
    }
    _lastRemoteCommandAt = now;

    if (!_ready) {
      _appendLog('REMOTE ignored: bike controller not connected.');
      return KeyEventResult.handled;
    }

    // Many cheap Bluetooth remotes identify as HID keyboards or media remotes.
    // Depending on the exact remote and OS, the same physical button may arrive
    // as mediaPlayPause, select, enter, space, arrowRight, audioVolumeUp, etc.
    if (_isToggleKey(key)) {
      _remoteCurrentlyHigh = !_remoteCurrentlyHigh;
      _appendLog(
        'REMOTE toggle -> ${_remoteCurrentlyHigh ? _highSpeed : _lowSpeed} km/h',
      );
      if (_remoteCurrentlyHigh) {
        unawaited(_sendHighSpeed());
      } else {
        unawaited(_sendLowSpeed());
      }
      return KeyEventResult.handled;
    }

    if (_isHighSpeedKey(key)) {
      _remoteCurrentlyHigh = true;
      _appendLog('REMOTE high -> $_highSpeed km/h');
      unawaited(_sendHighSpeed());
      return KeyEventResult.handled;
    }

    if (_isLowSpeedKey(key)) {
      _remoteCurrentlyHigh = false;
      _appendLog('REMOTE low -> $_lowSpeed km/h');
      unawaited(_sendLowSpeed());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      _appendLog('REMOTE customer mode PIN');
      unawaited(_sendCustomerMode());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      _remoteCurrentlyHigh = false;
      _appendLog('REMOTE PIN + low speed');
      unawaited(_sendCustomerThenLow());
      return KeyEventResult.handled;
    }

    _appendLog('REMOTE unmapped key: ${key.keyLabel} / ${key.debugName}');
    return KeyEventResult.handled;
  }

  bool _isToggleKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.numpadEnter;
  }

  bool _isHighSpeedKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.audioVolumeUp ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.gameButtonRight1;
  }

  bool _isLowSpeedKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.mediaTrackPrevious ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.audioVolumeDown ||
        key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.gameButtonLeft1;
  }

  Future<void> _connectFlow() async {
    final targetName = _targetNameController.text.trim();

    if (targetName.isEmpty) {
      _showSnack('Target name must not be empty.');
      return;
    }

    try {
      setState(() => _phase = VeloConnectionPhase.checkingPermissions);
      await _requestBlePermissions();

      if (_adapterState != BluetoothAdapterState.on) {
        _appendLog('Bluetooth is not on. Current state: ${_adapterState.name}');
        _showSnack('Please enable Bluetooth first.');
        setState(() => _phase = VeloConnectionPhase.idle);
        return;
      }

      await _disconnectCurrent();

      setState(() => _phase = VeloConnectionPhase.scanning);
      _appendLog('Scanning for "$targetName"...');

      final foundDevice = await _scanForDeviceByName(targetName);

      if (foundDevice == null) {
        _appendLog('Device "$targetName" not found.');
        setState(() => _phase = VeloConnectionPhase.failed);
        return;
      }

      _device = foundDevice;
      _appendLog('Found ${foundDevice.platformName} / ${foundDevice.remoteId}');

      setState(() => _phase = VeloConnectionPhase.connecting);

      _connectionSub = foundDevice.connectionState.listen((state) {
        _appendLog('Connection state: ${state.name}');
        if (!mounted) return;

        if (state == BluetoothConnectionState.disconnected &&
            _phase == VeloConnectionPhase.ready) {
          setState(() {
            _phase = VeloConnectionPhase.idle;
            _targets = null;
          });
        }
      });

      _appendLog('Connecting...');
      await foundDevice.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      // Optional on Android, harmlessly ignored where unsupported.
      try {
        final mtu = await foundDevice.requestMtu(185);
        _appendLog('MTU requested. Result: $mtu');
      } catch (e) {
        _appendLog('MTU request skipped/failed: $e');
      }

      setState(() => _phase = VeloConnectionPhase.discovering);
      _appendLog('Discovering services...');

      _targets = await _discoverLikeEsp32Sketch(foundDevice);

      if (_targets == null) {
        _appendLog('Discovery failed: could not find usable service/characteristics.');
        setState(() => _phase = VeloConnectionPhase.failed);
        return;
      }

      await _enableNotificationsIfAvailable(_targets!);

      setState(() => _phase = VeloConnectionPhase.ready);

      _appendLog('Ready.');
      _appendLog('Service: ${_targets!.service.uuid}');
      _appendLog('Write characteristic: ${_targets!.writeChar.uuid}');
      if (_targets!.readChar != null) {
        _appendLog('Read characteristic: ${_targets!.readChar!.uuid}');
      }
      if (_targets!.notifyChar != null) {
        _appendLog('Notify characteristic: ${_targets!.notifyChar!.uuid}');
      }
    } catch (e, st) {
      _appendLog('ERROR: $e');
      _appendLog(st.toString().split('\n').take(3).join('\n'));
      if (mounted) {
        setState(() => _phase = VeloConnectionPhase.failed);
      }
    }
  }

  Future<void> _requestBlePermissions() async {
    if (Platform.isAndroid) {
      final statuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,

        // Required on Android <= 11 for BLE scanning. On Android 12+ the
        // BLUETOOTH_SCAN permission above is the important one.
        Permission.locationWhenInUse,
      ].request();

      final denied = statuses.entries
          .where((entry) => entry.value.isDenied || entry.value.isPermanentlyDenied)
          .map((entry) => entry.key.toString())
          .toList();

      if (denied.isNotEmpty) {
        throw Exception('Bluetooth permissions denied: ${denied.join(', ')}');
      }
    } else if (Platform.isIOS) {
      // iOS shows Bluetooth permission prompts based on Info.plist usage strings.
      // No explicit permission_handler request is usually needed here.
      _appendLog('iOS Bluetooth permission handled by system prompt if needed.');
    }
  }

  Future<BluetoothDevice?> _scanForDeviceByName(String targetName) async {
    BluetoothDevice? found;

    await _scanSub?.cancel();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final name = result.device.platformName;
        final advertisedName = result.advertisementData.advName;

        if (name == targetName || advertisedName == targetName) {
          found = result.device;
          _appendLog(
            'Match: name="$name", adv="$advertisedName", RSSI=${result.rssi}',
          );
          FlutterBluePlus.stopScan();
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 10),
    );

    // Wait until scanning actually stops because of timeout or because we stopped it.
    await FlutterBluePlus.isScanning
        .where((isScanning) => isScanning == false)
        .first
        .timeout(const Duration(seconds: 12), onTimeout: () => false);

    await _scanSub?.cancel();
    _scanSub = null;

    return found;
  }

  Future<BleTargets?> _discoverLikeEsp32Sketch(BluetoothDevice device) async {
    final services = await device.discoverServices();

    for (var i = 0; i < services.length; i++) {
      _appendLog('Service [${i + 1}]: ${services[i].uuid}');
    }

    if (services.length < 3) {
      _appendLog('Expected at least 3 services, got ${services.length}.');
      return null;
    }

    final targetService = services[2];
    BluetoothCharacteristic? readChar;
    BluetoothCharacteristic? writeChar;
    BluetoothCharacteristic? notifyChar;

    for (final ch in targetService.characteristics) {
      final props = ch.properties;

      _appendLog(
        'Char: ${ch.uuid} '
        '[${props.read ? 'R' : ''}'
        '${props.write ? 'W' : ''}'
        '${props.writeWithoutResponse ? 'w' : ''}'
        '${props.notify ? 'N' : ''}'
        '${props.indicate ? 'I' : ''}]',
      );

      if (readChar == null && props.read) {
        readChar = ch;
      }

      if (writeChar == null && (props.write || props.writeWithoutResponse)) {
        writeChar = ch;
      }

      if (notifyChar == null && (props.notify || props.indicate)) {
        notifyChar = ch;
      }
    }

    if (writeChar == null) {
      _appendLog('No writable characteristic found in 3rd service.');
      return null;
    }

    return BleTargets(
      service: targetService,
      writeChar: writeChar,
      readChar: readChar,
      notifyChar: notifyChar,
    );
  }

  Future<void> _enableNotificationsIfAvailable(BleTargets targets) async {
    final notifyChar = targets.notifyChar;
    if (notifyChar == null) {
      _appendLog('No notify/indicate characteristic found.');
      return;
    }

    await _notifySub?.cancel();

    _notifySub = notifyChar.lastValueStream.listen((value) {
      if (value.isEmpty) return;
      final text = _decodeBytes(value);
      _appendLog('NOTIFY << $text');
    });

    await notifyChar.setNotifyValue(true);
    _appendLog('Notifications enabled.');
  }

  Future<void> _sendCustomerMode() async {
    await _sendCommand(
      label: 'Customer mode',
      bytes: VeloProtocol.customerModeCommand(_pinController.text.trim()),
    );
  }

  Future<void> _sendLowSpeed() async {
    await _sendSpeed(_lowSpeed);
  }

  Future<void> _sendHighSpeed() async {
    await _sendSpeed(_highSpeed);
  }

  Future<void> _sendSpeed(int kmh) async {
    final safeKmh = kmh.clamp(VeloProtocol.minSpeed, VeloProtocol.maxRoadSpeed);
    await _sendCommand(
      label: 'Set speed $safeKmh km/h',
      bytes: VeloProtocol.setSpeedCommand(safeKmh),
    );
  }

  Future<void> _sendCustomerThenLow() async {
    await _sendCustomerMode();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _sendLowSpeed();
  }

  Future<void> _sendCustomerThenHigh() async {
    await _sendCustomerMode();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _sendHighSpeed();
  }

  Future<void> _sendCommand({
    required String label,
    required List<int> bytes,
  }) async {
    final targets = _targets;
    if (!_ready || targets == null) {
      _showSnack('Not connected.');
      return;
    }

    final commandText = _decodeBytes(bytes).replaceAll('\n', r'\n');

    try {
      _appendLog('SEND >> $label: "$commandText"');

      final props = targets.writeChar.properties;
      final withoutResponse = !props.write && props.writeWithoutResponse;

      await targets.writeChar.write(
        bytes,
        withoutResponse: withoutResponse,
      );

      // Match the ESP32 sketch: after writing, wait briefly and try reading.
      if (targets.readChar != null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));

        try {
          final response = await targets.readChar!.read();
          if (response.isEmpty) {
            _appendLog('READ << empty');
          } else {
            _appendLog('READ << ${_decodeBytes(response)}');
          }
        } catch (e) {
          _appendLog('READ failed: $e');
        }
      }
    } catch (e) {
      _appendLog('SEND failed: $e');
      _showSnack('Send failed: $e');
    }
  }

  Future<void> _disconnectCurrent() async {
    await _notifySub?.cancel();
    _notifySub = null;

    await _connectionSub?.cancel();
    _connectionSub = null;

    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    final current = _device;
    if (current != null) {
      try {
        await current.disconnect();
      } catch (_) {}
    }

    _device = null;
    _targets = null;
  }

  Future<void> _disconnectButton() async {
    await _disconnectCurrent();
    if (!mounted) return;
    setState(() => _phase = VeloConnectionPhase.idle);
    _appendLog('Disconnected.');
  }

  String _decodeBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true).trimRight();
    } catch (_) {
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    }
  }

  void _appendLog(String message) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    if (!mounted) return;

    setState(() {
      _log.insert(0, '[$ts] $message');
      if (_log.length > 300) {
        _log.removeRange(300, _log.length);
      }
    });
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  String get _phaseText {
    switch (_phase) {
      case VeloConnectionPhase.idle:
        return 'Idle';
      case VeloConnectionPhase.checkingPermissions:
        return 'Checking permissions';
      case VeloConnectionPhase.scanning:
        return 'Scanning';
      case VeloConnectionPhase.connecting:
        return 'Connecting';
      case VeloConnectionPhase.discovering:
        return 'Discovering services';
      case VeloConnectionPhase.ready:
        return 'Ready';
      case VeloConnectionPhase.failed:
        return 'Failed';
    }
  }

  Color get _phaseColor {
    switch (_phase) {
      case VeloConnectionPhase.ready:
        return Colors.green;
      case VeloConnectionPhase.failed:
        return Colors.redAccent;
      case VeloConnectionPhase.scanning:
      case VeloConnectionPhase.connecting:
      case VeloConnectionPhase.discovering:
      case VeloConnectionPhase.checkingPermissions:
        return Colors.orangeAccent;
      case VeloConnectionPhase.idle:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;

    return Focus(
      focusNode: _remoteFocusNode,
      autofocus: true,
      onKeyEvent: _handleRemoteKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _remoteFocusNode.requestFocus(),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Velo Speeder Switch'),
            actions: [
              IconButton(
                tooltip: 'Refocus remote control',
                onPressed: () {
                  _remoteFocusNode.requestFocus();
                  _appendLog('Remote control focus requested.');
                },
                icon: const Icon(Icons.keyboard),
              ),
              IconButton(
                tooltip: 'Clear log',
                onPressed: () => setState(_log.clear),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatusCard(
                  phaseText: _phaseText,
                  phaseColor: _phaseColor,
                  adapterState: _adapterState.name,
                  deviceName: device?.platformName,
                  deviceId: device?.remoteId.toString(),
                ),
                const SizedBox(height: 12),
                _SettingsCard(
                  enabled: !_busy,
                  targetNameController: _targetNameController,
                  pinController: _pinController,
                  lowSpeed: _lowSpeed,
                  highSpeed: _highSpeed,
                  onLowSpeedChanged: (v) => setState(() => _lowSpeed = v),
                  onHighSpeedChanged: (v) => setState(() => _highSpeed = v),
                ),
                const SizedBox(height: 12),
                _ConnectionCard(
                  busy: _busy,
                  ready: _ready,
                  onConnect: _connectFlow,
                  onDisconnect: _disconnectButton,
                ),
                const SizedBox(height: 12),
                _RemoteControlCard(
                  enabled: _remoteControlEnabled,
                  hasFocus: _remoteFocusNode.hasFocus,
                  currentlyHigh: _remoteCurrentlyHigh,
                  lowSpeed: _lowSpeed,
                  highSpeed: _highSpeed,
                  onEnabledChanged: (value) {
                    setState(() => _remoteControlEnabled = value);
                    if (value) {
                      _remoteFocusNode.requestFocus();
                    }
                  },
                  onRequestFocus: () {
                    _remoteFocusNode.requestFocus();
                    _appendLog('Remote control focus requested.');
                  },
                ),
                const SizedBox(height: 12),
                _ControlCard(
                  ready: _ready,
                  lowSpeed: _lowSpeed,
                  highSpeed: _highSpeed,
                  onCustomerMode: _sendCustomerMode,
                  onLow: _sendLowSpeed,
                  onHigh: _sendHighSpeed,
                  onCustomerLow: _sendCustomerThenLow,
                  onCustomerHigh: _sendCustomerThenHigh,
                ),
                const SizedBox(height: 12),
                _LogCard(log: _log),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.phaseText,
    required this.phaseColor,
    required this.adapterState,
    required this.deviceName,
    required this.deviceId,
  });

  final String phaseText;
  final Color phaseColor;
  final String adapterState;
  final String? deviceName;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, color: phaseColor, size: 14),
                const SizedBox(width: 8),
                Text(
                  phaseText,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Bluetooth: $adapterState'),
            if (deviceName != null && deviceName!.isNotEmpty)
              Text('Device: $deviceName'),
            if (deviceId != null) Text('ID: $deviceId'),
          ],
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.enabled,
    required this.targetNameController,
    required this.pinController,
    required this.lowSpeed,
    required this.highSpeed,
    required this.onLowSpeedChanged,
    required this.onHighSpeedChanged,
  });

  final bool enabled;
  final TextEditingController targetNameController;
  final TextEditingController pinController;
  final int lowSpeed;
  final int highSpeed;
  final ValueChanged<int> onLowSpeedChanged;
  final ValueChanged<int> onHighSpeedChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: AbsorbPointer(
        absorbing: !enabled,
        child: Opacity(
          opacity: enabled ? 1 : 0.6,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Settings', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: targetNameController,
                  decoration: const InputDecoration(
                    labelText: 'BLE device name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pinController,
                  decoration: const InputDecoration(
                    labelText: 'Customer PIN',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  obscureText: true,
                ),
                const SizedBox(height: 16),
                _SpeedSlider(
                  label: 'Low speed',
                  value: lowSpeed,
                  onChanged: onLowSpeedChanged,
                ),
                _SpeedSlider(
                  label: 'High speed',
                  value: highSpeed,
                  onChanged: onHighSpeedChanged,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeedSlider extends StatelessWidget {
  const _SpeedSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: $value km/h'),
        Slider(
          min: VeloProtocol.minSpeed.toDouble(),
          max: VeloProtocol.maxRoadSpeed.toDouble(),
          divisions: VeloProtocol.maxRoadSpeed - VeloProtocol.minSpeed,
          value: value.toDouble(),
          label: '$value km/h',
          onChanged: (v) => onChanged(v.round()),
        ),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.busy,
    required this.ready,
    required this.onConnect,
    required this.onDisconnect,
  });

  final bool busy;
  final bool ready;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : onConnect,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(busy ? 'Working...' : 'Scan & Connect'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: ready || busy ? onDisconnect : null,
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Disconnect'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteControlCard extends StatelessWidget {
  const _RemoteControlCard({
    required this.enabled,
    required this.hasFocus,
    required this.currentlyHigh,
    required this.lowSpeed,
    required this.highSpeed,
    required this.onEnabledChanged,
    required this.onRequestFocus,
  });

  final bool enabled;
  final bool hasFocus;
  final bool currentlyHigh;
  final int lowSpeed;
  final int highSpeed;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onRequestFocus;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Remote Control',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Switch(
                  value: enabled,
                  onChanged: onEnabledChanged,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  hasFocus ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 16,
                  color: hasFocus ? Colors.greenAccent : Colors.orangeAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasFocus
                        ? 'Ready for paired Bluetooth remote key presses.'
                        : 'Tap refocus if the remote does not react.',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Remote state: ${currentlyHigh ? highSpeed : lowSpeed} km/h',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _RemoteChip(label: 'Play / OK', action: 'toggle'),
                _RemoteChip(label: 'Next / → / Vol+', action: '$highSpeed km/h'),
                _RemoteChip(label: 'Prev / ← / Vol-', action: '$lowSpeed km/h'),
                const _RemoteChip(label: '↑', action: 'PIN'),
                _RemoteChip(label: '↓', action: 'PIN + $lowSpeed'),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRequestFocus,
              icon: const Icon(Icons.keyboard),
              label: const Text('Refocus remote listener'),
            ),
            const SizedBox(height: 8),
            Text(
              'Pair the remote in the phone Bluetooth settings first. '
              'Most phone/music/camera remotes behave like a tiny keyboard or '
              'media controller. The app logs unmapped keys so you can adjust '
              'the mapping if your remote sends different key codes.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteChip extends StatelessWidget {
  const _RemoteChip({
    required this.label,
    required this.action,
  });

  final String label;
  final String action;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text('$label → $action'),
    );
  }
}

class _ControlCard extends StatelessWidget {
  const _ControlCard({
    required this.ready,
    required this.lowSpeed,
    required this.highSpeed,
    required this.onCustomerMode,
    required this.onLow,
    required this.onHigh,
    required this.onCustomerLow,
    required this.onCustomerHigh,
  });

  final bool ready;
  final int lowSpeed;
  final int highSpeed;
  final VoidCallback onCustomerMode;
  final VoidCallback onLow;
  final VoidCallback onHigh;
  final VoidCallback onCustomerLow;
  final VoidCallback onCustomerHigh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: AbsorbPointer(
        absorbing: !ready,
        child: Opacity(
          opacity: ready ? 1 : 0.45,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Controls', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onCustomerMode,
                  icon: const Icon(Icons.lock_open),
                  label: const Text('Send customer mode PIN'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: onLow,
                        icon: const Icon(Icons.speed),
                        label: Text('Low: $lowSpeed'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: onHigh,
                        icon: const Icon(Icons.bolt),
                        label: Text('High: $highSpeed'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onCustomerLow,
                        child: Text('PIN + $lowSpeed'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onCustomerHigh,
                        child: Text('PIN + $highSpeed'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.log});

  final List<String> log;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 220),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: DefaultTextStyle(
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Log',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (log.isEmpty)
                  const Text('No log entries yet.')
                else
                  ...log.map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(line),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
