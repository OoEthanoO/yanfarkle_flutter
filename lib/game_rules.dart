class GameRules {
  static int calculateScore(List<int> selectedDice) {
    if (selectedDice.isEmpty) return 0;

    Map<int, int> counts = {};
    for (var die in selectedDice) {
      counts[die] = (counts[die] ?? 0) + 1;
    }

    int score = 0;
    int usedCount = 0;

    // Full straight (1-6) - 1500 points
    bool hasFullStraight = true;
    for (int i = 1; i <= 6; i++) {
      if ((counts[i] ?? 0) < 1) {
        hasFullStraight = false;
        break;
      }
    }
    if (hasFullStraight) {
      score += 1500;
      for (int i = 1; i <= 6; i++) {
        counts[i] = (counts[i] ?? 0) - 1;
      }
      usedCount += 6;
    }

    // Multiples (3+ of a kind)
    for (int die = 1; die <= 6; die++) {
      int count = counts[die] ?? 0;
      if (count >= 3) {
        int threeOfAKindScore = die == 1 ? 1000 : die * 100;
        if (count > 3) {
          score += threeOfAKindScore * (1 << (count - 3));
        } else {
          score += threeOfAKindScore;
        }
        usedCount += count;
        counts[die] = 0;
      }
    }

    // Partial straights
    bool has1To5 = true;
    for (int i = 1; i <= 5; i++) {
      if ((counts[i] ?? 0) < 1) {
        has1To5 = false;
        break;
      }
    }
    if (has1To5) {
      score += 500;
      for (int i = 1; i <= 5; i++) {
        counts[i] = (counts[i] ?? 0) - 1;
      }
      usedCount += 5;
    }

    bool has2To6 = true;
    for (int i = 2; i <= 6; i++) {
      if ((counts[i] ?? 0) < 1) {
        has2To6 = false;
        break;
      }
    }
    if (has2To6) {
      score += 750;
      for (int i = 2; i <= 6; i++) {
        counts[i] = (counts[i] ?? 0) - 1;
      }
      usedCount += 5;
    }

    // Singles (1s and 5s)
    int remainingOnes = counts[1] ?? 0;
    score += remainingOnes * 100;
    usedCount += remainingOnes;
    counts[1] = 0;

    int remainingFives = counts[5] ?? 0;
    score += remainingFives * 50;
    usedCount += remainingFives;
    counts[5] = 0;

    return usedCount == selectedDice.length ? score : 0;
  }

  static List<int> getScoringIndices(List<int> dice) {
    List<int> scoringIndices = [];
    for (int idx = 0; idx < dice.length; idx++) {
      if (dice[idx] == 1 || dice[idx] == 5) {
        scoringIndices.add(idx);
      }
    }

    Map<int, int> counts = {};
    for (var die in dice) {
      counts[die] = (counts[die] ?? 0) + 1;
    }

    counts.forEach((die, count) {
      if (count >= 3) {
        for (int idx = 0; idx < dice.length; idx++) {
          if (dice[idx] == die && !scoringIndices.contains(idx)) {
            scoringIndices.add(idx);
          }
        }
      }
    });

    List<int> sorted = List.from(dice)..sort();
    if (sorted.length == 6 && sorted[0] == 1 && sorted[1] == 2 && sorted[2] == 3 && sorted[3] == 4 && sorted[4] == 5 && sorted[5] == 6) {
      return List.generate(dice.length, (index) => index);
    }

    bool hasAll(List<int> vals) {
      for (var v in vals) {
        if (!sorted.contains(v)) return false;
      }
      return true;
    }

    List<int>? bestStraightIndices;
    int bestStraightWeight = -1;

    void checkStraight(List<int> vals) {
      if (hasAll(vals)) {
        List<int> indices = [];
        Set<int> used = {};
        for (var v in vals) {
          for (int i = 0; i < dice.length; i++) {
            if (dice[i] == v && !used.contains(i)) {
              indices.add(i);
              used.add(i);
              break;
            }
          }
        }
        if (dice.length == 6) {
          for (int i = 0; i < dice.length; i++) {
            if (!used.contains(i) && (dice[i] == 1 || dice[i] == 5)) {
              indices.add(i);
              used.add(i);
              break;
            }
          }
        }
        // Weight: Hot Dice (6 dice) gets a massive boost, then use the actual score.
        int weight = (indices.length == 6 ? 10000 : 0) + GameRules.calculateScore(indices.map((i) => dice[i]).toList());
        if (weight > bestStraightWeight) {
          bestStraightWeight = weight;
          bestStraightIndices = indices;
        }
      }
    }

    checkStraight([1, 2, 3, 4, 5]);
    checkStraight([2, 3, 4, 5, 6]);

    int standardWeight = (scoringIndices.length == 6 ? 10000 : 0) + GameRules.calculateScore(scoringIndices.map((i) => dice[i]).toList());

    if (bestStraightIndices != null && bestStraightWeight > standardWeight) {
      return bestStraightIndices!;
    }

    return scoringIndices;
  }
}
