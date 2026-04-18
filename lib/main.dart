import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'game.dart';
import 'models.dart';
import 'network_manager.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => Game()),
        ChangeNotifierProvider.value(value: NetworkManager.shared),
      ],
      child: const YanFarkleApp(),
    ),
  );
}

class YanFarkleApp extends StatelessWidget {
  const YanFarkleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YanFarkle',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.green,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: const ContentView(),
    );
  }
}

class ContentView extends StatefulWidget {
  const ContentView({super.key});

  @override
  State<ContentView> createState() => _ContentViewState();
}

class _ContentViewState extends State<ContentView> {
  bool isStarted = false;
  String hostIP = "127.0.0.1";
  bool isConfiguring = false;
  bool hasReceivedInitialState = false;
  bool showRules = false;
  bool showChat = false;
  String? _incomingMessage;
  Timer? _messageTimer;
  String? _p1Emote;
  String? _p2Emote;
  Timer? _p1EmoteTimer;
  Timer? _p2EmoteTimer;

  final TextEditingController _hostIPController = TextEditingController();
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final FocusNode _chatFocusNode = FocusNode();
  final FocusNode _roomFocusNode = FocusNode();
  final FocusNode _focusNode = FocusNode();
  late bool _isKeyboardActive;
  String _versionString = "";

  @override
  void initState() {
    super.initState();
    // Initialize based on both current highlight mode and whether a keyboard is physically present.
    _isKeyboardActive = FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    FocusManager.instance.addHighlightModeListener(_handleFocusHighlightModeChange);
    _initPackageInfo();
  }

