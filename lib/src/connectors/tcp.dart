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
  final String address;

  TcpPrinterInfo({required this.address});
}

class TcpPrinterConnector implements PrinterConnector<TcpPrinterInput> {
  TcpPrinterConnector._();

  static final TcpPrinterConnector _instance = TcpPrinterConnector._();
  static TcpPrinterConnector get instance => _instance;

  Socket? _socket;
  TCPStatus status = TCPStatus.none;

  final _statusStreamController = StreamController<TCPStatus>.broadcast();
  Stream<TCPStatus> get currentStatus => _statusStreamController.stream;

  static Future<List<PrinterDiscovered<TcpPrinterInfo>>> discoverPrinters({
    String? ipAddress,
    int? port,
    Duration? timeOut,
  }) async {
    final List<PrinterDiscovered<TcpPrinterInfo>> result = [];
    final defaultPort = port ?? 9100;

    String? deviceIp = await _getDeviceIp(ipAddress);
    if (deviceIp == null) return result;

    final String subnet = _getSubnet(deviceIp);
    final stream =
        NetworkAnalyzer.discover2(subnet, defaultPort, timeout: timeOut ?? const Duration(milliseconds: 4000));

    await for (var addr in stream) {
      if (addr.exists) {
        result.add(PrinterDiscovered<TcpPrinterInfo>(
          name: "${addr.ip}:$defaultPort",
          detail: TcpPrinterInfo(address: addr.ip),
        ));
      }
    }

    return result;
  }

  static Future<String?> _getDeviceIp(String? ipAddress) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return await NetworkInfo().getWifiIP();
    }
    return ipAddress;
  }

  static String _getSubnet(String deviceIp) => deviceIp.substring(0, deviceIp.lastIndexOf('.'));

  Stream<PrinterDevice> discovery({TcpPrinterInput? model}) async* {
    final defaultPort = model?.port ?? 9100;

    String? deviceIp = await _getDeviceIp(model?.ipAddress);
    if (deviceIp == null) return;

    final String subnet = _getSubnet(deviceIp);
    final stream = NetworkAnalyzer.discover2(subnet, defaultPort);

    await for (var data in stream) {
      if (data.exists) {
        yield PrinterDevice(name: "${data.ip}:$defaultPort", address: data.ip);
      }
    }
  }

  @override
  Future<bool> send(List<int> bytes) async {
    try {
      if (status != TCPStatus.connected) return false;

      _socket?.add(Uint8List.fromList(bytes));
      return true;
    } catch (e) {
      _handleSocketError();
      return false;
    }
  }

  @override
  Future<bool> connect(TcpPrinterInput model) async {
    if (status != TCPStatus.none) return false;

    try {
      _socket = await Socket.connect(model.ipAddress, model.port, timeout: model.timeout);
      _updateStatus(TCPStatus.connected);

      final ping = Ping(model.ipAddress, interval: 3, timeout: 7);
      ping.stream.listen(_handlePingResponse);
      _listenSocket(ping);

      return true;
    } catch (e) {
      _handleSocketError();
      return false;
    }
  }

  @override
  Future<bool> disconnect({int? delayMs}) async {
    try {
      _socket?.destroy();
      if (delayMs != null) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }
      _updateStatus(TCPStatus.none);
      return true;
    } catch (e) {
      _handleSocketError();
      return false;
    }
  }

  void _updateStatus(TCPStatus newStatus) {
    status = newStatus;
    _statusStreamController.add(status);
  }

  void _handlePingResponse(PingData data) {
    if (data.error != null) {
      _handleSocketError();
    }
  }

  void _handleSocketError() {
    _socket?.destroy();
    _updateStatus(TCPStatus.none);
  }

  void _listenSocket(Ping ping) {
    _socket?.listen(
      (dynamic message) => debugPrint('Received: $message'),
      onDone: () {
        _handleSocketClose(ping);
      },
      onError: (error) {
        debugPrint('Socket error: $error');
        _handleSocketClose(ping);
      },
    );
  }

  void _handleSocketClose(Ping ping) {
    _socket?.destroy();
    ping.stop();
    _updateStatus(TCPStatus.none);
    debugPrint('Socket closed');
  }
}
