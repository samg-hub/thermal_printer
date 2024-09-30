import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_ping/dart_ping.dart';
import 'package:flutter/material.dart';
import 'package:thermal_printer/src/models/printer_device.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:thermal_printer/discovery.dart';
import 'package:thermal_printer/printer.dart';
import 'package:ping_discover_network_forked/ping_discover_network_forked.dart';

class TcpPrinterInput extends BasePrinterInput {
  final String ipAddress;
  final int port;
  final Duration timeout;
  TcpPrinterInput({
    required this.ipAddress,
    this.port = 9100,
    this.timeout = const Duration(seconds: 5),
  });
}

class TcpPrinterInfo {
  String address;
  TcpPrinterInfo({
    required this.address,
  });
}

class TcpPrinterConnector implements PrinterConnector<TcpPrinterInput> {
  TcpPrinterConnector._();
  static TcpPrinterConnector _instance = TcpPrinterConnector._();

  static TcpPrinterConnector get instance => _instance;

  TcpPrinterConnector();
  Socket? _socket;
  TCPStatus status = TCPStatus.none;

  Stream<TCPStatus> get _statusStream => _statusStreamController.stream;
  final StreamController<TCPStatus> _statusStreamController = StreamController.broadcast();
  final StreamController<PrinterState> _printerStateStreamController = StreamController.broadcast();

  static Future<List<PrinterDiscovered<TcpPrinterInfo>>> discoverPrinters({String? ipAddress, int? port, Duration? timeOut}) async {
    final List<PrinterDiscovered<TcpPrinterInfo>> result = [];
    final defaultPort = port ?? 9100;

    String? deviceIp;
    if (Platform.isAndroid || Platform.isIOS) {
      deviceIp = await NetworkInfo().getWifiIP();
    } else if (ipAddress != null) deviceIp = ipAddress;
    if (deviceIp == null) return result;

    final String subnet = deviceIp.substring(0, deviceIp.lastIndexOf('.'));
    // final List<String> ips = List.generate(255, (index) => '$subnet.$index');

    final stream = NetworkAnalyzer.discover2(
      subnet,
      defaultPort,
      timeout: timeOut ?? Duration(milliseconds: 4000),
    );

    await for (var addr in stream) {
      if (addr.exists) {
        result.add(PrinterDiscovered<TcpPrinterInfo>(name: "${addr.ip}:$defaultPort", detail: TcpPrinterInfo(address: addr.ip)));
      }
    }

    return result;
  }

  /// Starts a scan for network printers.
  Stream<PrinterDevice> discovery({TcpPrinterInput? model}) async* {
    final defaultPort = model?.port ?? 9100;

    String? deviceIp;
    if (Platform.isAndroid || Platform.isIOS) {
      deviceIp = await NetworkInfo().getWifiIP();
    } else if (model?.ipAddress != null) {
      deviceIp = model!.ipAddress;
    } else {
      return;
      // throw Exception('No IP address provided');
    }

    final String subnet = deviceIp!.substring(0, deviceIp.lastIndexOf('.'));
    // final List<String> ips = List.generate(255, (index) => '$subnet.$index');

    final stream = NetworkAnalyzer.discover2(subnet, defaultPort);

    await for (var data in stream.map((message) => message)) {
      if (data.exists) {
        yield PrinterDevice(name: "${data.ip}:$defaultPort", address: data.ip);
      }
    }
  }

  @override
  Future<bool> send(List<int> bytes) async {
    try {
      final isConnected = status == TCPStatus.connected;
      if(!isConnected){
        return false;
      }else{
        _printerStateStreamController.add(PrinterState.printing);
        _socket?.add(Uint8List.fromList(bytes));
        // Now send the status command to check if the printer has finished printing (DLE EOT 1)
        List<int> statusCommand = [16, 4, 1]; // DLE EOT 1 (check printer status)
        _socket?.add(Uint8List.fromList(statusCommand));
         // Wait for the printer to finish printing by listening for the status update
        return await _waitForPrinterFinished();
      }
    } catch (e) {
      _socket?.destroy();
      return false;
    }
  }


  Future<bool> _waitForPrinterFinished() async {
  // Completer to await for the printer state
    final completer = Completer<bool>();

    // Listen to the printer state updates
    final subscription = _printerStateStreamController.stream.listen((state) {
      if (state == PrinterState.finished) {
        completer.complete(true);  // Print finished
      } else if (state == PrinterState.none || state == PrinterState.error) {
        completer.complete(false); // Something went wrong or no response
      }
    });

    // Timeout mechanism in case the printer takes too long
    final timeout = Future.delayed(Duration(seconds: 10), () {
      completer.complete(false);  // Timed out waiting for print completion
    });

    // Wait for either the printer to finish or timeout
    final result = await Future.any([completer.future, timeout]);

    // Clean up the subscription
    await subscription.cancel();

  return result;
}



  @override
  Future<bool> connect(TcpPrinterInput model) async {
    try {
      if (status == TCPStatus.none) {
        _socket = await Socket.connect(model.ipAddress, model.port, timeout: model.timeout);
        status = TCPStatus.connected;
        debugPrint('socket $status'); //if opened you will get it here
        _statusStreamController.add(status);

        // Create ping object with desired args
        final ping = Ping('${model.ipAddress}', interval: 3, timeout: 7);

        // Begin ping process and listen for output
        ping.stream.listen((PingData data) {
          if (data.error != null) {
            debugPrint(' ----- ping error ${data.error}');
            _socket?.destroy();
            status = TCPStatus.none;
            _statusStreamController.add(status);
          }
        });
        listenSocket(ping);
      }
    } catch (e) {
      _socket?.destroy();
      status = TCPStatus.none;
      _statusStreamController.add(status);
    }
    return status == TCPStatus.connected;
  }

  /// [delayMs]: milliseconds to wait after destroying the socket
  @override
  Future<bool> disconnect({int? delayMs}) async {
    try {
      // await _socket?.flush();
      _socket?.destroy();

      if (delayMs != null) {
        await Future.delayed(Duration(milliseconds: delayMs), () => null);
      }
      return true;
    } catch (e) {
      _socket?.destroy();
      status = TCPStatus.none;
      _statusStreamController.add(status);
      return false;
    }
  }

  /// Gets the current state of the TCP module
  Stream<TCPStatus> get currentStatus async* {
    yield* _statusStream.cast<TCPStatus>();
  }

  Stream<PrinterState> get printerState async* {
    yield* _printerStateStreamController.stream.cast<PrinterState>();
  }

  void listenSocket(Ping ping) {
    _socket?.listen(
      (dynamic message) {
        debugPrint('message $message');
        int status = message[0];
        if ((status & 0x08) == 0x08) {
          _printerStateStreamController.add(PrinterState.printing);
        }else{
          _printerStateStreamController.add(PrinterState.finished);
        }
      },
      onDone: () {
        status = TCPStatus.none;
        debugPrint('socket closed'); //if closed you will get it here
        _socket?.destroy();
        _printerStateStreamController.add(PrinterState.stopped);
        ping.stop();
        _statusStreamController.add(status);
      },
      onError: (error) {
        status = TCPStatus.none;
        debugPrint('socket error $error');
        _socket?.destroy();
        ping.stop();
        _printerStateStreamController.add(PrinterState.error);
        _statusStreamController.add(status);
      },
    );
  }
}
