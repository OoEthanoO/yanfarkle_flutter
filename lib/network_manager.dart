import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'models.dart';

enum NetworkMode { none, lan }

class NetworkManager extends ChangeNotifier {
  static final NetworkManager shared = NetworkManager._internal();

  NetworkManager._internal();

  NetworkMode networkMode = NetworkMode.none;
  bool isHosting = false;
  bool isConnected = false;
  bool isConnecting = false;
  String? connectionError;
  String? hostIPAddress;

  ServerSocket? _serverSocket;
  Socket? _socket;
  
  Function(GameStatePacket)? onStateReceived;
  Function(GameAction, int)? onActionReceived;
  Function(String)? onChatReceived;
  Function()? onDisconnected;
  Function()? onConnected;

  void stop({bool notify = true}) {
    _serverSocket?.close();
    _serverSocket = null;
    
    _socket?.destroy();
    _socket = null;

    bool wasConnected = isConnected;
    isConnected = false;
    isConnecting = false;
    isHosting = false;
    networkMode = NetworkMode.none;

    if (wasConnected && notify) {
      onDisconnected?.call();
    }
    notifyListeners();
  }

  Future<void> host({int port = 9999}) async {
    stop(notify: false);
    networkMode = NetworkMode.lan;
    isHosting = true;
    isConnecting = true;
    notifyListeners();

    if (kIsWeb) {
      connectionError = "Hosting LAN games is not supported on Web. Please play against a bot.";
      stop();
      return;
    }

    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      if (interfaces.isNotEmpty) {
        String? bestIp;
        for (var interface in interfaces) {
          // Prefer Wi-Fi (en0) or Ethernet interfaces
          if (interface.name.toLowerCase().contains('en') || interface.name.toLowerCase().contains('eth')) {
            for (var addr in interface.addresses) {
              if (addr.type == InternetAddressType.IPv4) {
                bestIp = addr.address;
                break;
              }
            }
          }
          if (bestIp != null) break;
        }
        
        // Fallback to first available IPv4 if no en/eth found
        if (bestIp == null) {
          for (var interface in interfaces) {
            for (var addr in interface.addresses) {
              if (addr.type == InternetAddressType.IPv4) {
                bestIp = addr.address;
                break;
              }
            }
            if (bestIp != null) break;
          }
        }
        
        hostIPAddress = bestIp ?? "127.0.0.1";
      } else {
        hostIPAddress = "127.0.0.1";
      }
    } catch (_) {
      hostIPAddress = "127.0.0.1";
    }

    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      isConnecting = false;
      notifyListeners();

      _serverSocket!.listen((Socket clientSocket) {
        if (_socket != null) {
          clientSocket.destroy();
          return;
        }
        _serverSocket?.close();
        _serverSocket = null;
        _setupConnection(clientSocket);
      }, onError: (error) {
        connectionError = error.toString();
        stop();
      });
    } catch (e) {
      connectionError = e.toString();
      stop();
    }
  }

  Future<void> connect({required String host, int port = 9999}) async {
    stop(notify: false);
    networkMode = NetworkMode.lan;
    isConnecting = true;
    connectionError = null;
    notifyListeners();

    if (kIsWeb) {
      connectionError = "LAN Multiplayer is not supported on Web.";
      stop();
      return;
    }

    try {
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      _setupConnection(socket);
    } catch (e) {
      connectionError = "Connection timed out. Make sure the host is online and you have the correct IP.";
      stop();
    }
  }

  void _setupConnection(Socket socket) {
    _socket = socket;
    isConnected = true;
    isConnecting = false;
    onConnected?.call();
    notifyListeners();

    String buffer = "";
    
    _socket!.listen(
      (List<int> data) {
        buffer += utf8.decode(data);
        int index;
        while ((index = buffer.indexOf('\n')) != -1) {
          String message = buffer.substring(0, index);
          buffer = buffer.substring(index + 1);
          if (message.isNotEmpty) {
            _parseMessage(message);
          }
        }
      },
      onError: (error) {
        connectionError = error.toString();
        stop();
      },
      onDone: () {
        stop();
      },
    );
  }

  void _parseMessage(String message) {
    try {
      final json = jsonDecode(message);
      final type = json['type'] as String?;
      if (type == null) return;

      if (type.contains('StateUpdate')) {
        final state = GameStatePacket.fromJson(json['state']);
        onStateReceived?.call(state);
      } else if (type.contains('Action')) {
        final actionStr = json['gameAction'] as String;
        final action = GameAction.values.firstWhere((e) => e.name == actionStr);
        final value = json['value'] as int? ?? 0;
        onActionReceived?.call(action, value);
      } else if (type.contains('Chat')) {
        final chatMessage = json['message'] as String;
        onChatReceived?.call(chatMessage);
      }
    } catch (e) {
      debugPrint('[NET] Decoding error: $e\nMessage: $message');
    }
  }

  void sendState(GameStatePacket state) {
    final packet = {
      'type': 'aqario.farkle.network.NetworkPacket.StateUpdate',
      'state': state.toJson(),
    };
    _sendData(jsonEncode(packet));
  }

  void sendAction(GameAction action, {int value = 0}) {
    final packet = {
      'type': 'aqario.farkle.network.NetworkPacket.Action',
      'gameAction': action.name,
      'value': value,
    };
    _sendData(jsonEncode(packet));
  }

  void sendChat(String message) {
    final packet = {
      'type': 'aqario.farkle.network.NetworkPacket.Chat',
      'message': message,
    };
    _sendData(jsonEncode(packet));
  }

  void _sendData(String jsonString) {
    if (_socket != null) {
      _socket!.write('$jsonString\n');
    }
  }
}