  Future<void> _initPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _versionString = "v${info.version}+${info.buildNumber}";
      });
    }
  }

  void _handleFocusHighlightModeChange(FocusHighlightMode mode) {
    debugPrint("FocusHighlightMode changed to: $mode");
    if (mounted) {
      setState(() {
        _isKeyboardActive = mode == FocusHighlightMode.traditional;
      });
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_handleFocusHighlightModeChange);
    _hostIPController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    _chatFocusNode.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.jumpTo(_chatScrollController.position.maxScrollExtent);
      }
    });
    // Double check after a short delay for keyboard or layout shifts
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted && _chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showEmote(Player player, String emote) {
    if (player == Player.p1) {
      _p1EmoteTimer?.cancel();
      setState(() => _p1Emote = emote);
      _p1EmoteTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _p1Emote = null);
      });
    } else {
      _p2EmoteTimer?.cancel();
      setState(() => _p2Emote = emote);
      _p2EmoteTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _p2Emote = null);
      });
    }
  }

  void _setupNetworkCallbacks(Game game, NetworkManager networkManager) {
    networkManager.onStateReceived = (state) {
      setState(() {
        hasReceivedInitialState = true;
      });
      game.fromPacket(state);
    };

    networkManager.onChatReceived = (message) {
      if (!mounted) return;
      setState(() {
        game.chatMessages.add(ChatMessage(text: message, isMe: false));
      });
      if (showChat) {
        _scrollToBottom();
      } else {
        _messageTimer?.cancel();
        setState(() {
          _incomingMessage = message;
        });
        _messageTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() {
              _incomingMessage = null;
            });
          }
        });
      }
    };

    networkManager.onActionReceived = (action, value) {
      if (action == GameAction.emote) {
        final emotes = ["😀", "😂", "😎", "🤔", "😮", "😢", "😡", "👍", "👎", "🔥", "🎲", "🎯"];
        if (value >= 0 && value < emotes.length) {
          Player sender = game.myPlayer.next; // If it's a network game, it's from the other player
          _showEmote(sender, emotes[value]);
        }
        return;
      }

      if (action == GameAction.startGame) {
        if (mounted && isConfiguring) {
          setState(() => isConfiguring = false);
        }
        return;
      }

      if (action == GameAction.readyUp) {
        Player sender = PlayerExtension.fromRawValue(value);
        game.togglePlayerReady(sender);
        
        if (game.isLocalAuthority && game.p1Ready && game.p2Ready) {
          game.start();
          NetworkManager.shared.sendAction(GameAction.startGame);
          game.syncState();
          if (mounted && isConfiguring) {
            setState(() => isConfiguring = false);
          }
        } else if (game.isLocalAuthority) {
          game.syncState();
        }
        return;
      }

      // Guest ignore actions, they wait for state
      if (!game.isLocalAuthority) return;

      switch (action) {
        case GameAction.moveTo:
          game.currentDieIndex = value;
          break;
        case GameAction.select:
          game.currentDieIndex = value;
          game.toggleDieSelection(value);
          break;
        case GameAction.continueRoll:
          game.scoreAndContinue();
          break;
        case GameAction.endTurn:
          game.scoreAndEndTurn();
          break;
        case GameAction.bust:
          game.nextPlayerAfterBust();
          break;
        default:
          break;
      }
      game.syncState();
    };

    networkManager.onDisconnected = () {
      if (isConfiguring) {
        setState(() {
          isStarted = false;
          isConfiguring = false;
        });
      } else {
        if (game.state != GameState.gameOver) {
          game.state = GameState.gameOver;
          game.winner = game.myPlayer;
          game.winReason = "Opponent disconnected";
        } else {
          setState(() {}); // Rebuild to show disconnected UI if game is already over
        }
      }
    };

    networkManager.onGuestLeft = () {
      if (isConfiguring || !game.isGameStarted) {
        setState(() {
          isConfiguring = true; // Still in the setup phase implicitly but waiting
          game.p1Ready = false;
          game.p2Ready = false;
          game.syncState();
        });
      } else {
        if (game.state != GameState.gameOver) {
          game.state = GameState.gameOver;
          game.winner = game.myPlayer;
          game.winReason = "Opponent disconnected";
        } else {
          setState(() {}); // Rebuild to show disconnected UI if game is already over
        }
      }
    };

    networkManager.onConnected = () {
      setState(() {
        isStarted = true;
        isConfiguring = true;
      });
    };
  }

  @override
  Widget build(BuildContext context) {
    final game = context.watch<Game>();
    final networkManager = context.watch<NetworkManager>();

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (_chatFocusNode.hasFocus || _roomFocusNode.hasFocus) return KeyEventResult.ignored;

        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft || event.logicalKey == LogicalKeyboardKey.keyA ||
              event.logicalKey == LogicalKeyboardKey.arrowRight || event.logicalKey == LogicalKeyboardKey.keyD ||
              event.logicalKey == LogicalKeyboardKey.arrowUp || event.logicalKey == LogicalKeyboardKey.keyW ||
              event.logicalKey == LogicalKeyboardKey.arrowDown || event.logicalKey == LogicalKeyboardKey.keyS) {
            if (game.isLocalTurn && game.state != GameState.rolling && game.state != GameState.bust) {
              int offset = (event.logicalKey == LogicalKeyboardKey.arrowLeft || event.logicalKey == LogicalKeyboardKey.keyA ||
                            event.logicalKey == LogicalKeyboardKey.arrowUp || event.logicalKey == LogicalKeyboardKey.keyW) ? -1 : 1;
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft || event.logicalKey == LogicalKeyboardKey.keyA ||
                  event.logicalKey == LogicalKeyboardKey.arrowRight || event.logicalKey == LogicalKeyboardKey.keyD) {
                game.moveFocusHorizontal(offset);
              } else {
                game.moveFocusVertical(offset);
              }
              if (game.isLocalAuthority) {
                game.syncState();
              } else {
                networkManager.sendAction(GameAction.moveTo, value: game.currentDieIndex);
              }
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.space) {
            if (showChat) return KeyEventResult.ignored;

            if (game.isLocalTurn && game.state != GameState.rolling && game.state != GameState.bust) {
              if (game.isLocalAuthority) {
                game.toggleSelectedDie();
                game.syncState();
              } else {
                game.toggleSelectedDie();
                networkManager.sendAction(GameAction.select, value: game.currentDieIndex);
              }
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.keyF) {
            if (game.isLocalTurn && game.state != GameState.rolling && game.state != GameState.bust) {
              if (game.isLocalAuthority) {
                game.scoreAndContinue();
                game.syncState();
              } else {
                networkManager.sendAction(GameAction.continueRoll);
              }
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.keyQ) {
            if (game.isLocalTurn && game.state != GameState.rolling && game.state != GameState.bust) {
               if (game.isLocalAuthority) {
                 game.scoreAndEndTurn();
                 game.syncState();
               } else {
                 networkManager.sendAction(GameAction.endTurn);
               }
            }
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () {
          // Unfocus any text fields and regain game focus
          FocusManager.instance.primaryFocus?.unfocus();
          _focusNode.requestFocus();
        },
        behavior: HitTestBehavior.opaque,
        child: Scaffold(
          body: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF196633), Color(0xFF0D331A)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(child: _buildBody(game, networkManager)),
                if (showRules)
                  Positioned.fill(
                    child: RulesView(onDismiss: () => setState(() => showRules = false)),
                  ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Text(
                    _versionString,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(Game game, NetworkManager networkManager) {
    if (!isStarted) {
      return _buildMainMenu(game, networkManager);
    } else if (isConfiguring) {
      if (game.isNetworkGame && networkManager.isHosting && !networkManager.isConnected) {
        // Host is configuring but waiting for someone to join (or guest left)
        return Stack(
          fit: StackFit.expand,
          children: [
            _buildGame(game, networkManager),
            if (showChat)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildChat(game, networkManager),
              ),
          ],
        );
      }
      return _buildConfigMenu(game, networkManager);
    } else if (game.state == GameState.gameOver) {
      return _buildGameOver(game, networkManager);
    } else {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildGame(game, networkManager),
          if (showChat)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildChat(game, networkManager),
            ),
        ],
      );
    }
  }

  Widget _buildMainMenu(Game game, NetworkManager networkManager) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  const Text(
                    "YanFarkle",
                    style: TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 40),
                  _menuButton("1 Player (Vs Bot)", Colors.orange, () {
                    game.start();
                    hasReceivedInitialState = true;
                    game.isNetworkGame = false;
                    game.isBotGame = true;
                    setState(() {
                      isStarted = true;
                      isConfiguring = true;
                    });
                  }),
                  const SizedBox(height: 15),
                  _menuButton("2 Players (Local)", Colors.white, () {
                    game.start();
                    hasReceivedInitialState = true;
                    game.isNetworkGame = false;
                    game.isBotGame = false;
                    setState(() {
                      isStarted = true;
                      isConfiguring = true;
                    });
                  }, textColor: const Color(0xFF196633)),
                  const SizedBox(height: 15),
                  _menuButton("Host Online Game", Colors.purple, () {
                    game.start();
                    hasReceivedInitialState = true;
                    game.isNetworkGame = true;
                    game.isBotGame = false;
                    game.myPlayer = Player.p1;
                    networkManager.hostOnline();
                    _setupNetworkCallbacks(game, networkManager);
                    setState(() {
                      isStarted = true;
                    });
                  }),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 150,
                        child: TextField(
                          controller: _hostIPController,
                          focusNode: _roomFocusNode,
                          decoration: const InputDecoration(
                            fillColor: Colors.white,
                            filled: true,
                            hintText: "Room ID",
                            border: OutlineInputBorder(),
                          ),
                          style: const TextStyle(color: Colors.black),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        onPressed: networkManager.isConnecting ? null : () {
                          game.start();
                          hasReceivedInitialState = false;
                          game.isNetworkGame = true;
                          game.isBotGame = false;
                          game.myPlayer = Player.p2;
                          networkManager.joinOnline(_hostIPController.text);
                          _setupNetworkCallbacks(game, networkManager);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purple,
                          foregroundColor: Colors.white,
                        ),
                        child: networkManager.isConnecting
                            ? const CircularProgressIndicator(color: Colors.white)
                            : const Text("Join Online"),
                      ),
                    ],
                  ),
                  if (networkManager.connectionError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(networkManager.connectionError!, style: const TextStyle(color: Colors.red)),
                    ),
                  const SizedBox(height: 20),
                  OutlinedButton(
                    onPressed: () => setState(() => showRules = true),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      minimumSize: const Size(250, 0),
                    ),
                    child: const Text("How to Play", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

  Widget _playerReadyStatus(String label, bool isReady, {bool isDisconnected = false}) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 18, color: Colors.white)),
        const SizedBox(height: 8),
        Icon(
          isDisconnected ? Icons.close : (isReady ? Icons.check_circle : Icons.circle_outlined),
          color: isDisconnected ? Colors.red : (isReady ? Colors.greenAccent : Colors.white38),
          size: 48,
        ),
        Text(
          isDisconnected ? "LEFT" : (isReady ? "READY" : "WAITING"),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: isDisconnected ? Colors.red : (isReady ? Colors.greenAccent : Colors.white38),
          ),
        ),
      ],
    );
  }

  Widget _menuButton(String text, Color color, VoidCallback onPressed, {Color textColor = Colors.white}) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: textColor,
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
        minimumSize: const Size(250, 0),
      ),
      onPressed: onPressed,
      child: Text(text, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildConfigMenu(Game game, NetworkManager networkManager) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  const Text("Game Setup", style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 20),
                  if (game.isLocalAuthority)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text("Goal: ", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                        IconButton(
                          icon: const Icon(Icons.remove_circle, color: Colors.white),
                          onPressed: () {
                            if (game.winPoints > 1000) setState(() => game.winPoints -= 1000);
                          },
                        ),
                        Text("${game.winPoints}", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.yellow)),
                        IconButton(
                          icon: const Icon(Icons.add_circle, color: Colors.white),
                          onPressed: () {
                            if (game.winPoints < 10000) setState(() => game.winPoints += 1000);
                          },
                        ),
                      ],
                    ),
                  if (game.isLocalAuthority)
                    const SizedBox(height: 40),
                  if (game.isNetworkGame) ...[
                    Text(
                      networkManager.isHosting ? "Hosting Lobby" : "Joined Lobby",
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          "Room ID: ${networkManager.roomID}",
                          style: const TextStyle(fontSize: 24, color: Colors.yellow),
                        ),
                        if (networkManager.isHosting) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.copy, color: Colors.yellow),
                            onPressed: () {
                              if (networkManager.roomID != null) {
                                Clipboard.setData(ClipboardData(text: networkManager.roomID!));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Room ID copied to clipboard!'), duration: Duration(seconds: 2)),
                                );
                              }
                            },
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 30),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _playerReadyStatus("You", game.myPlayer == Player.p1 ? game.p1Ready : game.p2Ready),
                        const SizedBox(width: 40),
                        _playerReadyStatus("Opponent", game.myPlayer == Player.p1 ? game.p2Ready : game.p1Ready),
                      ],
                    ),
                    const SizedBox(height: 40),
                    _menuButton(
                      (game.myPlayer == Player.p1 ? game.p1Ready : game.p2Ready) ? "Unready" : "Ready Up",
                      (game.myPlayer == Player.p1 ? game.p1Ready : game.p2Ready) ? Colors.red : Colors.green,
                      () {
                        bool started = game.readyUp();
                        if (started) {
                          setState(() => isConfiguring = false);
                        }
                      },
                    ),
                  ] else ...[
                    _menuButton("Start Game", Colors.white, () {
                      game.start();
                      setState(() => isConfiguring = false);
                    }, textColor: const Color(0xFF196633)),
                  ],
                  const SizedBox(height: 15),
                  _menuButton("Cancel", Colors.red, () {
                    networkManager.stop();
                    setState(() {
                      isStarted = false;
                      isConfiguring = false;
                    });
                  }),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

  Widget _buildGameOver(Game game, NetworkManager networkManager) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  if (game.winner != null)
                    Text(game.playerName(game.winner!) == "You" ? "You Win!" : "${game.playerName(game.winner!)} Wins!", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white))
                  else
                    const Text("Someone Wins!", style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
                  if (game.winReason != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(game.winReason!, style: const TextStyle(fontSize: 18, color: Colors.white70)),
                    ),
                  const SizedBox(height: 30),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Column(
                        children: [
                          Text(game.playerName(game.isNetworkGame || game.isBotGame ? game.myPlayer : Player.p1), style: const TextStyle(fontSize: 20, color: Colors.white)),
                          Text("${game.getScore(game.isNetworkGame || game.isBotGame ? game.myPlayer : Player.p1)}", style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
                        ],
                      ),
                      const SizedBox(width: 40),
                      Column(
                        children: [
                          Text(game.playerName(game.isNetworkGame || game.isBotGame ? game.myPlayer.next : Player.p2), style: const TextStyle(fontSize: 20, color: Colors.white)),
                          Text("${game.getScore(game.isNetworkGame || game.isBotGame ? game.myPlayer.next : Player.p2)}", style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 40),
                  if (game.isNetworkGame && game.winReason == null) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _playerReadyStatus("You", game.myPlayer == Player.p1 ? game.p1Ready : game.p2Ready),
                        const SizedBox(width: 40),
                        if (!networkManager.isConnected)
                          _playerReadyStatus("Opponent", false, isDisconnected: true)
                        else
                          _playerReadyStatus("Opponent", game.myPlayer == Player.p1 ? game.p2Ready : game.p1Ready),
                      ],
                    ),
                    const SizedBox(height: 30),
                    if (networkManager.isConnected)
                      _menuButton(
                        (game.myPlayer == Player.p1 ? game.p1Ready : game.p2Ready) ? "Unready" : "Play Again",
                        (game.myPlayer == Player.p1 ? game.p1Ready : game.p2Ready) ? Colors.red : Colors.green,
                        () {
                          bool started = game.readyUp();
                          if (started) {
                            setState(() => isConfiguring = false);
                          }
                        },
                      ),
                  ] else ...[
                    if (!game.isNetworkGame)
                      _menuButton("Play Again", Colors.white, () {
                        game.start();
                      }, textColor: const Color(0xFF196633)),
                  ],
                  const SizedBox(height: 15),
                  _menuButton("Exit to Menu", Colors.red, () {
                    networkManager.stop();
                    setState(() {
                      isStarted = false;
                      isConfiguring = false;
                    });
                  }),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

  Widget _buildGame(Game game, NetworkManager networkManager) {
    bool isWaiting = game.isNetworkGame && !networkManager.isConnected;
    if (isConfiguring && game.isNetworkGame && networkManager.isHosting) {
       isWaiting = true;
    }
    bool actionEnabled = game.isLocalTurn && !isWaiting && hasReceivedInitialState;
    int potentialScore = game.calculateSelectedScore();

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: IntrinsicHeight(
                        child: SafeArea(
                          bottom: false,
                          child: Column(
                            children: [
                              Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10),
                              child: Row(
                                children: [
                                  ElevatedButton(
                                    onPressed: () {
                                      networkManager.stop();
                                      setState(() => isStarted = false);
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      foregroundColor: Colors.white,
                                    ),
                                    child: const Text("Leave"),
                                  ),
                                  const Spacer(),
                                  if (game.isNetworkGame) ...[
                                    Container(
                                      margin: const EdgeInsets.only(left: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.2),
                                        shape: BoxShape.circle,
                                      ),
                                      child: IconButton(
                                        icon: const Icon(Icons.message, color: Colors.white70, size: 20),
                                        onPressed: () {
                                          setState(() => showChat = true);
                                          _scrollToBottom();
                                        },
                                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                                        padding: EdgeInsets.zero,
                                      ),
                                    ),
                                    Container(
                                      margin: const EdgeInsets.only(left: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.2),
                                        shape: BoxShape.circle,
                                      ),
                                      child: IconButton(
                                        icon: const Icon(Icons.emoji_emotions, color: Colors.white70, size: 20),
                                        onPressed: () => _showEmotePicker(game, networkManager),
                                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                                        padding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ],
                                  Container(
                                    margin: const EdgeInsets.only(left: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.2),
                                      shape: BoxShape.circle,
                                    ),
                                    child: IconButton(
                                      icon: const Icon(Icons.question_mark_rounded, color: Colors.white70, size: 20),
                                      onPressed: () => setState(() => showRules = true),
                                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                                      padding: EdgeInsets.zero,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!isWaiting && hasReceivedInitialState)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    _scoreCard(game, game.isNetworkGame || game.isBotGame ? game.myPlayer : Player.p1),
                                    _scoreCard(game, game.isNetworkGame || game.isBotGame ? game.myPlayer.next : Player.p2),
                                  ],
                                ),
                              ),
                            if (!isWaiting && hasReceivedInitialState) ...[
                              Text(
                                game.isNetworkGame ? (game.isLocalTurn ? "Your Turn" : "Opponent's Turn") : "${game.playerName(game.currentPlayer)}'s Turn",
                                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                              Text("Goal: ${game.winPoints}", style: const TextStyle(color: Colors.white70)),
                              Text("Turn Score: ${game.turnScore}", style: const TextStyle(fontSize: 20, color: Colors.yellow)),
                            ],
                            if (isWaiting) ...[
                              const Spacer(),
                              const CircularProgressIndicator(color: Colors.white),
                              const SizedBox(height: 10),
                              if (networkManager.isHosting)
                                Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text("Room ID: ${networkManager.roomID ?? '...'}", style: const TextStyle(color: Colors.white, fontSize: 20)),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          icon: const Icon(Icons.copy, color: Colors.white),
                                          onPressed: () {
                                            if (networkManager.roomID != null) {
                                              Clipboard.setData(ClipboardData(text: networkManager.roomID!));
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(content: Text('Room ID copied to clipboard!'), duration: Duration(seconds: 2)),
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                    const Text("Waiting for opponent...", style: TextStyle(color: Colors.white, fontSize: 20), textAlign: TextAlign.center),
                                  ],
                                )
                              else
                                const Text("Waiting for opponent...", style: TextStyle(color: Colors.white, fontSize: 20)),
                              const Spacer(),
                            ] else if (game.isNetworkGame && !hasReceivedInitialState) ...[
                              const Spacer(),
                              const CircularProgressIndicator(color: Colors.white),
                              const SizedBox(height: 10),
                              const Text("Waiting for host...", style: TextStyle(color: Colors.white, fontSize: 20)),
                              const Spacer(),
                            ] else ...[
                              const Spacer(),
                              SizedBox(
                                height: 60,
                                child: game.state == GameState.bust
                                    ? const Text("BUST!", style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.red))
                                    : const SizedBox.shrink(),
                              ),
                              _buildDiceArea(game, networkManager),
                            ],
                            const Spacer(),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
            SafeArea(
              top: false,
              child: Column(
                children: [
                  if (!isWaiting && hasReceivedInitialState)
                    Text("Selected Score: $potentialScore", style: TextStyle(fontSize: 18, color: potentialScore > 0 ? Colors.greenAccent : Colors.white)),
                  const SizedBox(height: 10),
                  if (game.state != GameState.bust)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(
                          onPressed: (potentialScore == 0 || !actionEnabled) ? null : () {
                            if (game.isLocalAuthority) {
                              game.scoreAndContinue();
                              game.syncState();
                            } else {
                              networkManager.sendAction(GameAction.continueRoll);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                          ),
                          child: Text(_isKeyboardActive ? "Score & Roll (F)" : "Score & Roll"),
                        ),
                        const SizedBox(width: 20),
                        ElevatedButton(
                          onPressed: (potentialScore == 0 || !actionEnabled) ? null : () {
                            if (game.isLocalAuthority) {
                              game.scoreAndEndTurn();
                              game.syncState();
                            } else {
                              networkManager.sendAction(GameAction.endTurn);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                          ),
                          child: Text(_isKeyboardActive ? "Score & End (Q)" : "Score & End"),
                        ),
                      ],
                    ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
        if (_incomingMessage != null)
          Positioned(
            top: 60,
            left: 20,
            right: 20,
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 300),
              tween: Tween(begin: 0.0, end: 1.0),
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, (1 - value) * -20),
                    child: child,
                  ),
                );
              },
          child: GestureDetector(
            onTap: () {
              setState(() {
                showChat = true;
                _incomingMessage = null;
              });
              _scrollToBottom();
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.chat_bubble, color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _incomingMessage!,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
            ),
          ),
      ],
    );
  }

  Widget _scoreCard(Game game, Player player) {
    bool isHighlighted = game.currentPlayer == player && game.state != GameState.gameOver;
    String emote = (player == Player.p1) ? (_p1Emote ?? "") : (_p2Emote ?? "");

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isHighlighted ? Colors.white.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: isHighlighted ? Colors.yellow : Colors.transparent, width: 2),
          ),
          child: Column(
            children: [
              Text(game.playerName(player), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              Text("${game.getScore(player)}", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: AnimatedOpacity(
            opacity: emote.isEmpty ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: Text(emote, style: const TextStyle(fontSize: 32)),
          ),
        ),
      ],
    );
  }

  void _showEmotePicker(Game game, NetworkManager networkManager) {
    final emotes = ["😀", "😂", "😎", "🤔", "😮", "😢", "😡", "👍", "👎", "🔥", "🎲", "🎯"];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF0D331A),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Send an Emote", style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                itemCount: emotes.length,
                itemBuilder: (context, index) {
                  return GestureDetector(
                    onTap: () {
                      _showEmote(game.myPlayer, emotes[index]);
                      networkManager.sendAction(GameAction.emote, value: index);
                      Navigator.pop(context);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(emotes[index], style: const TextStyle(fontSize: 32)),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiceArea(Game game, NetworkManager networkManager) {
    List<int> diceToShow = game.state == GameState.rolling ? game.rollingDice : game.remainingDice;
    return Column(
      children: List.generate(2, (row) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (col) {
            int index = row * 3 + col;
            if (index < diceToShow.length) {
              bool isSelected = game.state != GameState.rolling && game.selectedDice.contains(index);
              return GestureDetector(
                onTap: () {
                  if (game.state == GameState.rolling || !game.isLocalTurn || game.state == GameState.bust) return;
                  game.currentDieIndex = index;
                  if (game.isLocalAuthority) {
                    game.toggleDieSelection(index);
                    game.syncState();
                  } else {
                    game.toggleDieSelection(index);
                    networkManager.sendAction(GameAction.select, value: index);
                  }
                },
                child: DieWidget(
                  value: diceToShow[index],
                  isSelected: isSelected,
                  isFocused: _isKeyboardActive && game.currentDieIndex == index && game.state != GameState.rolling && game.isLocalTurn,
                  isRolling: game.state == GameState.rolling,
                  rotation: game.diceRotations[index] ?? 0,
                ),
              );
            } else {
              return const SizedBox(width: 80, height: 80);
            }
          }),
        );
      }),
    );
  }

  Widget _buildChat(Game game, NetworkManager networkManager) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.black87,
      ),
      height: 300,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Row(
              children: [
                const Padding(padding: EdgeInsets.all(8.0), child: Text("Chat", style: TextStyle(color: Colors.white, fontSize: 18))),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => setState(() => showChat = false)),
              ],
            ),
            Expanded(
              child: ListView.builder(
                controller: _chatScrollController,
                itemCount: game.chatMessages.length,
                itemBuilder: (context, index) {
                  final msg = game.chatMessages[index];
                  return Align(
                    alignment: msg.isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: msg.isMe ? Colors.blue : Colors.grey,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(msg.text, style: const TextStyle(color: Colors.white)),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _chatController,
                      focusNode: _chatFocusNode,
                      style: const TextStyle(color: Colors.black),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        hintText: "Message...",
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                      onSubmitted: (text) {
                        if (text.isNotEmpty) {
                          game.chatMessages.add(ChatMessage(text: text, isMe: true));
                          networkManager.sendChat(text);
                          _chatController.clear();
                          setState(() {});
                          _scrollToBottom();
                          _chatFocusNode.requestFocus();
                        }
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: () {
                      final text = _chatController.text;
                      if (text.isNotEmpty) {
                        game.chatMessages.add(ChatMessage(text: text, isMe: true));
                        networkManager.sendChat(text);
                        _chatController.clear();
                        setState(() {});
                        _scrollToBottom();
                        _chatFocusNode.requestFocus();
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RulesView extends StatefulWidget {
  final VoidCallback onDismiss;
  const RulesView({super.key, required this.onDismiss});

  @override
  State<RulesView> createState() => _RulesViewState();
}

class _RulesViewState extends State<RulesView> {
  int currentPage = 0;
  final int totalPages = 6;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: const Color(0xFF0D331A),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text("How to Play", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: widget.onDismiss,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text("Done", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF196633), Color(0xFF0D331A)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Stack(
              children: [
                _buildPage(currentPage),
                Positioned(
                  bottom: 20,
                  left: 20,
                  right: 20,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (currentPage > 0)
                        IconButton(
                          icon: const Icon(Icons.arrow_circle_left, size: 48, color: Colors.white70),
                          onPressed: () => setState(() => currentPage--),
                        )
                      else
                        const SizedBox(width: 48),
                      if (currentPage < totalPages - 1)
                        IconButton(
                          icon: const Icon(Icons.arrow_circle_right, size: 48, color: Colors.white70),
                          onPressed: () => setState(() => currentPage++),
                        )
                      else
                        const SizedBox(width: 48),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPage(int index) {
    switch (index) {
      case 0: return const RulePage1();
      case 1: return const RulePage2();
      case 2: return const RulePage3();
      case 3: return const RulePage4();
      case 4: return const RulePage6();
      case 5: return const RulePage5();
      default: return const SizedBox.shrink();
    }
  }
}

class RulePage1 extends StatefulWidget {
  const RulePage1({super.key});

  @override
  State<RulePage1> createState() => _RulePage1State();
}

class _RulePage1State extends State<RulePage1> {
  late List<int> diceValues;
  final math.Random random = math.Random();
  bool _running = true;

  @override
  void initState() {
    super.initState();
    diceValues = List.generate(6, (_) => random.nextInt(6) + 1);
    _rollDice();
  }

  void _rollDice() async {
    while (_running) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      setState(() {
        diceValues = List.generate(6, (_) => random.nextInt(6) + 1);
      });
    }
  }

  @override
  void dispose() {
    _running = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 40),
        const Text("Welcome to YanFarkle!", style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white), textAlign: TextAlign.center),
        const SizedBox(height: 30),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Text("The goal is to reach the winning score by rolling dice and banking points.", 
            style: TextStyle(fontSize: 20, color: Colors.white), textAlign: TextAlign.center),
        ),
        const SizedBox(height: 30),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DieWidget(value: diceValues[0], isSelected: false, isFocused: false, isRolling: true, rotation: 0),
            DieWidget(value: diceValues[1], isSelected: false, isFocused: false, isRolling: true, rotation: 0),
            DieWidget(value: diceValues[2], isSelected: false, isFocused: false, isRolling: true, rotation: 0),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DieWidget(value: diceValues[3], isSelected: false, isFocused: false, isRolling: true, rotation: 0),
            DieWidget(value: diceValues[4], isSelected: false, isFocused: false, isRolling: true, rotation: 0),
            DieWidget(value: diceValues[5], isSelected: false, isFocused: false, isRolling: true, rotation: 0),
          ],
        ),
        const SizedBox(height: 30),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Text("You roll 6 dice. You must select at least one scoring die to continue your turn.",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.yellow), textAlign: TextAlign.center),
        ),
      ],
    );
  }
}

class RulePage2 extends StatelessWidget {
  const RulePage2({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 40),
        const Text("Basic Scoring", style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 30),
        const Text("Single 1s and 5s are your bread and butter.", style: TextStyle(fontSize: 20, color: Colors.white70), textAlign: TextAlign.center),
        const SizedBox(height: 30),
        _scoreRow(1, "100 points"),
        const SizedBox(height: 20),
        _scoreRow(5, "50 points"),
        const SizedBox(height: 30),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Text("Select these dice to lock in points and either score them or roll the remaining dice for more!",
            style: TextStyle(fontSize: 18, color: Colors.white), textAlign: TextAlign.center),
        ),
      ],
    );
  }

  Widget _scoreRow(int value, String points) {
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(horizontal: 40),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(15)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DieWidget(value: value, isSelected: true, isFocused: false, isRolling: false, rotation: 0),
          const SizedBox(width: 20),
          Text("= $points", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.yellow)),
        ],
      ),
    );
  }
}

