import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:math';
import 'models.dart';
import 'firebase_options.dart';

enum NetworkMode { none, lan, online }

class NetworkManager extends ChangeNotifier {
  static final NetworkManager shared = NetworkManager._internal();

  NetworkManager._internal();

  NetworkMode networkMode = NetworkMode.none;
  bool isHosting = false;
  bool isConnected = false;
  bool isConnecting = false;
  String? connectionError;
  String? hostIPAddress;
  String? roomID;

  DatabaseReference? _roomRef;
  StreamSubscription? _stateSubscription;
  StreamSubscription? _actionSubscription;
  StreamSubscription? _chatSubscription;
  StreamSubscription? _presenceSubscription;
  
  Function(GameStatePacket)? onStateReceived;
  Function(GameAction, int)? onActionReceived;
  Function(String)? onChatReceived;
  Function()? onDisconnected;
  Function()? onGuestLeft;
  Function()? onConnected;
  Function(String)? onRoomCreated;

  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      _initialized = true;
    }
  }

  void stop({bool notify = true}) {
    _stateSubscription?.cancel();
    _actionSubscription?.cancel();
    _chatSubscription?.cancel();
    _presenceSubscription?.cancel();
    
    if (_roomRef != null) {
      if (isHosting) {
        _roomRef!.remove();
      } else if (isConnected) {
        _roomRef!.update({"guestConnected": false}).catchError((_) {});
      }
    }

    _roomRef = null;
    bool wasConnected = isConnected;
    isConnected = false;
    isConnecting = false;
    isHosting = false;
    networkMode = NetworkMode.none;
    roomID = null;

    if (wasConnected && notify) {
      onDisconnected?.call();
    }
    notifyListeners();
  }

  String _generateRoomID() {
    const charset = "abcdefghjklmnpqrstuvwxyz23456789";
    Random random = Random();
    return List.generate(5, (index) => charset[random.nextInt(charset.length)]).join();
  }

  Future<void> hostOnline() async {
    stop(notify: false);
    networkMode = NetworkMode.online;
    isHosting = true;
    isConnecting = true;
    notifyListeners();

    try {
      await _ensureInitialized();
      roomID = _generateRoomID();
      _roomRef = FirebaseDatabase.instance.ref("rooms/$roomID");
      
      await _roomRef!.set({
        "hostConnected": true,
        "guestConnected": false,
        "state": null,
        "lastAction": null,
        "lastChat": null,
      });

      _roomRef!.onDisconnect().remove();
      _setupFirebaseListeners();
      onRoomCreated?.call(roomID!);
      notifyListeners();
      onRoomCreated?.call(roomID!);
      notifyListeners();
    } catch (e) {
      debugPrint("Firebase Host Error: $e");
      connectionError = "Failed to create online room. $e";
      stop();
    }
  }

  Future<void> joinOnline(String id) async {
    stop(notify: false);
    networkMode = NetworkMode.online;
    isHosting = false;
    isConnecting = true;
    roomID = id.toLowerCase();
    notifyListeners();

    try {
      await _ensureInitialized();
      _roomRef = FirebaseDatabase.instance.ref("rooms/$roomID");
      
      final snapshot = await _roomRef!.get();
      if (!snapshot.exists) {
        connectionError = "Room not found.";
        stop();
        return;
      }

      await _roomRef!.update({"guestConnected": true});
      _roomRef!.child("guestConnected").onDisconnect().set(false);

      isConnected = true;
      isConnecting = false;
      onConnected?.call();
      _setupFirebaseListeners();
      notifyListeners();
    } catch (e) {
      debugPrint("Firebase Join Error: $e");
      connectionError = "Failed to join room. $e";
      stop();
    }
  }

  void _setupFirebaseListeners() {
    if (_roomRef == null) return;

    _presenceSubscription?.cancel();
    _presenceSubscription = _roomRef!.onValue.listen((event) {
      if (!event.snapshot.exists) {
        if (isConnected || isConnecting) {
          stop();
        }
        return;
      }

      if (isHosting) {
        final data = event.snapshot.value as Map?;
        if (data != null) {
          bool guestConnected = data["guestConnected"] as bool? ?? false;
          if (guestConnected && !isConnected) {
            isConnected = true;
            isConnecting = false;
            onConnected?.call();
            notifyListeners();
          } else if (!guestConnected && isConnected) {
            isConnected = false;
            isConnecting = true; // Return to waiting state
            onGuestLeft?.call();
            notifyListeners();
          }
        }
      }
    });

    _stateSubscription = _roomRef!.child("state").onValue.listen((event) {
      if (event.snapshot.value != null) {
        final data = jsonDecode(event.snapshot.value as String);
        // Only process if it's not our own update (Firebase doesn't have easy 'fromOther' filtering without tracking)
        // But for simplicity in turn-based games, we can just let it overwrite.
        onStateReceived?.call(GameStatePacket.fromJson(data));
      }
    });

    _actionSubscription = _roomRef!.child("actions").onChildAdded.listen((event) {
      if (event.snapshot.value != null) {
        final data = event.snapshot.value as Map;
        final sender = data["sender"] as String;
        final myRole = isHosting ? "host" : "guest";
        
        if (sender != myRole) {
          final actionStr = data["action"] as String;
          final value = data["value"] as int;
          final action = GameAction.values.firstWhere((e) => e.name == actionStr);
          onActionReceived?.call(action, value);
        }
      }
    });

    _chatSubscription = _roomRef!.child("lastChat").onValue.listen((event) {
      if (event.snapshot.value != null) {
        final data = event.snapshot.value as Map;
        final sender = data["sender"] as String;
        final myRole = isHosting ? "host" : "guest";
        
        if (sender != myRole) {
          onChatReceived?.call(data["message"] as String);
        }
      }
    });
  }

  void sendState(GameStatePacket state) {
    if (networkMode == NetworkMode.online && _roomRef != null) {
      _roomRef!.child("state").set(jsonEncode(state.toJson()));
    }
  }

  void sendAction(GameAction action, {int value = 0}) {
    if (networkMode == NetworkMode.online && _roomRef != null) {
      _roomRef!.child("actions").push().set({
        "action": action.name,
        "value": value,
        "sender": isHosting ? "host" : "guest",
        "timestamp": ServerValue.timestamp,
      });
    }
  }

  void sendChat(String message) {
    if (networkMode == NetworkMode.online && _roomRef != null) {
      _roomRef!.child("lastChat").set({
        "message": message,
        "sender": isHosting ? "host" : "guest",
        "timestamp": ServerValue.timestamp,
      });
    }
  }
  
  // Keep LAN methods for compatibility but they are unused in Firebase mode
  Future<void> host({int port = 9999}) async {}
  Future<void> connect({required String host, int port = 9999}) async {}
}
