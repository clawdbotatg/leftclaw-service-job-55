// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BurnGrid — CLAWD Multiplier Grid Game
/// @notice A 10x10 grid where players burn CLAWD to claim cells and win multiplied payouts.
contract BurnGrid is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable clawd;

    uint256 public constant CELL_PRICE = 500_000 * 1e18;
    uint8 public constant GRID_SIZE = 100;
    uint256 public constant BURN_PERCENT = 20;
    uint256 public constant ROUND_DURATION = 48 hours;

    uint256 public roundId;
    uint256 public roundEnd;
    bytes32 public commitHash;
    uint256 public pot;
    bytes32 public roundSeed;
    uint8 public claimedCount;

    mapping(uint256 => mapping(uint8 => address)) public claimed;
    mapping(uint256 => mapping(address => uint8[])) private roundPicks;

    event CellPicked(uint256 indexed roundId, uint8 cellIndex, address indexed player);
    event RoundRevealed(uint256 indexed roundId, bytes32 seed);

    constructor(address _clawd, address _owner) Ownable(_owner) {
        clawd = IERC20(_clawd);
        roundId = 1;
    }

    /// @notice Pick a cell in the current round. Caller must have approved CELL_PRICE of CLAWD.
    function pickCell(uint8 cellIndex) external nonReentrant {
        require(cellIndex < GRID_SIZE, "Invalid cell");
        require(commitHash != bytes32(0), "Round not open");
        require(block.timestamp < roundEnd, "Round expired");
        require(claimed[roundId][cellIndex] == address(0), "Cell taken");

        clawd.safeTransferFrom(msg.sender, address(this), CELL_PRICE);

        uint256 burnAmount = (CELL_PRICE * BURN_PERCENT) / 100;
        clawd.safeTransfer(address(0), burnAmount);

        pot += CELL_PRICE - burnAmount;

        claimed[roundId][cellIndex] = msg.sender;
        roundPicks[roundId][msg.sender].push(cellIndex);
        claimedCount++;

        emit CellPicked(roundId, cellIndex, msg.sender);
    }

    /// @notice Reveal the round seed, pay out winners, and start the next round.
    /// @dev Callable by anyone after roundEnd or when all 100 cells are claimed.
    function revealRound(bytes32 seed) external nonReentrant {
        require(block.timestamp >= roundEnd || claimedCount == GRID_SIZE, "Round not ended");
        require(roundEnd > 0, "Round not started");
        require(keccak256(abi.encodePacked(seed)) == commitHash, "Invalid seed");

        roundSeed = seed;

        // Compute payouts in memory first, then transfer (checks-effects-interactions)
        address[100] memory players;
        uint256[100] memory payouts;
        uint256 totalPayout;

        for (uint8 i = 0; i < GRID_SIZE; i++) {
            address player = claimed[roundId][i];
            if (player == address(0)) continue;

            players[i] = player;
            uint256 roll = uint256(keccak256(abi.encodePacked(seed, i))) % 1000;
            uint256 multiplier = _getMultiplier(roll);

            if (multiplier > 0) {
                payouts[i] = multiplier * CELL_PRICE;
                totalPayout += payouts[i];
            }
        }

        // Cap total payouts at available pot
        uint256 remaining = pot;
        if (totalPayout > remaining) {
            // Pay out cells in order, capping at remaining pot
            for (uint8 i = 0; i < GRID_SIZE; i++) {
                if (payouts[i] > remaining) {
                    payouts[i] = remaining;
                }
                remaining -= payouts[i];
            }
            remaining = 0;
        } else {
            remaining = pot - totalPayout;
        }

        // Update state before transfers
        uint256 burnRemainder = remaining / 2;
        uint256 carry = remaining - burnRemainder;

        uint256 currentRound = roundId;

        pot = carry;
        claimedCount = 0;
        roundId++;
        roundEnd = block.timestamp + ROUND_DURATION;
        commitHash = bytes32(0);

        emit RoundRevealed(currentRound, seed);

        // Transfer payouts
        for (uint8 i = 0; i < GRID_SIZE; i++) {
            if (payouts[i] > 0) {
                clawd.safeTransfer(players[i], payouts[i]);
            }
        }

        // Burn remaining pot share
        if (burnRemainder > 0) {
            clawd.safeTransfer(address(0), burnRemainder);
        }
    }

    /// @notice Owner sets the commit hash to open a round for picks.
    /// @dev Can only be called when no commit is active (after reveal or initial deploy).
    function setCommit(bytes32 hash) external onlyOwner {
        require(commitHash == bytes32(0), "Commit already set");
        commitHash = hash;
        if (roundEnd == 0 || block.timestamp >= roundEnd) {
            roundEnd = block.timestamp + ROUND_DURATION;
        }
    }

    /// @notice Returns the claimed state of all 100 cells for the current round.
    function getCells() external view returns (address[100] memory cells) {
        for (uint8 i = 0; i < GRID_SIZE; i++) {
            cells[i] = claimed[roundId][i];
        }
    }

    /// @notice Returns current round information.
    function getRoundInfo()
        external
        view
        returns (uint256 _roundId, uint256 _roundEnd, uint256 _pot, uint8 _claimedCount, bytes32 _commitHash)
    {
        return (roundId, roundEnd, pot, claimedCount, commitHash);
    }

    /// @notice Returns which cells a player has picked in the current round.
    function getPlayerPicks(address player) external view returns (uint8[] memory) {
        return roundPicks[roundId][player];
    }

    /// @notice Compute the payout multiplier from a roll value (0-999).
    function _getMultiplier(uint256 roll) internal pure returns (uint256) {
        if (roll < 500) return 0;
        if (roll < 800) return 1;
        if (roll < 920) return 2;
        if (roll < 980) return 3;
        if (roll < 995) return 5;
        return 10;
    }
}