class RulePage3 extends StatelessWidget {
  const RulePage3({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 30),
        const Text("Multiples", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 10),
        const Text("Three of a kind gives you big points!", style: TextStyle(fontSize: 20, color: Colors.white70)),
        const SizedBox(height: 20),
        _multiplesRow([1, 1, 1], "1000 pts"),
        const SizedBox(height: 10),
        _multiplesRow([4, 4, 4], "400 pts"),
        const Text("For 2-6, it's 100 x Face Value", style: TextStyle(fontSize: 14, color: Colors.white60)),
        const SizedBox(height: 20),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Text("Four, Five, or Six of a kind doubles the score for each extra die!",
            style: TextStyle(fontSize: 18, color: Colors.white), textAlign: TextAlign.center),
        ),
        const SizedBox(height: 10),
        _multiplesRow([4, 4, 4, 4], "800 pts"),
      ],
    );
  }

  Widget _multiplesRow(List<int> values, String points) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(15)),
      child: Row(
        children: [
          ...values.map((v) => SizedBox(width: 65, height: 65, child: Transform.scale(scale: 0.85, child: DieWidget(value: v, isSelected: true, isFocused: false, isRolling: false, rotation: 0)))),
          const Spacer(),
          Text(points, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.yellow)),
        ],
      ),
    );
  }
}

