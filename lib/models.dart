enum Player { p1, p2 }

extension PlayerExtension on Player {
  Player get next => this == Player.p1 ? Player.p2 : Player.p1;
  int get rawValue => this == Player.p1 ? 1 : 2;
  static Player fromRawValue(int value) => value == 1 ? Player.p1 : Player.p2;
}

enum GameState { rolling, bust, turn, endTurn, gameOver }

class GameStatePacket {
  final int p1Score;
  final int p2Score;
  final int currentPlayer;
  final int turnScore;
  final List<int> remainingDice;
  final List<int> selectedDice;
  final GameState state;
  final int winner;
  final int goal;

  GameStatePacket({
    required this.p1Score,
    required this.p2Score,
    required this.currentPlayer,
    required this.turnScore,
    required this.remainingDice,
    required this.selectedDice,
    required this.state,
    required this.winner,
    required this.goal,
  });

  Map<String, dynamic> toJson() => {
        'p1Score': p1Score,
        'p2Score': p2Score,
        'currentPlayer': currentPlayer,
        'turnScore': turnScore,
        'remainingDice': remainingDice,
        'selectedDice': selectedDice,
        'state': state.name,
        'winner': winner,
        'goal': goal,
      };

  factory GameStatePacket.fromJson(Map<String, dynamic> json) => GameStatePacket(
        p1Score: json['p1Score'],
        p2Score: json['p2Score'],
        currentPlayer: json['currentPlayer'],
        turnScore: json['turnScore'],
        remainingDice: List<int>.from(json['remainingDice'] ?? []),
        selectedDice: List<int>.from(json['selectedDice'] ?? []),
        state: GameState.values.firstWhere((e) => e.name == json['state'], orElse: () => GameState.turn),
        winner: json['winner'],
        goal: json['goal'],
      );
}

enum GameAction {
  select, moveLeft, moveRight, moveTo, roll, score, bustAck, nextTurn, moveUp, moveDown, continueRoll, endTurn, bust, readyUp, emote
}
