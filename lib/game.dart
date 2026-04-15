import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'models.dart';
import 'game_rules.dart';
import 'network_manager.dart';

class ChatMessage {
  final String text;
  final bool isMe;

  ChatMessage({required this.text, required this.isMe});
}

class Game extends ChangeNotifier {
  int winPoints = 2000;
  Map<Player, int> playerScores = {Player.p1: 0, Player.p2: 0};
  bool isBotGame = false;

  Player currentPlayer = Player.p1;
  GameState _state = GameState.rolling;
  GameState get state => _state;
  set state(GameState value) {
    GameState oldState = _state;
    _state = value;
    if (_state == GameState.rolling && oldState != GameState.rolling) {
      _startRollingAnimation();
    } else if (_state != GameState.rolling && oldState == GameState.rolling) {
      _stopRollingAnimation();
      // Generate landed rotations for client
      diceRotations.clear();
      for (int i = 0; i < remainingDice.length; i++) {
        diceRotations[i] = _random.nextDouble() * 30 - 15;
      }
    }

    if (diceRotations.isEmpty && remainingDice.isNotEmpty && _state != GameState.rolling && _state != GameState.gameOver) {
      for (int i = 0; i < remainingDice.length; i++) {
        diceRotations[i] = _random.nextDouble() * 30 - 15;
      }
    }
    if (_state == GameState.turn && isBotGame && currentPlayer == Player.p2) {
      Future.delayed(const Duration(seconds: 1), _executeBotTurn);
    }
    notifyListeners();
  }

  Player? winner;
  int turnScore = 0;
  List<int> remainingDice = [];
  Set<int> selectedDice = {};
  int currentDieIndex = 0;

  bool isNetworkGame = false;
  Player myPlayer = Player.p1;
  bool p1Ready = false;
  bool p2Ready = false;

  String localP1Name = "Player 1";
  String localP2Name = "Player 2";

  List<ChatMessage> chatMessages = [];
  List<int> rollingDice = [];
  Map<int, double> diceRotations = {};
  Timer? _rollingTimer;
  final Random _random = Random();

  int getScore(Player player) => playerScores[player] ?? 0;
  void setScore(Player player, int score) {
    playerScores[player] = score;
    notifyListeners();
  }

  void start() {
    playerScores = {Player.p1: 0, Player.p2: 0};
    winner = null;
    currentPlayer = _random.nextBool() ? Player.p1 : Player.p2;
    p1Ready = false;
    p2Ready = false;
    chatMessages.clear();
    resetTurn();
  }

  void resetTurn() {
    turnScore = 0;
    _rollNewDice(6);
  }