class RulePage4 extends StatelessWidget {
  const RulePage4({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 40),
        const Text("Straights", style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 20),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Text(
            "Roll a sequence of numbers for massive points!",
            style: TextStyle(fontSize: 20, color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(15)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _straightInfo("Small Straight (1-5) = 500 pts", [1, 2, 3, 4, 5]),
              const SizedBox(height: 15),
              _straightInfo("Large Straight (2-6) = 750 pts", [2, 3, 4, 5, 6]),
              const SizedBox(height: 15),
              _straightInfo("Full Straight (1-6) = 1500 pts", [1, 2, 3, 4, 5, 6]),
            ],
          ),
        ),
      ],
    );
  }

  Widget _straightInfo(String title, List<int> values) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.yellow)),
        const SizedBox(height: 5),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: values.map((v) => SizedBox(width: 65, height: 65, child: Transform.scale(scale: 0.85, child: DieWidget(value: v, isSelected: true, isFocused: false, isRolling: false, rotation: 0)))).toList(),
          ),
        ),
      ],
    );
  }
}

class RulePage5 extends StatelessWidget {
  const RulePage5({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 30),
          const Text("Farkle & Hot Dice", style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 25),
          _infoBox("FARKLE (Bust!)", Colors.red, "If your roll has NO scoring dice, you Farkle! You lose all points accumulated during that turn.", [2, 3, 4, 6], false),
          const SizedBox(height: 25),
          _infoBox("🔥 HOT DICE! 🔥", Colors.orange, "If you manage to select and score with ALL 6 dice, you get Hot Dice! You can roll all 6 again and keep building your turn score.", [5, 5, 5, 5, 5, 5], true),
          const SizedBox(height: 60), // Add padding for bottom navigation
        ],
      ),
    );
  }

  Widget _infoBox(String title, Color titleColor, String desc, List<int> dice, bool isSelected) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(15)),
      child: Column(
        children: [
          Text(title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: titleColor)),
          const SizedBox(height: 15),
          SizedBox(
            width: dice.length == 6 ? 195 : null,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 0,
              runSpacing: 0,
              children: dice.map((v) => SizedBox(
                width: 65, 
                height: 65, 
                child: Transform.scale(
                  scale: 0.85, 
                  child: DieWidget(value: v, isSelected: isSelected, isFocused: false, isRolling: false, rotation: 0)
                )
              )).toList(),
            ),
          ),
          const SizedBox(height: 15),
          Text(desc, style: const TextStyle(fontSize: 14, color: Colors.white), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class RulePage6 extends StatelessWidget {
  const RulePage6({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 30),
          const Text("Score & Roll vs Score & End", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white), textAlign: TextAlign.center),
          const SizedBox(height: 25),
          const Text("After selecting scoring dice, you have two choices:", style: TextStyle(fontSize: 20, color: Colors.white70), textAlign: TextAlign.center),
          const SizedBox(height: 25),
          _choiceBox("Score & Roll", Colors.blue, "Locks in your selected dice points to your turn score and rolls the remaining dice. It's risky but rewarding!"),
          const SizedBox(height: 25),
          _choiceBox("Score & End", Colors.orange, "Banks your total turn score into your overall score and safely ends your turn."),
          const SizedBox(height: 60), // Add padding for bottom navigation
        ],
      ),
    );
  }

  Widget _choiceBox(String title, Color color, String desc) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(15)),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
            child: Center(
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
          ),
          const SizedBox(height: 15),
          Text(desc, style: const TextStyle(fontSize: 14, color: Colors.white), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class DieWidget extends StatelessWidget {
  final int value;
  final bool isSelected;
  final bool isFocused;
  final bool isRolling;
  final double rotation;

  const DieWidget({super.key, required this.value, required this.isSelected, required this.isFocused, required this.isRolling, required this.rotation});

  @override
  Widget build(BuildContext context) {
    double displayRotation = isRolling ? (math.Random().nextDouble() * 40 - 20) : rotation;
    return Container(
      margin: const EdgeInsets.all(5),
      child: Transform.rotate(
        angle: (displayRotation + (isSelected ? 5 : 0)) * math.pi / 180,
        child: Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            color: isSelected ? Colors.yellow : Colors.white,
            borderRadius: BorderRadius.circular(15),
            border: isFocused ? Border.all(color: Colors.blueAccent, width: 3) : null,
            boxShadow: const [BoxShadow(color: Colors.black26, offset: Offset(2, 2), blurRadius: 5)],
          ),
          child: CustomPaint(
            painter: DiePainter(value),
          ),
        ),
      ),
    );
  }
}

class DiePainter extends CustomPainter {
  final int value;
  DiePainter(this.value);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    final double radius = size.width / 10;
    
    void drawDot(double x, double y) {
      canvas.drawCircle(Offset(size.width * x, size.height * y), radius, paint);
    }

    if (value == 1 || value == 3 || value == 5) drawDot(0.5, 0.5);
    if (value > 1) { drawDot(0.25, 0.25); drawDot(0.75, 0.75); }
    if (value > 3) { drawDot(0.25, 0.75); drawDot(0.75, 0.25); }
    if (value == 6) { drawDot(0.25, 0.5); drawDot(0.75, 0.5); }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
