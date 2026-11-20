import Foundation

/// Deterministic random numbers (SplitMix64), so the same date always gives the same puzzle.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public enum Sudoku {
    public typealias Grid = [[Int]]

    public static func clues(for difficulty: String) -> Int {
        switch difficulty.lowercased() {
        case "easy": return 40
        case "hard": return 26
        default: return 32
        }
    }

    /// A puzzle with exactly one solution, and that solution. Cells are removed one at a time and a removal
    /// is kept only while the puzzle stays uniquely solvable (the web app removes at random, which can
    /// leave puzzles with several solutions).
    public static func generate(seed: UInt64, clues: Int) -> (puzzle: Grid, solution: Grid) {
        var rng = SeededRandom(seed: seed)
        var grid = Array(repeating: Array(repeating: 0, count: 9), count: 9)
        _ = fill(&grid, &rng)
        let solution = grid
        var cells = (0..<81).map { ($0 / 9, $0 % 9) }
        cells.shuffle(using: &rng)
        var filled = 81
        for (r, c) in cells where filled > max(clues, 17) {
            let keep = grid[r][c]
            grid[r][c] = 0
            if countSolutions(grid, limit: 2) == 1 { filled -= 1 } else { grid[r][c] = keep }
        }
        return (grid, solution)
    }

    static func candidates(_ g: Grid, _ r: Int, _ c: Int) -> [Int] {
        var used = Set<Int>()
        for i in 0..<9 { used.insert(g[r][i]); used.insert(g[i][c]) }
        let br = 3 * (r / 3), bc = 3 * (c / 3)
        for i in 0..<3 { for j in 0..<3 { used.insert(g[br + i][bc + j]) } }
        return (1...9).filter { !used.contains($0) }
    }

    /// The empty cell with the fewest candidates (keeps the search small).
    static func nextCell(_ g: Grid) -> (Int, Int, [Int])? {
        var best: (Int, Int, [Int])?
        for r in 0..<9 { for c in 0..<9 where g[r][c] == 0 {
            let cand = candidates(g, r, c)
            if best == nil || cand.count < best!.2.count { best = (r, c, cand) }
            if cand.count <= 1 { return best }
        } }
        return best
    }

    static func fill(_ g: inout Grid, _ rng: inout SeededRandom) -> Bool {
        guard let (r, c, cand) = nextCell(g) else { return true }
        for n in cand.shuffled(using: &rng) {
            g[r][c] = n
            if fill(&g, &rng) { return true }
        }
        g[r][c] = 0
        return false
    }

    public static func countSolutions(_ grid: Grid, limit: Int) -> Int {
        var g = grid
        var count = 0
        func search() {
            guard count < limit else { return }
            guard let (r, c, cand) = nextCell(g) else { count += 1; return }
            for n in cand {
                g[r][c] = n
                search()
                if count >= limit { break }
            }
            g[r][c] = 0
        }
        search()
        return count
    }
}