  void _rollNewDice(int num) {
    state = GameState.rolling;
    rollingDice = List.generate(num, (_) => _random.nextInt(6) + 1);
    remainingDice = List.filled(num, 0);
    syncState();

    if (isLocalAuthority) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (state != GameState.rolling) return;
        remainingDice = _rollDice(num);
        diceRotations.clear();
        for (int i = 0; i < remainingDice.length; i++) {
          diceRotations[i] = _random.nextDouble() * 30 - 15;
        }
        selectedDice.clear();
        currentDieIndex = 0;
        checkBust();
        syncState();
        notifyListeners();
      });
    } else {
      remainingDice = [];
      selectedDice.clear();
      currentDieIndex = 0;
    }
    notifyListeners();
  }

  List<int> _rollDice(int numDice) => List.generate(numDice, (_) => _random.nextInt(6) + 1);

  int calculateSelectedScore() {
    List<int> dice = selectedDice
        .where((idx) => idx >= 0 && idx < remainingDice.length)
        .map((idx) => remainingDice[idx])
        .toList();
    return GameRules.calculateScore(dice);
  }

  bool scoreAndContinue() {
    int score = calculateSelectedScore();
    if (score == 0) return false;

    turnScore += score;
    List<int> validSelected = selectedDice.where((idx) => idx >= 0 && idx < remainingDice.length).toList();
    List<int> newRemaining = [];
    for (int i = 0; i < remainingDice.length; i++) {
      if (!validSelected.contains(i)) {
        newRemaining.add(remainingDice[i]);
      }
    }
    remainingDice = newRemaining;
    diceRotations.clear();
    for (int i = 0; i < remainingDice.length; i++) {
      diceRotations[i] = _random.nextDouble() * 30 - 15;
    }
    selectedDice.clear();
    currentDieIndex = 0;

    if (remainingDice.isEmpty) {
      _rollNewDice(6);
    } else {
      _rollNewDice(remainingDice.length);
    }
    notifyListeners();
    return true;
  }

  bool scoreAndEndTurn() {
    int score = calculateSelectedScore();
    if (score == 0) return false;

    turnScore += score;
    int newScore = getScore(currentPlayer) + turnScore;
    setScore(currentPlayer, newScore);

    if (newScore >= winPoints) {
      state = GameState.gameOver;
      winner = currentPlayer;
    } else {
      state = GameState.endTurn;
    }

    if (state == GameState.endTurn) {
      currentPlayer = currentPlayer.next;
      resetTurn();
    }
    notifyListeners();
    return true;
  }

  void checkBust() {
    if (GameRules.getScoringIndices(remainingDice).isEmpty) {
      state = GameState.bust;
      syncState();

      if (isLocalAuthority) {
        Future.delayed(const Duration(seconds: 2), () {
          if (state == GameState.bust) {
            nextPlayerAfterBust();
            syncState();
          }
        });
      }
    } else {
      state = GameState.turn;
      syncState();
    }
    notifyListeners();
  }

  void nextPlayerAfterBust() {
    if (state != GameState.bust) return;
    currentPlayer = currentPlayer.next;
    resetTurn();
    notifyListeners();
  }

  void _executeBotTurn() {
    if (state != GameState.turn || !isBotGame || currentPlayer != Player.p2) return;

    List<int> scoringIndices = GameRules.getScoringIndices(remainingDice);
    if (scoringIndices.isEmpty) return;

    selectedDice = scoringIndices.toSet();
    notifyListeners();

    Future.delayed(const Duration(milliseconds: 1500), () {
      if (state != GameState.turn || currentPlayer != Player.p2) return;

      int calculated = calculateSelectedScore();
      int currentBank = getScore(Player.p2);
      int remainingCount = remainingDice.length - selectedDice.length;
      int totalPotential = calculated + turnScore;

      if (totalPotential + currentBank >= winPoints) {
        scoreAndEndTurn();
      } else if (remainingCount == 0) {
        scoreAndContinue();
      } else if (totalPotential >= 500 || (remainingCount <= 2 && totalPotential >= 300)) {
        scoreAndEndTurn();
      } else {
        scoreAndContinue();
      }
    });
  }

  void toggleDieSelection(int index) {
    if (selectedDice.contains(index)) {
      selectedDice.remove(index);
    } else {
      selectedDice.add(index);
    }
    notifyListeners();
  }

  void moveFocusHorizontal(int offset) {
    if (remainingDice.isEmpty) return;
    int count = remainingDice.length;
    int col = currentDieIndex % 3;
    int row = currentDieIndex ~/ 3;

    if (offset == -1 && col > 0) {
      int targetIdx = row * 3 + (col - 1);
      if (targetIdx < count) currentDieIndex = targetIdx;
    } else if (offset == 1 && col < 2) {
      int targetIdx = row * 3 + (col + 1);
      if (targetIdx < count) {
        currentDieIndex = targetIdx;
      } else {
        for (int c = col + 1; c <= 2; c++) {
          for (int r = 0; r <= 1; r++) {
            int idx = r * 3 + c;
            if (idx < count) {
              currentDieIndex = idx;
              return;
            }
          }
        }
      }
    }
    notifyListeners();
  }

  void moveFocusVertical(int offset) {
    if (remainingDice.isEmpty) return;
    int count = remainingDice.length;
    int col = currentDieIndex % 3;
    int row = currentDieIndex ~/ 3;

    if (offset == -1 && row > 0) {
      int targetIdx = (row - 1) * 3 + col;
      if (targetIdx < count) currentDieIndex = targetIdx;
    } else if (offset == 1 && row < 1) {
      int targetIdx = (row + 1) * 3 + col;
      if (targetIdx < count) {
        currentDieIndex = targetIdx;
      } else {
        // Find the closest die in the next row
        int maxInNextRow = -1;
        for (int c = 2; c >= 0; c--) {
          int idx = (row + 1) * 3 + c;
          if (idx < count) {
            maxInNextRow = idx;
            break;
          }
        }
        if (maxInNextRow != -1) {
          currentDieIndex = maxInNextRow;
        }
      }
    }
    notifyListeners();
  }

  void toggleSelectedDie() {
    if (remainingDice.isNotEmpty && currentDieIndex < remainingDice.length) {
      toggleDieSelection(currentDieIndex);
    }
  }

  String playerName(Player player) {
    if (isNetworkGame) {
      return player == myPlayer ? "You" : "Opponent";
    } else if (isBotGame && player == Player.p2) {
      return "Bot";
    } else {
      return player == Player.p1 ? localP1Name : localP2Name;
    }
  }

  GameStatePacket toPacket() {
    return GameStatePacket(
      p1Score: getScore(Player.p1),
      p2Score: getScore(Player.p2),
      currentPlayer: currentPlayer.rawValue,
      turnScore: turnScore,
      remainingDice: remainingDice,
      selectedDice: selectedDice.toList(),
      state: state,
      winner: winner?.rawValue ?? 0,
      goal: winPoints,
    );
  }

  void fromPacket(GameStatePacket packet) {
    setScore(Player.p1, packet.p1Score);
    setScore(Player.p2, packet.p2Score);
    currentPlayer = PlayerExtension.fromRawValue(packet.currentPlayer);
    turnScore = packet.turnScore;
    remainingDice = packet.remainingDice;
    selectedDice = packet.selectedDice.where((idx) => idx >= 0 && idx < packet.remainingDice.length).toSet();

    GameState oldState = _state;
    _state = packet.state;

    if (_state == GameState.rolling && oldState != GameState.rolling) {
      _startRollingAnimation();
    } else if (_state != GameState.rolling && oldState == GameState.rolling) {
      _stopRollingAnimation();
      // Generate landed rotations for client
      diceRotations.clear();
      for (int i = 0; i < remainingDice.length; i++) {
        diceRotations[i] = _random.nextDouble() * 30 - 15;
      }
    }

    if (diceRotations.isEmpty && remainingDice.isNotEmpty && _state != GameState.rolling && _state != GameState.gameOver) {
      for (int i = 0; i < remainingDice.length; i++) {
        diceRotations[i] = _random.nextDouble() * 30 - 15;
      }
    }

    Player? oldWinner = winner;
    winner = packet.winner == 0 ? null : PlayerExtension.fromRawValue(packet.winner);
    winPoints = packet.goal;

    if (oldWinner != null && winner == null) {
      p1Ready = false;
      p2Ready = false;
    }

    if (remainingDice.isNotEmpty) {
      currentDieIndex = min(currentDieIndex, remainingDice.length - 1);
    } else {
      currentDieIndex = 0;
    }
    notifyListeners();
  }

  void _startRollingAnimation() {
    _rollingTimer?.cancel();
    
    void updateDice() {
      int currentCount = rollingDice.isNotEmpty ? rollingDice.length : (remainingDice.isEmpty ? 6 : remainingDice.length);
      rollingDice = List.generate(currentCount, (_) => _random.nextInt(6) + 1);
      diceRotations.clear();
      for (int i = 0; i < currentCount; i++) {
        diceRotations[i] = _random.nextDouble() * 30 - 15;
      }
      notifyListeners();
    }
    
    updateDice();
    _rollingTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      updateDice();
    });
  }

  void _stopRollingAnimation() {
    _rollingTimer?.cancel();
    _rollingTimer = null;
    rollingDice = [];
    notifyListeners();
  }

  bool get isLocalTurn {
    if (isBotGame && currentPlayer == Player.p2) return false;
    return !isNetworkGame || currentPlayer == myPlayer;
  }

  bool get isLocalAuthority {
    return !isNetworkGame || NetworkManager.shared.isHosting;
  }

  void syncState() {
    if (isNetworkGame && NetworkManager.shared.isHosting) {
      NetworkManager.shared.sendState(toPacket());
    }
  }
}
